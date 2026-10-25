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
    var onStateChange: (() -> Void)?
    var readFrame: (TrackedWindow) -> CGRect? = { $0.getFrame() }
    var writeFrame: (TrackedWindow, CGRect) -> Bool = { $0.setFrameUnchecked($1) }
    var moveWindow: (TrackedWindow, CGPoint) -> Bool = { $0.setPosition($1) }
    var isEligibleForGeometry: (TrackedWindow) -> Bool = { $0.isTileable() }
    var windowAttributes: (TrackedWindow) -> WindowAttributes? = { $0.attributes() }
    var paused = false

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
        park(moved)
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
    func insertWindow(
        _ window: TrackedWindow,
        floating: Bool = false,
        workspace: Int? = nil,
        position: Int? = nil
    ) -> Bool {
        guard updateExistingWindow(window) == .missing else { return false }
        state.insertWindow(window, workspace: workspace, position: position, floating: floating)
        return true
    }

    @discardableResult
    func addWindow(_ window: TrackedWindow, floating: Bool = false) -> WindowUpdate {
        addWindow(window, workspace: nil, position: nil, floating: floating)
    }

    @discardableResult
    func addWindow(_ window: TrackedWindow, workspace: Int?, position: Int?, floating: Bool = false) -> WindowUpdate {
        let existing = updateExistingWindow(window)
        switch existing {
        case .missing:
            let workspaceIndex = state.resolvedWorkspaceIndex(workspace)
            let insertIndex = state.resolvedInsertIndex(position, in: workspaceIndex)
            DebugLog.write("monitor \(displayID) add workspace=\(workspaceIndex) index=\(insertIndex) window=\(DebugLog.describe(window))")
            state.insertWindow(window, workspace: workspace, position: position, floating: floating)
            if workspaceIndex == state.active {
                if !paused && !state.isFloating(window) { scheduleRetile() }
            } else {
                park(window)
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
                state.replaceWindow(current, with: window)
                return .replaced
            }
            return .unchanged
        }

        for ws in 0..<state.workspaces.count {
            guard let i = state.workspaces[ws].firstIndex(where: { $0.group == window.group && !$0.isTileable() }) else {
                continue
            }
            DebugLog.write("monitor \(displayID) replace untileable workspace=\(ws) index=\(i) old={\(DebugLog.describe(state.workspaces[ws][i]))} new={\(DebugLog.describe(window))}")
            state.replaceWindow(state.workspaces[ws][i], with: window)
            return .replaced
        }

        for ws in 0..<state.workspaces.count {
            guard let i = state.workspaces[ws].firstIndex(where: { Self.matchesFullscreenTransition(existing: $0, incoming: window) }) else {
                continue
            }
            DebugLog.write("monitor \(displayID) replace fullscreen workspace=\(ws) index=\(i) old={\(DebugLog.describe(state.workspaces[ws][i]))} new={\(DebugLog.describe(window))}")
            state.replaceWindow(state.workspaces[ws][i], with: window)
            return .replaced
        }
        return .missing
    }

    func applyReplacementEffects(for window: TrackedWindow) {
        guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.contains(window) }) else { return }
        if workspaceIndex == state.active {
            if !paused && !state.isFloating(window) { scheduleRetile() }
        } else {
            park(window)
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

    func removeStaleWindows(
        pid: pid_t,
        current: [TrackedWindow],
        attributesFor: (TrackedWindow) -> WindowAttributes? = { $0.attributes() },
        isConfirmedInvalid: (TrackedWindow) -> Bool = { WindowManager.isConfirmedInvalid($0.element) }
    ) -> Bool {
        removeWindows { window in
            guard window.pid == pid, !current.contains(window) else { return false }
            let attributes = attributesFor(window)
            guard isConfirmedInvalid(window) || attributes.map({ $0.trackabilityKnown && !$0.isTrackable }) == true else {
                return false
            }
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
        guard !paused, retileWork == nil else { return }
        let work = DispatchWorkItem { [self] in
            retileWork = nil
            guard !paused else { return }
            retile()
        }
        retileWork = work
        DispatchQueue.main.async(execute: work)
    }

    func scheduleCorrectiveRetile() {
        guard !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= ignoreGeometryUntil else { return }

        geometryRetileWork?.cancel()
        let scheduledActive = state.active
        let work = DispatchWorkItem { [self] in
            geometryRetileWork = nil
            guard !paused, state.active == scheduledActive else { return }
            guard ProcessInfo.processInfo.systemUptime >= ignoreGeometryUntil else { return }
            guard !activeWorkspaceMatchesLayout(tolerance: Self.frameTolerance) else { return }
            retile()
        }
        geometryRetileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.geometryDebounceDelay, execute: work)
    }

    @discardableResult
    func retile() -> CGRect {
        guard !paused else { return WindowManager.screenFrame(for: self.screen) }
        guard let layout = activeLayoutFrames() else {
            return WindowManager.screenFrame(for: self.screen)
        }
        ignoreGeometryUntil = ProcessInfo.processInfo.systemUptime + Self.geometrySuppressionDelay
        for (window, frame) in zip(layout.windows, layout.frames) {
            if let current = readFrame(window),
               WorkspaceWindows.framesMatch(current, frame, tolerance: Self.frameTolerance) {
                state.clearParkedFrame(for: window)
                continue
            }
            if writeFrame(window, frame) {
                state.clearParkedFrame(for: window)
            }
        }
        return layout.screen
    }

    static func cleanActiveWorkspaceWindows(
        _ windows: [TrackedWindow],
        attributesFor: (TrackedWindow) -> WindowAttributes?,
        isConfirmedInvalid: (TrackedWindow) -> Bool = { _ in false }
    ) -> (windows: [TrackedWindow], snapshots: [ActiveWindowSnapshot]) {
        var focusedIndex = 0
        return cleanActiveWorkspaceWindows(
            windows,
            focusedIndex: &focusedIndex,
            attributesFor: attributesFor,
            isConfirmedInvalid: isConfirmedInvalid
        )
    }

    static func cleanActiveWorkspaceWindows(
        _ windows: [TrackedWindow],
        focusedIndex: inout Int,
        attributesFor: (TrackedWindow) -> WindowAttributes?,
        isConfirmedInvalid: (TrackedWindow) -> Bool = { _ in false }
    ) -> (windows: [TrackedWindow], snapshots: [ActiveWindowSnapshot]) {
        let originalFocus = Swift.min(
            Swift.max(focusedIndex, 0),
            max(windows.count - 1, 0)
        )
        let focusedWindow = windows.indices.contains(originalFocus) ? windows[originalFocus] : nil
        var kept: [TrackedWindow] = []
        var snapshots: [ActiveWindowSnapshot] = []
        var seenIdentities: Set<WindowIdentityKey> = []
        kept.reserveCapacity(windows.count)
        snapshots.reserveCapacity(windows.count)
        seenIdentities.reserveCapacity(windows.count)

        for window in windows {
            let identityKeys = window.identityKeys
            guard seenIdentities.isDisjoint(with: identityKeys) else { continue }
            guard let attributes = attributesFor(window) else {
                if !isConfirmedInvalid(window) {
                    kept.append(window)
                    seenIdentities.formUnion(identityKeys)
                }
                continue
            }
            guard attributes.isTrackable else {
                if !attributes.trackabilityKnown {
                    kept.append(window)
                    seenIdentities.formUnion(identityKeys)
                }
                continue
            }
            seenIdentities.formUnion(identityKeys)
            kept.append(window)
            snapshots.append(ActiveWindowSnapshot(window: window, attributes: attributes))
        }

        if kept.isEmpty {
            focusedIndex = 0
        } else if let focusedWindow,
                  let index = kept.firstIndex(where: { $0.hasElement(focusedWindow) }) {
            focusedIndex = index
        } else {
            focusedIndex = Swift.min(originalFocus, kept.count - 1)
        }
        return (kept, snapshots)
    }

    @discardableResult
    func cleanActiveWorkspace(
        applyChanges: Bool = true,
        attributesFor: (TrackedWindow) -> WindowAttributes? = { $0.attributes() },
        isConfirmedInvalid: (TrackedWindow) -> Bool = { WindowManager.isConfirmedInvalid($0.element) }
    ) -> [ActiveWindowSnapshot] {
        var focusedIndex = state.focusedIndices[state.active]
        let originalWindows = state.workspaces[state.active]
        let originalFocus = state.focusedIndices[state.active]
        let cleaned = Self.cleanActiveWorkspaceWindows(
            originalWindows,
            focusedIndex: &focusedIndex,
            attributesFor: attributesFor,
            isConfirmedInvalid: isConfirmedInvalid
        )
        if applyChanges {
            state.workspaces[state.active] = cleaned.windows
            state.focusedIndices[state.active] = focusedIndex
            if cleaned.windows != originalWindows { state.pruneMetadata() }
            if cleaned.windows != originalWindows || focusedIndex != originalFocus {
                onStateChange?()
            }
        }
        return cleaned.snapshots
    }

    private func activeWorkspaceMatchesLayout(tolerance: CGFloat) -> Bool {
        guard let layout = activeLayoutFrames(applyCleanup: false) else { return false }
        guard layout.frames.count == layout.windows.count else { return false }

        for i in layout.windows.indices {
            guard let frame = readFrame(layout.windows[i]) else { return false }
            guard framesMatch(frame, layout.frames[i], tolerance: tolerance) else { return false }
        }

        return true
    }

    private func activeLayoutFrames(applyCleanup: Bool = true) -> (windows: [TrackedWindow], frames: [CGRect], screen: CGRect)? {
        let snapshots = cleanActiveWorkspace(applyChanges: applyCleanup, attributesFor: windowAttributes)
        guard snapshots.count == state.workspaces[state.active].count else { return nil }
        guard !snapshots.contains(where: { !$0.attributes.fullscreenKnown || $0.isFullscreen }) else { return nil }

        let windows = snapshots
            .filter(\.isTileable)
            .map(\.window)
            .filter { !state.isFloating($0) }
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
        state.workspaces[state.active].firstIndex { windowAttributes($0)?.fullscreen == true }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        WorkspaceWindows.framesMatch(lhs, rhs, tolerance: tolerance)
    }

    func canResizeMasterRatio(at point: CGPoint) -> Bool {
        guard !paused else { return false }
        return masterRatioFor(point: point, requireDividerHit: true) != nil
    }

    @discardableResult
    func resizeMasterRatio(at point: CGPoint) -> Bool {
        guard !paused else { return false }
        guard let ratio = masterRatioFor(point: point, requireDividerHit: false) else { return false }
        Config.shared.masterRatio = ratio
        retile()
        return true
    }

    private func masterRatioFor(point: CGPoint, requireDividerHit: Bool) -> CGFloat? {
        guard !paused,
              !activeWorkspaceIsFullscreen,
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
        return LayoutSettings.clampedMasterRatio(rawRatio)
    }

    private var activeTileableWindowCount: Int {
        var count = 0
        for window in state.workspaces[state.active] where windowAttributes(window)?.isTileable == true && !state.isFloating(window) {
            count += 1
            if count > 1 { return count }
        }
        return count
    }

    package func resizeWorkspaces(to count: Int) {
        state.resize(to: count)
        reconcileVisibility()
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
        let bounds = WindowManager.screenFrame(for: screen)
        for window in state.workspaces.flatMap({ $0 }) {
            guard let frame = state.parkedFrame(for: window) else { continue }
            state.saveParkedFrame(
                WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: bounds),
                for: window
            )
        }
    }

    func resetState() {
        cancelPendingWork()
        ignoreGeometryUntil = 0
        state = MonitorState()
    }

    /// Place the active workspace on screen before moving the previous workspace offscreen
    /// so the desktop is not exposed between AX updates.
    func revealActiveWorkspace(hiding previous: Int) {
        for window in state.workspaces[state.active] where paused || state.isFloating(window) {
            reveal(window)
        }
        if !paused { retile() }
        for window in state.workspaces[previous] { park(window) }
    }

    func park(_ window: TrackedWindow) {
        guard isEligibleForGeometry(window) else { return }
        let screen = WindowManager.screenRect(for: self.screen)
        guard let frame = readFrame(window) else { return }
        if WorkspaceWindows.isHiddenOffscreen(frame: frame, screen: screen) { return }
        state.saveParkedFrame(frame, for: window)
        let position = CGPoint(x: screen.origin.x + 1 - screen.width, y: screen.maxY - 1)
        _ = moveWindow(window, position)
    }

    func reveal(_ window: TrackedWindow) {
        guard isEligibleForGeometry(window), let frame = state.parkedFrame(for: window) else { return }
        if writeFrame(window, frame) {
            state.clearParkedFrame(for: window)
        }
    }

    func transferGeometry(of window: TrackedWindow, from frame: CGRect, parked: Bool = false) {
        guard isEligibleForGeometry(window) else { return }
        let targetFrame = WorkspaceWindows.framePreservingSizeInsideScreen(
            frame, screen: WindowManager.screenFrame(for: screen)
        )
        guard writeFrame(window, targetFrame) else { return }
        state.clearParkedFrame(for: window)
        if parked { park(window) }
    }

    func geometryForTransfer(_ window: TrackedWindow) -> CGRect? {
        state.parkedFrame(for: window) ?? readFrame(window)
    }

    func reconcileVisibility() {
        for (index, windows) in state.workspaces.enumerated() {
            if index == state.active {
                for window in windows where state.parkedFrame(for: window) != nil { reveal(window) }
            } else {
                for window in windows { park(window) }
            }
        }
        if !paused { retile() }
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
                guard isEligibleForGeometry(win) else { continue }
                let frame = state.parkedFrame(for: win) ?? readFrame(win)
                guard let frame else { continue }
                let restored = WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: screen)
                if writeFrame(win, restored) {
                    state.clearParkedFrame(for: win)
                } else {
                    state.saveParkedFrame(restored, for: win)
                }
            }
        }
    }
}
