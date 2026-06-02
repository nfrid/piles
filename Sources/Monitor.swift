import AppKit

enum WindowUpdate {
    case missing
    case inserted
    case replaced
    case unchanged
}

package final class Monitor {
    private static let geometryDebounceDelay: TimeInterval = 0.08
    private static let geometrySuppressionDelay: TimeInterval = 0.20
    private static let frameTolerance: CGFloat = 2.0

    let displayID: CGDirectDisplayID
    var screen: NSScreen
    var workspaces: [[TrackedWindow]] = Array(repeating: [], count: Config.shared.workspaceCount)
    var layouts: [Layout] = Array(repeating: Config.shared.defaultLayout, count: Config.shared.workspaceCount)
    var focusedIndices: [Int] = Array(repeating: 0, count: Config.shared.workspaceCount)
    var active: Int = 0
    var previousActive: Int = 0
    private var retileScheduled = false
    private var geometryRetileWork: DispatchWorkItem?
    private var ignoreGeometryUntil: TimeInterval = 0

    init(displayID: CGDirectDisplayID, screen: NSScreen) {
        self.displayID = displayID
        self.screen = screen
    }

    func switchTo(_ index: Int) {
        guard index >= 0, index < Config.shared.workspaceCount, index != active else { return }

        let previous = active
        previousActive = previous
        saveFocusedIndex()
        active = index

        let screen = WindowManager.screenRect(for: self.screen)
        for win in workspaces[previous] {
            win.hideOffscreen(screen)
        }

        retile()
        restoreFocusedWindow()
    }

    func revealWorkspace(_ index: Int, focusing focused: TrackedWindow) {
        guard index >= 0, index < Config.shared.workspaceCount else { return }

        if index != active {
            let previous = active
            previousActive = previous
            saveFocusedIndex()
            active = index

            let screen = WindowManager.screenRect(for: self.screen)
            for win in workspaces[previous] {
                win.hideOffscreen(screen)
            }
        }

        guard rememberFocusedWindow(focused) else { return }
        retile()
        guard rememberFocusedWindow(focused) else { return }

        let target = workspaces[active][focusedIndices[active]]
        target.focus()
        if layouts[active] == .monocle {
            target.raise()
        }
    }

    func moveActiveWindowTo(_ index: Int) {
        guard index >= 0, index < Config.shared.workspaceCount, index != active else { return }
        guard let focused = WindowManager.focusedWindow() else { return }

        guard let i = workspaces[active].firstIndex(of: focused) else { return }
        let moved = focused.keepingMembers(from: workspaces[active][i])
        workspaces[active].remove(at: i)
        workspaces[index].insert(moved, at: 0)

        retile()
        moved.hideOffscreen(WindowManager.screenRect(for: self.screen))

        if let next = workspaces[active].first {
            next.focus()
        }
    }

    func moveActiveWindowAndSwitchTo(_ index: Int) {
        guard index >= 0, index < Config.shared.workspaceCount else { return }
        guard index != active else {
            restoreFocusedWindow()
            return
        }
        guard let focused = WindowManager.focusedWindow(),
              let i = workspaces[active].firstIndex(of: focused)
        else {
            switchTo(index)
            return
        }

        let moved = focused.keepingMembers(from: workspaces[active][i])
        workspaces[active].remove(at: i)
        workspaces[index].insert(moved, at: 0)
        focusedIndices[index] = 0
        switchTo(index)
        moved.focus()
    }

    func nextOccupiedWorkspace(offset: Int) -> Int? {
        guard offset != 0, Config.shared.workspaceCount > 1 else { return nil }
        let count = Config.shared.workspaceCount
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
        workspaces[active].insert(window, at: 0)
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
        let workspaceIndex = clampedWorkspaceIndex(workspace)
        let insertIndex = clampedInsertIndex(position, count: workspaces[workspaceIndex].count)
        DebugLog.write("monitor \(displayID) add workspace=\(workspaceIndex) index=\(insertIndex) window=\(DebugLog.describe(window))")
        workspaces[workspaceIndex].insert(window, at: insertIndex)
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
        var needsRetile = false
        var changed = false
        for i in 0..<Config.shared.workspaceCount {
            let before = workspaces[i]
            workspaces[i] = Self.windowsAfterRemoving(from: before, focusedIndex: &focusedIndices[i], where: predicate)
            if workspaces[i].count != before.count {
                changed = true
                needsRetile = needsRetile || (i == active)
            }
        }
        if changed && needsRetile { scheduleRetile() }
        return changed
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

        let targetIndex = i + offset
        guard windows.indices.contains(targetIndex) else { return }

        workspaces[active].swapAt(i, targetIndex)
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
        cleanActiveWorkspace()
        let screen = WindowManager.screenFrame(for: self.screen)
        guard !activeWorkspaceIsFullscreen else { return screen }

        let tileableWindows = workspaces[active].filter { $0.isTileable() }
        ignoreGeometryUntil = ProcessInfo.processInfo.systemUptime + Self.geometrySuppressionDelay
        Tiler.tile(
            windows: tileableWindows,
            screen: screen,
            layout: layouts[active],
            settings: LayoutSettings(masterRatio: Config.shared.masterRatio)
        )
        return screen
    }

    private func cleanActiveWorkspace() {
        var windows: [TrackedWindow] = []
        for window in workspaces[active] {
            guard window.isTrackable(), !windows.contains(window) else { continue }
            windows.append(window)
        }
        workspaces[active] = windows
    }

    private func activeWorkspaceMatchesLayout(tolerance: CGFloat) -> Bool {
        guard !activeWorkspaceIsFullscreen else { return true }

        let windows = workspaces[active].filter { $0.isTileable() }
        let screen = WindowManager.screenFrame(for: self.screen)
        let frames = Tiler.calculateFrames(
            count: windows.count,
            screen: screen,
            layout: layouts[active],
            settings: LayoutSettings(masterRatio: Config.shared.masterRatio)
        )
        guard frames.count == windows.count else { return false }

        for i in windows.indices {
            guard windows[i].isTileable(), let frame = windows[i].getFrame() else { return false }
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
              workspaces[active].filter({ $0.isTileable() }).count > 1
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

    package func resizeWorkspaces(to count: Int) {
        let old = workspaces.count
        guard count != old else { return }

        if count > old {
            workspaces.append(contentsOf: Array(repeating: [], count: count - old))
            layouts.append(contentsOf: Array(repeating: Config.shared.defaultLayout, count: count - old))
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

    func saveFocusedIndex() {
        guard let focused = WindowManager.focusedWindow(),
              rememberFocusedWindow(focused)
        else { return }
    }

    @discardableResult
    func rememberFocusedWindow(_ focused: TrackedWindow) -> Bool {
        guard let i = workspaces[active].firstIndex(of: focused) else { return false }
        workspaces[active][i] = focused.keepingMembers(from: workspaces[active][i])
        focusedIndices[active] = i
        return true
    }

    func copyState(from source: Monitor) {
        workspaces = source.workspaces
        layouts = source.layouts
        focusedIndices = source.focusedIndices
        active = source.active
        previousActive = source.previousActive
    }

    func resetState() {
        geometryRetileWork?.cancel()
        geometryRetileWork = nil
        ignoreGeometryUntil = 0
        let count = Config.shared.workspaceCount
        workspaces = Array(repeating: [], count: count)
        layouts = Array(repeating: Config.shared.defaultLayout, count: count)
        focusedIndices = Array(repeating: 0, count: count)
        active = 0
        previousActive = 0
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
                win.setFrame(Self.framePreservingSizeInsideScreen(frame, screen: screen))
            }
        }
    }

    private func clampedWorkspaceIndex(_ workspace: Int?) -> Int {
        guard let workspace else { return active }
        return Swift.min(Swift.max(workspace - 1, 0), workspaces.count - 1)
    }

    private func clampedInsertIndex(_ position: Int?, count: Int) -> Int {
        guard let position else { return 0 }
        return Swift.min(Swift.max(position - 1, 0), count)
    }

    static func windowsAfterRemoving(
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

    package static func framePreservingSizeInsideScreen(_ frame: CGRect, screen: CGRect) -> CGRect {
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
