import AppKit

enum WindowUpdate {
    case missing
    case inserted
    case replaced
    case unchanged
}

enum WorkspaceWindows {
    static func afterRemoving(
        from windows: [TrackedWindow],
        focusedIndex: inout Int,
        where predicate: (TrackedWindow) -> Bool
    ) -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        result.reserveCapacity(windows.count)

        var removedBeforeFocus = 0
        var removedFocused = false
        let originalFocus = Swift.min(Swift.max(focusedIndex, 0), max(windows.count - 1, 0))

        for index in windows.indices {
            if predicate(windows[index]) {
                if index < originalFocus {
                    removedBeforeFocus += 1
                } else if index == originalFocus {
                    removedFocused = true
                }
                continue
            }
            result.append(windows[index])
        }

        guard !result.isEmpty else {
            focusedIndex = 0
            return result
        }

        let adjustedFocus = originalFocus - removedBeforeFocus
        focusedIndex = removedFocused
            ? Swift.min(adjustedFocus, result.count - 1)
            : Swift.min(Swift.max(adjustedFocus, 0), result.count - 1)
        return result
    }

    static func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index % count + count) % count
    }

    static func moveIndex(_ sourceIndex: Int, offset: Int, count: Int) -> Int {
        wrappedIndex(sourceIndex + offset, count: count)
    }

    static func moving<T>(_ items: [T], from sourceIndex: Int, offset: Int) -> (items: [T], movedIndex: Int) {
        guard items.indices.contains(sourceIndex), items.count > 1 else {
            return (items, sourceIndex)
        }

        let targetIndex = moveIndex(sourceIndex, offset: offset, count: items.count)
        guard targetIndex != sourceIndex else {
            return (items, sourceIndex)
        }

        var moved = items
        let item = moved.remove(at: sourceIndex)
        moved.insert(item, at: targetIndex)
        return (moved, targetIndex)
    }

    static func framePreservingSizeInsideScreen(_ frame: CGRect, screen: CGRect) -> CGRect {
        CGRect(
            origin: CGPoint(
                x: clampedOrigin(frame.minX, length: frame.width, min: screen.minX, max: screen.maxX),
                y: clampedOrigin(frame.minY, length: frame.height, min: screen.minY, max: screen.maxY)
            ),
            size: frame.size
        )
    }

    private static func clampedOrigin(_ origin: CGFloat, length: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard origin.isFinite, length.isFinite, min.isFinite, max.isFinite else { return min }
        guard length <= max - min else { return min }
        return Swift.min(Swift.max(origin, min), max - length)
    }
}

