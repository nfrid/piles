import AppKit

package final class Monitor {
    private struct ActiveWindowSnapshot {
        let window: TrackedWindow
        let attributes: WindowAttributes

        var isFullscreen: Bool { attributes.fullscreen }
        var isTrackable: Bool { attributes.isTrackable }
        var isTileable: Bool { attributes.isTileable }
    }

    private static let geometryDebounceDelay: TimeInterval = 0.08
    private static let geometrySuppressionDelay: TimeInterval = 0.20
    private static let frameTolerance: CGFloat = 2.0

    let displayID: CGDirectDisplayID
    var screen: NSScreen
    var state = MonitorState()
    var workspaces: [[TrackedWindow]] {
        get { state.workspaces }
        set { state.workspaces = newValue }
    }
    var layouts: [Layout] {
        get { state.layouts }
        set { state.layouts = newValue }
    }
    var focusedIndices: [Int] {
        get { state.focusedIndices }
        set { state.focusedIndices = newValue }
    }
    var active: Int {
        get { state.active }
        set { state.active = newValue }
    }
    var previousActive: Int {
        get { state.previousActive }
        set { state.previousActive = newValue }
    }
    private var retileScheduled = false
    private var geometryRetileWork: DispatchWorkItem?
    private var ignoreGeometryUntil: TimeInterval = 0

    init(displayID: CGDirectDisplayID, screen: NSScreen) {
        self.displayID = displayID
        self.screen = screen
    }

    func clampedFocus(in workspaceIndex: Int) -> Int {
        state.clampedFocus(in: workspaceIndex)
    }

    func switchTo(_ index: Int) {
        guard workspaces.indices.contains(index), index != active else { return }
        saveFocusedIndex()
        guard let previous = state.activate(index) else { return }

        revealActiveWorkspace(hiding: previous)
        restoreFocusedWindow()
    }

    func revealWorkspace(_ index: Int, focusing focused: TrackedWindow) {
        guard workspaces.indices.contains(index) else { return }

        if index != active {
            saveFocusedIndex()
            guard let previous = state.activate(index) else { return }
            revealActiveWorkspace(hiding: previous)
        } else {
            retile()
        }

        guard rememberFocusedWindow(focused) else { return }

        let target = workspaces[active][focusedIndices[active]]
        focusInActiveLayout(target)
    }

    func moveActiveWindowTo(_ index: Int) {
        guard workspaces.indices.contains(index) else { return }
        guard index != active else {
            restoreFocusedWindow()
            return
        }
        guard let moved = moveActiveFocusedWindow(to: index) else { return }
        moved.hideOffscreen(WindowManager.screenRect(for: self.screen))
        retile()
        restoreFocusedWindow()
    }

    func moveActiveWindowAndSwitchTo(_ index: Int) {
        guard workspaces.indices.contains(index) else { return }
        guard index != active else {
            restoreFocusedWindow()
            return
        }
        if let moved = moveActiveFocusedWindow(to: index) {
            switchTo(index)
            moved.focus()
        } else {
            switchTo(index)
        }
    }

    func nextOccupiedWorkspace(offset: Int) -> Int? {
        guard offset != 0, workspaces.count > 1 else { return nil }
        let count = workspaces.count
        var index = active
        for _ in 1..<count {
            index = (index + offset + count) % count
            if !workspaces[index].isEmpty {
                return index
            }
        }
        return nil
    }

    @discardableResult
    func insertWindow(_ window: TrackedWindow) -> Bool {
        guard updateExistingWindow(window) == .missing else { return false }
        state.insertWindow(window)
        return true
    }

    @discardableResult
    func addWindow(_ window: TrackedWindow) -> WindowUpdate {
        addWindow(window, workspace: nil, position: nil)
    }

    @discardableResult
    func addWindow(_ window: TrackedWindow, workspace: Int?, position: Int?) -> WindowUpdate {
        let existing = updateExistingWindow(window)
        guard existing == .missing else { return existing }
        let workspaceIndex = state.resolvedWorkspaceIndex(workspace)
        let insertIndex = state.resolvedInsertIndex(position, in: workspaceIndex)
        DebugLog.write("monitor \(displayID) add workspace=\(workspaceIndex) index=\(insertIndex) window=\(DebugLog.describe(window))")
        state.insertWindow(window, workspace: workspace, position: position)
        if workspaceIndex == active {
            scheduleRetile()
        } else {
            window.hideOffscreen(WindowManager.screenRect(for: self.screen))
        }
        return .inserted
    }

    func updateExistingWindow(_ window: TrackedWindow) -> WindowUpdate {
        for ws in 0..<workspaces.count {
            guard let i = workspaces[ws].firstIndex(of: window) else { continue }
            let current = workspaces[ws][i]
            if current.group != window.group || !current.hasSameMembers(window) {
                DebugLog.write("monitor \(displayID) replace workspace=\(ws) index=\(i) old={\(DebugLog.describe(current))} new={\(DebugLog.describe(window))}")
                workspaces[ws][i] = window
                return .replaced
            }
            return .unchanged
        }

        for ws in 0..<workspaces.count {
            guard let i = workspaces[ws].firstIndex(where: { $0.group == window.group && !$0.isTileable() }) else {
                continue
            }
            DebugLog.write("monitor \(displayID) replace untileable workspace=\(ws) index=\(i) old={\(DebugLog.describe(workspaces[ws][i]))} new={\(DebugLog.describe(window))}")
            workspaces[ws][i] = window
            return .replaced
        }
        return .missing
    }

    func removeWindows(where predicate: (TrackedWindow) -> Bool) -> Bool {
        let result = state.removeWindows(where: predicate)
        if result.changed && result.activeChanged { scheduleRetile() }
        return result.changed
    }

    func removeStaleWindows(pid: pid_t, current: [TrackedWindow]) -> Bool {
        removeWindows { window in
            let stale = window.pid == pid && !current.contains(window)
            guard stale else { return false }
            let remove = WindowManager.isAppHidden(pid: pid) || !window.isTrackable()
            DebugLog.write("monitor \(displayID) stale pid=\(pid) remove=\(remove) window=\(DebugLog.describe(window))")
            return remove
        }
    }

    func containsWindow(_ window: TrackedWindow) -> Bool {
        workspaces.contains { $0.contains(window) }
    }

    func focusNext() { focusOffset(1) }
    func focusPrev() { focusOffset(-1) }
    func moveFocusedWindowNext() { moveFocusedWindow(offset: 1) }
    func moveFocusedWindowPrev() { moveFocusedWindow(offset: -1) }

    private func focusOffset(_ offset: Int) {
        guard !activeWorkspaceIsFullscreen else { return }
        let windows = workspaces[active]
        guard windows.count > 1,
              let focused = WindowManager.focusedWindow(),
              let i = windows.firstIndex(of: focused)
        else { return }
        let targetIndex = (i + offset + windows.count) % windows.count
        let target = windows[targetIndex]
        focusInActiveLayout(target)
        focusedIndices[active] = targetIndex
    }

    private func moveFocusedWindow(offset: Int) {
        guard !activeWorkspaceIsFullscreen else { return }
        let windows = workspaces[active]
        guard windows.count > 1,
              let focused = WindowManager.focusedWindow(),
              let i = windows.firstIndex(of: focused)
        else { return }

        let moved = WorkspaceWindows.moving(windows, from: i, offset: offset)
        let targetIndex = moved.movedIndex
        workspaces[active] = moved.items
        focusedIndices[active] = targetIndex
        retile()
        workspaces[active][targetIndex].focus()
    }

    func swapMaster() {
        guard !activeWorkspaceIsFullscreen else { return }
        guard workspaces[active].count > 1 else { return }
        guard let focused = WindowManager.focusedWindow(),
              let i = workspaces[active].firstIndex(of: focused),
              i != 0
        else { return }
        workspaces[active].swapAt(0, i)
        retile()
        workspaces[active][0].focus()
    }

    func toggleLayout() {
        layouts[active] = layouts[active] == .tile ? .monocle : .tile
        retile()
        if layouts[active] == .monocle,
           let focused = WindowManager.focusedWindow(),
           workspaces[active].contains(focused) {
            focusInActiveLayout(focused)
        }
    }

    private func scheduleRetile() {
        guard !retileScheduled else { return }
        retileScheduled = true
        DispatchQueue.main.async { [self] in
            retileScheduled = false
            retile()
        }
    }

    func scheduleCorrectiveRetile() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= ignoreGeometryUntil else { return }

        geometryRetileWork?.cancel()
        let scheduledActive = active
        let work = DispatchWorkItem { [self] in
            geometryRetileWork = nil
            guard active == scheduledActive else { return }
            guard ProcessInfo.processInfo.systemUptime >= ignoreGeometryUntil else { return }
            guard !activeWorkspaceMatchesLayout(tolerance: Self.frameTolerance) else { return }
            retile()
        }
        geometryRetileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.geometryDebounceDelay, execute: work)
    }

    @discardableResult
    func retile() -> CGRect {
        guard let layout = activeLayoutFrames() else {
            return WindowManager.screenFrame(for: self.screen)
        }
        ignoreGeometryUntil = ProcessInfo.processInfo.systemUptime + Self.geometrySuppressionDelay
        for (window, frame) in zip(layout.windows, layout.frames) {
            window.setFrameUnchecked(frame)
        }
        return layout.screen
    }

    @discardableResult
    private func cleanActiveWorkspace() -> [ActiveWindowSnapshot] {
        var windows: [TrackedWindow] = []
        var snapshots: [ActiveWindowSnapshot] = []
        windows.reserveCapacity(workspaces[active].count)
        snapshots.reserveCapacity(workspaces[active].count)

        for window in workspaces[active] {
            guard let attributes = window.attributes(),
                  attributes.isTrackable,
                  !windows.contains(window)
            else { continue }
            windows.append(window)
            snapshots.append(ActiveWindowSnapshot(window: window, attributes: attributes))
        }
        workspaces[active] = windows
        return snapshots
    }

    private func activeWorkspaceMatchesLayout(tolerance: CGFloat) -> Bool {
        guard let layout = activeLayoutFrames() else { return true }
        guard layout.frames.count == layout.windows.count else { return false }

        for i in layout.windows.indices {
            guard let frame = layout.windows[i].getFrame() else { return false }
            guard framesMatch(frame, layout.frames[i], tolerance: tolerance) else { return false }
        }

        return true
    }

    private func activeLayoutFrames() -> (windows: [TrackedWindow], frames: [CGRect], screen: CGRect)? {
        let snapshots = cleanActiveWorkspace()
        guard !snapshots.contains(where: \.isFullscreen) else { return nil }

        let windows = snapshots
            .filter(\.isTileable)
            .map(\.window)
        let screen = WindowManager.screenFrame(for: self.screen)
        let frames = Tiler.calculateFrames(
            count: windows.count,
            screen: screen,
            layout: layouts[active],
            settings: LayoutSettings(masterRatio: Config.shared.masterRatio)
        )
        return (windows, frames, screen)
    }

    private var activeWorkspaceIsFullscreen: Bool {
        activeFullscreenIndex != nil
    }

    private var activeFullscreenIndex: Int? {
        workspaces[active].firstIndex { $0.isFullscreen() }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    func canResizeMasterRatio(at point: CGPoint) -> Bool {
        masterRatioFor(point: point, requireDividerHit: true) != nil
    }

    @discardableResult
    func resizeMasterRatio(at point: CGPoint) -> Bool {
        guard let ratio = masterRatioFor(point: point, requireDividerHit: false) else { return false }
        Config.shared.masterRatio = ratio
        retile()
        return true
    }

    private func masterRatioFor(point: CGPoint, requireDividerHit: Bool) -> CGFloat? {
        guard !activeWorkspaceIsFullscreen,
              layouts[active] == .tile,
              activeTileableWindowCount > 1
        else { return nil }

        let screen = WindowManager.screenFrame(for: self.screen)
        guard screen.contains(point), screen.width > 0 else { return nil }

        if requireDividerHit {
            let dividerX = screen.minX + floor(screen.width * Config.shared.masterRatio)
            guard abs(point.x - dividerX) <= 8 else { return nil }
        }

        let rawRatio = (point.x - screen.minX) / screen.width
        return Swift.min(Swift.max(rawRatio, 0.10), 0.90)
    }

    private var activeTileableWindowCount: Int {
        var count = 0
        for window in workspaces[active] where window.isTileable() {
            count += 1
            if count > 1 { return count }
        }
        return count
    }

    package func resizeWorkspaces(to count: Int) {
        state.resize(to: count)
    }

    func saveFocusedIndex() {
        guard let focused = WindowManager.focusedWindow(),
              rememberFocusedWindow(focused)
        else { return }
    }

    @discardableResult
    func rememberFocusedWindow(_ focused: TrackedWindow) -> Bool {
        state.rememberFocusedWindow(focused)
    }

    func copyState(from source: Monitor) {
        state = source.state
    }

    func resetState() {
        geometryRetileWork?.cancel()
        geometryRetileWork = nil
        ignoreGeometryUntil = 0
        state = MonitorState()
    }

    /// Place the active workspace on screen before moving the previous workspace offscreen
    /// so the desktop is not exposed between AX updates.
    private func revealActiveWorkspace(hiding previous: Int) {
        retile()
        let screen = WindowManager.screenRect(for: self.screen)
        for win in workspaces[previous] {
            win.hideOffscreen(screen)
        }
    }

    private func focusInActiveLayout(_ window: TrackedWindow) {
        window.focus()
        if layouts[active] == .monocle {
            window.raise()
        }
    }

    private func moveActiveFocusedWindow(to workspaceIndex: Int) -> TrackedWindow? {
        guard workspaces.indices.contains(workspaceIndex) else { return nil }
        guard let focused = WindowManager.focusedWindow(),
              let removed = state.moveActiveWindow(matching: focused, to: workspaceIndex)
        else { return nil }
        let moved = focused.keepingMembers(from: removed)
        workspaces[workspaceIndex][0] = moved
        return moved
    }

    func restoreFocusedWindow() {
        let windows = workspaces[active]
        guard !windows.isEmpty else { return }
        let idx = activeFullscreenIndex ?? clampedFocus(in: active)
        let target = windows[idx]
        focusInActiveLayout(target)
    }

    func restoreAllWindows() {
        let screen = WindowManager.screenFrame(for: self.screen)
        for ws in workspaces {
            for win in ws {
                guard !win.isFullscreen() else { continue }
                guard let frame = win.getFrame() else { continue }
                win.setFrame(WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: screen))
            }
        }
    }
}
