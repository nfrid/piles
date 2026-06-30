import AppKit

struct ActiveWindowSnapshot {
    let window: TrackedWindow
    let attributes: WindowAttributes

    var isFullscreen: Bool { attributes.fullscreen }
    var isTrackable: Bool { attributes.isTrackable }
    var isTileable: Bool { attributes.isTileable }
}

@dynamicMemberLookup
package final class Monitor {

    private static let geometryDebounceDelay: TimeInterval = 0.08
    private static let geometrySuppressionDelay: TimeInterval = 0.20
    private static let frameTolerance: CGFloat = 2.0

    let displayID: CGDirectDisplayID
    var screen: NSScreen
    var state = MonitorState()

    subscript<T>(dynamicMember keyPath: WritableKeyPath<MonitorState, T>) -> T {
        get { state[keyPath: keyPath] }
        set { state[keyPath: keyPath] = newValue }
    }

    private var retileWork: DispatchWorkItem?
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
        guard state.workspaces.indices.contains(index), index != state.active else { return }
        saveFocusedIndex()
        guard let previous = state.activate(index) else { return }

        revealActiveWorkspace(hiding: previous)
        restoreFocusedWindow()
    }

    func revealWorkspace(_ index: Int, focusing focused: TrackedWindow) {
        guard state.workspaces.indices.contains(index) else { return }

        if index != state.active {
            saveFocusedIndex()
            guard let previous = state.activate(index) else { return }
            revealActiveWorkspace(hiding: previous)
        } else {
            retile()
        }

        guard rememberFocusedWindow(focused) else { return }

        let target = state.workspaces[state.active][state.focusedIndices[state.active]]
        focusInActiveLayout(target)
    }

    func moveActiveWindowTo(_ index: Int) {
        guard state.workspaces.indices.contains(index) else { return }
        guard index != state.active else {
            restoreFocusedWindow()
            return
        }
        guard let moved = moveActiveFocusedWindow(to: index) else { return }
        moved.hideOffscreen(WindowManager.screenRect(for: self.screen))
        retile()
        restoreFocusedWindow()
    }

    func moveActiveWindowAndSwitchTo(_ index: Int) {
        guard state.workspaces.indices.contains(index) else { return }
        guard index != state.active else {
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
        guard offset != 0, state.workspaces.count > 1 else { return nil }
        let count = state.workspaces.count
        var index = state.active
        for _ in 1..<count {
            index = (index + offset + count) % count
            if !state.workspaces[index].isEmpty {
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
        switch existing {
        case .missing:
            let workspaceIndex = state.resolvedWorkspaceIndex(workspace)
            let insertIndex = state.resolvedInsertIndex(position, in: workspaceIndex)
            DebugLog.write("monitor \(displayID) add workspace=\(workspaceIndex) index=\(insertIndex) window=\(DebugLog.describe(window))")
            state.insertWindow(window, workspace: workspace, position: position)
            if workspaceIndex == state.active {
                scheduleRetile()
            } else {
                window.hideOffscreen(WindowManager.screenRect(for: self.screen))
            }
            return .inserted
        case .replaced:
            applyReplacementEffects(for: window)
            return .replaced
        case .unchanged, .inserted:
            return existing
        }
    }

    func updateExistingWindow(_ window: TrackedWindow) -> WindowUpdate {
        for ws in 0..<state.workspaces.count {
            guard let i = state.workspaces[ws].firstIndex(of: window) else { continue }
            let current = state.workspaces[ws][i]
            if current.group != window.group || !current.hasSameMembers(window) {
                DebugLog.write("monitor \(displayID) replace workspace=\(ws) index=\(i) old={\(DebugLog.describe(current))} new={\(DebugLog.describe(window))}")
                state.workspaces[ws][i] = window
                return .replaced
            }
            return .unchanged
        }

        for ws in 0..<state.workspaces.count {
            guard let i = state.workspaces[ws].firstIndex(where: { $0.group == window.group && !$0.isTileable() }) else {
                continue
            }
            DebugLog.write("monitor \(displayID) replace untileable workspace=\(ws) index=\(i) old={\(DebugLog.describe(state.workspaces[ws][i]))} new={\(DebugLog.describe(window))}")
            state.workspaces[ws][i] = window
            return .replaced
        }

        for ws in 0..<state.workspaces.count {
            guard let i = state.workspaces[ws].firstIndex(where: { Self.matchesFullscreenTransition(existing: $0, incoming: window) }) else {
                continue
            }
            DebugLog.write("monitor \(displayID) replace fullscreen workspace=\(ws) index=\(i) old={\(DebugLog.describe(state.workspaces[ws][i]))} new={\(DebugLog.describe(window))}")
            state.workspaces[ws][i] = window
            return .replaced
        }
        return .missing
    }

    func applyReplacementEffects(for window: TrackedWindow) {
        guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.contains(window) }) else { return }
        if workspaceIndex == state.active {
            scheduleRetile()
        } else if window.isTileable() {
            window.hideOffscreen(WindowManager.screenRect(for: self.screen))
        }
    }

    private static func matchesFullscreenTransition(existing: TrackedWindow, incoming: TrackedWindow) -> Bool {
        guard existing.pid == incoming.pid, !existing.hasElement(incoming) else { return false }
        guard existing.isFullscreen() || incoming.isFullscreen() else { return false }
        if existing.group == incoming.group { return true }
        if let existingTitle = existing.title(),
           let incomingTitle = incoming.title(),
           existingTitle == incomingTitle,
           !existingTitle.isEmpty {
            return true
        }
        return false
    }

    func removeWindows(where predicate: (TrackedWindow) -> Bool) -> Bool {
        let result = state.removeWindows(where: predicate)
        if result.changed && result.activeChanged { scheduleRetile() }
        return result.changed
    }

    func removeStaleWindows(pid: pid_t, current: [TrackedWindow]) -> Bool {
        removeWindows { window in
            guard window.pid == pid, !current.contains(window) else { return false }
            guard !window.isTrackable() else { return false }
            DebugLog.write("monitor \(displayID) stale pid=\(pid) window=\(DebugLog.describe(window))")
            return true
        }
    }

    func cancelPendingWork() {
        geometryRetileWork?.cancel()
        geometryRetileWork = nil
        retileWork?.cancel()
        retileWork = nil
    }

    func containsWindow(_ window: TrackedWindow) -> Bool {
        state.workspaces.contains { $0.contains(window) }
    }

    func focusNext() { focusOffset(1) }
    func focusPrev() { focusOffset(-1) }
    func moveFocusedWindowNext() { moveFocusedWindow(offset: 1) }
    func moveFocusedWindowPrev() { moveFocusedWindow(offset: -1) }

    private func focusOffset(_ offset: Int) {
        guard !activeWorkspaceIsFullscreen else { return }
        let beforeCount = state.workspaces[state.active].count
        _ = cleanActiveWorkspace()
        let windows = state.workspaces[state.active]
        guard !windows.isEmpty else { return }

        if windows.count != beforeCount {
            retile()
        }

        let targetIndex: Int
        if windows.count > 1,
           let focused = WindowManager.focusedWindow(),
           let i = windows.firstIndex(of: focused) {
            targetIndex = (i + offset + windows.count) % windows.count
        } else {
            targetIndex = state.clampedFocus(in: state.active)
        }

        let target = windows[targetIndex]
        focusInActiveLayout(target)
        state.focusedIndices[state.active] = targetIndex
    }

    private func moveFocusedWindow(offset: Int) {
        guard !activeWorkspaceIsFullscreen else { return }
        let windows = state.workspaces[state.active]
        guard windows.count > 1,
              let focused = WindowManager.focusedWindow(),
              let i = windows.firstIndex(of: focused)
        else { return }

        let moved = WorkspaceWindows.moving(windows, from: i, offset: offset)
        let targetIndex = moved.movedIndex
        state.workspaces[state.active] = moved.items
        state.focusedIndices[state.active] = targetIndex
        retile()
        state.workspaces[state.active][targetIndex].focus()
    }

    func swapMaster() {
        guard !activeWorkspaceIsFullscreen else { return }
        guard state.workspaces[state.active].count > 1 else { return }
        guard let focused = WindowManager.focusedWindow(),
              let i = state.workspaces[state.active].firstIndex(of: focused),
              i != 0
        else { return }
        state.workspaces[state.active].swapAt(0, i)
        retile()
        state.workspaces[state.active][0].focus()
    }

    func toggleLayout() {
        state.layouts[state.active] = state.layouts[state.active] == .tile ? .monocle : .tile
        retile()
        if state.layouts[state.active] == .monocle,
           let focused = WindowManager.focusedWindow(),
           state.workspaces[state.active].contains(focused) {
            focusInActiveLayout(focused)
        }
    }

    private func scheduleRetile() {
        guard retileWork == nil else { return }
        let work = DispatchWorkItem { [self] in
            retileWork = nil
            retile()
        }
        retileWork = work
        DispatchQueue.main.async(execute: work)
    }

    func scheduleCorrectiveRetile() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= ignoreGeometryUntil else { return }

        geometryRetileWork?.cancel()
        let scheduledActive = state.active
        let work = DispatchWorkItem { [self] in
            geometryRetileWork = nil
            guard state.active == scheduledActive else { return }
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
            if let current = window.getFrame(),
               WorkspaceWindows.framesMatch(current, frame, tolerance: Self.frameTolerance) {
                continue
            }
            window.setFrameUnchecked(frame)
        }
        return layout.screen
    }

    static func cleanActiveWorkspaceWindows(
        _ windows: [TrackedWindow],
        attributesFor: (TrackedWindow) -> WindowAttributes?
    ) -> (windows: [TrackedWindow], snapshots: [ActiveWindowSnapshot]) {
        var kept: [TrackedWindow] = []
        var snapshots: [ActiveWindowSnapshot] = []
        var seenIdentities: Set<WindowIdentityKey> = []
        kept.reserveCapacity(windows.count)
        snapshots.reserveCapacity(windows.count)
        seenIdentities.reserveCapacity(windows.count)

        for window in windows {
            let identityKeys = window.identityKeys
            guard seenIdentities.isDisjoint(with: identityKeys),
                  let attributes = attributesFor(window),
                  attributes.isTrackable
            else { continue }
            seenIdentities.formUnion(identityKeys)
            kept.append(window)
            snapshots.append(ActiveWindowSnapshot(window: window, attributes: attributes))
        }
        return (kept, snapshots)
    }

    @discardableResult
    private func cleanActiveWorkspace() -> [ActiveWindowSnapshot] {
        let cleaned = Self.cleanActiveWorkspaceWindows(state.workspaces[state.active]) { $0.attributes() }
        state.workspaces[state.active] = cleaned.windows
        return cleaned.snapshots
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
            layout: state.layouts[state.active],
            settings: LayoutSettings(masterRatio: Config.shared.masterRatio)
        )
        return (windows, frames, screen)
    }

    private var activeWorkspaceIsFullscreen: Bool {
        activeFullscreenIndex != nil
    }

    private var activeFullscreenIndex: Int? {
        state.workspaces[state.active].firstIndex { $0.isFullscreen() }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        WorkspaceWindows.framesMatch(lhs, rhs, tolerance: tolerance)
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
              state.layouts[state.active] == .tile,
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
        for window in state.workspaces[state.active] where window.isTileable() {
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
        cancelPendingWork()
        ignoreGeometryUntil = 0
        state = MonitorState()
    }

    /// Place the active workspace on screen before moving the previous workspace offscreen
    /// so the desktop is not exposed between AX updates.
    private func revealActiveWorkspace(hiding previous: Int) {
        retile()
        let screen = WindowManager.screenRect(for: self.screen)
        for win in state.workspaces[previous] {
            win.hideOffscreen(screen)
        }
    }

    private func focusInActiveLayout(_ window: TrackedWindow) {
        window.focus()
        if state.layouts[state.active] == .monocle {
            window.raise()
        }
    }

    private func moveActiveFocusedWindow(to workspaceIndex: Int) -> TrackedWindow? {
        guard state.workspaces.indices.contains(workspaceIndex) else { return nil }
        guard let focused = WindowManager.focusedWindow(),
              let removed = state.moveActiveWindow(matching: focused, to: workspaceIndex)
        else { return nil }
        let moved = focused.keepingMembers(from: removed)
        state.workspaces[workspaceIndex][0] = moved
        return moved
    }

    func restoreFocusedWindow() {
        let windows = state.workspaces[state.active]
        guard !windows.isEmpty else { return }
        let idx = activeFullscreenIndex ?? clampedFocus(in: state.active)
        let target = windows[idx]
        focusInActiveLayout(target)
    }

    func restoreAllWindows() {
        let screen = WindowManager.screenFrame(for: self.screen)
        for ws in state.workspaces {
            for win in ws {
                guard !win.isFullscreen() else { continue }
                guard let frame = win.getFrame() else { continue }
                win.setFrame(WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: screen))
            }
        }
    }
}