package struct MonitorState {
    var workspaces: [[TrackedWindow]]
    var layouts: [Layout]
    var focusedIndices: [Int]
    var active: Int
    var previousActive: Int

    init(count: Int = Config.shared.workspaceCount, defaultLayout: Layout = Config.shared.defaultLayout) {
        workspaces = Array(repeating: [], count: count)
        layouts = Array(repeating: defaultLayout, count: count)
        focusedIndices = Array(repeating: 0, count: count)
        active = 0
        previousActive = 0
    }

    mutating func activate(_ index: Int) -> Int? {
        guard workspaces.indices.contains(index), index != active else { return nil }
        let previous = active
        previousActive = previous
        active = index
        return previous
    }

    func resolvedWorkspaceIndex(_ workspace: Int?) -> Int {
        guard let workspace else { return active }
        return Swift.min(Swift.max(workspace - 1, 0), workspaces.count - 1)
    }

    func resolvedInsertIndex(_ position: Int?, in workspaceIndex: Int) -> Int {
        guard let position else { return 0 }
        return Swift.min(Swift.max(position - 1, 0), workspaces[workspaceIndex].count)
    }

    mutating func insertWindow(_ window: TrackedWindow, workspace: Int? = nil, position: Int? = nil) {
        let workspaceIndex = resolvedWorkspaceIndex(workspace)
        let insertIndex = resolvedInsertIndex(position, in: workspaceIndex)
        workspaces[workspaceIndex].insert(window, at: insertIndex)
    }

    mutating func removeActiveWindow(matching focused: TrackedWindow) -> TrackedWindow? {
        guard let index = workspaces[active].firstIndex(of: focused) else { return nil }
        return workspaces[active].remove(at: index)
    }

    mutating func moveActiveWindow(matching focused: TrackedWindow, to workspaceIndex: Int) -> TrackedWindow? {
        guard workspaces.indices.contains(workspaceIndex),
              let removed = removeActiveWindow(matching: focused)
        else { return nil }
        workspaces[workspaceIndex].insert(removed, at: 0)
        focusedIndices[workspaceIndex] = 0
        return removed
    }

    mutating func removeWindows(where predicate: (TrackedWindow) -> Bool) -> (changed: Bool, activeChanged: Bool) {
        var changed = false
        var activeChanged = false
        for index in workspaces.indices {
            let before = workspaces[index]
            workspaces[index] = WorkspaceWindows.afterRemoving(
                from: before,
                focusedIndex: &focusedIndices[index],
                where: predicate
            )
            if workspaces[index].count != before.count {
                changed = true
                activeChanged = activeChanged || index == active
            }
        }
        return (changed, activeChanged)
    }

    mutating func rememberFocusedWindow(_ focused: TrackedWindow) -> Bool {
        guard let index = workspaces[active].firstIndex(of: focused) else { return false }
        workspaces[active][index] = focused.keepingMembers(from: workspaces[active][index])
        focusedIndices[active] = index
        return true
    }

    mutating func resize(to count: Int, defaultLayout: Layout = Config.shared.defaultLayout) {
        let old = workspaces.count
        guard count != old else { return }

        if count > old {
            workspaces.append(contentsOf: Array(repeating: [], count: count - old))
            layouts.append(contentsOf: Array(repeating: defaultLayout, count: count - old))
            focusedIndices.append(contentsOf: Array(repeating: 0, count: count - old))
        } else {
            let overflow = workspaces[count..<old].joined()
            workspaces.removeSubrange(count...)
            layouts.removeSubrange(count...)
            focusedIndices.removeSubrange(count...)
            if active >= count {
                active = count - 1
            }
            if previousActive >= count {
                previousActive = active
            }
            workspaces[active].append(contentsOf: overflow)
        }
    }
}

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
        target.focus()
        if layouts[active] == .monocle {
            target.raise()
        }
    }

    func moveActiveWindowTo(_ index: Int) {
        guard workspaces.indices.contains(index), index != active else { return }
        guard let focused = WindowManager.focusedWindow() else { return }

        guard let removed = state.moveActiveWindow(matching: focused, to: index) else { return }
        let moved = focused.keepingMembers(from: removed)
        workspaces[index][0] = moved

        retile()
        moved.hideOffscreen(WindowManager.screenRect(for: self.screen))

        if let next = workspaces[active].first {
            next.focus()
        }
    }

    func moveActiveWindowAndSwitchTo(_ index: Int) {
        guard workspaces.indices.contains(index) else { return }
        guard index != active else {
            restoreFocusedWindow()
            return
        }
        guard let focused = WindowManager.focusedWindow(),
              let removed = state.moveActiveWindow(matching: focused, to: index)
        else {
            switchTo(index)
            return
        }

        let moved = focused.keepingMembers(from: removed)
        workspaces[index][0] = moved
        switchTo(index)
        moved.focus()
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
        target.focus()
        focusedIndices[active] = targetIndex
        if layouts[active] == .monocle {
            target.raise()
        }
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
        if layouts[active] == .monocle, let focused = WindowManager.focusedWindow(),
           workspaces[active].contains(focused) {
            focused.raise()
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
        let snapshots = cleanActiveWorkspace()
        let screen = WindowManager.screenFrame(for: self.screen)
        guard !snapshots.contains(where: \.isFullscreen) else { return screen }

        let tileableWindows = snapshots
            .filter(\.isTileable)
            .map(\.window)
        ignoreGeometryUntil = ProcessInfo.processInfo.systemUptime + Self.geometrySuppressionDelay
        let frames = Tiler.calculateFrames(
            count: tileableWindows.count,
            screen: screen,
            layout: layouts[active],
            settings: LayoutSettings(masterRatio: Config.shared.masterRatio)
        )
        for (window, frame) in zip(tileableWindows, frames) {
            window.setFrameUnchecked(frame)
        }
        return screen
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
        let snapshots = cleanActiveWorkspace()
        guard !snapshots.contains(where: \.isFullscreen) else { return true }

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
        guard frames.count == windows.count else { return false }

        for i in windows.indices {
            guard let frame = windows[i].getFrame() else { return false }
            guard framesMatch(frame, frames[i], tolerance: tolerance) else { return false }
        }

        return true
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

    func restoreFocusedWindow() {
        let windows = workspaces[active]
        guard !windows.isEmpty else { return }
        let idx = activeFullscreenIndex ?? min(focusedIndices[active], windows.count - 1)
        let target = windows[idx]
        target.focus()
        if layouts[active] == .monocle {
            target.raise()
        }
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
