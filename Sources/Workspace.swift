import Foundation
import AppKit
import ApplicationServices

package final class WorkspaceManager {
    package static let shared = WorkspaceManager()

    private struct LocatedWindow {
        let window: TrackedWindow
        let location: WorkspaceWindowLocation
    }

    private(set) var monitors: [Monitor] = []
    private(set) var focusedMonitorIndex: Int = 0
    private var screenChangeWork: DispatchWorkItem?
    private lazy var externalFocus = ExternalFocusCoordinator(host: self)
    private var locationIndex: [WindowIdentityKey: LocatedWindow] = [:]
    private var pendingHUD: (workspaceIndex: Int, direction: Int?)?

    var focusedMonitor: Monitor { monitors[focusedMonitorIndex] }

    var focusedMonitorLabel: String? {
        monitors.count > 1 ? "Monitor \(focusedMonitorIndex + 1)" : nil
    }

    private init() {}

    package func bootstrap() {
        rebuildMonitors()
        focusedMonitorIndex = 0
        let windows = WindowManager.allWindows()
        for window in windows {
            let placement = placementForWindow(window)
            placement.monitor.addWindow(
                window,
                workspace: placement.assignment?.workspace,
                position: placement.assignment?.position
            )
        }
        for monitor in monitors {
            monitor.retile()
        }
        commitChanges()
    }

    func switchTo(_ index: Int, hudDirection: Int? = nil) {
        let previous = focusedMonitor.active
        if index != previous {
            beginManagedWorkspaceSwitch(from: previous, to: index)
        }
        focusedMonitor.switchTo(index)
        if index != previous {
            queueHUD(
                workspaceIndex: index,
                direction: hudDirection ?? workspaceSwitchDirection(from: previous, to: index)
            )
        }
        commitChanges()
    }

    func focusWindow(workspaceIndex: Int, windowIndex: Int) {
        let monitor = focusedMonitor
        guard monitor.workspaces.indices.contains(workspaceIndex),
              monitor.workspaces[workspaceIndex].indices.contains(windowIndex)
        else {
            if monitor.workspaces.indices.contains(workspaceIndex) {
                switchTo(workspaceIndex)
            }
            return
        }
        let window = monitor.workspaces[workspaceIndex][windowIndex]
        let previous = monitor.active
        if workspaceIndex != previous {
            beginManagedWorkspaceSwitch(from: previous, to: workspaceIndex)
        }
        monitor.revealWorkspace(workspaceIndex, focusing: window)
        if workspaceIndex != previous {
            queueHUD(
                workspaceIndex: workspaceIndex,
                direction: workspaceSwitchDirection(from: previous, to: workspaceIndex)
            )
        }
        commitChanges()
    }

    func switchToLast() {
        let target = focusedMonitor.previousActive
        guard target != focusedMonitor.active else { return }
        switchTo(target)
    }

    func switchToOccupied(offset: Int, movingFocusedWindow: Bool) {
        guard let target = focusedMonitor.nextOccupiedWorkspace(offset: offset) else { return }
        let previous = focusedMonitor.active
        if target != previous {
            beginManagedWorkspaceSwitch(from: previous, to: target)
        }
        if movingFocusedWindow {
            focusedMonitor.moveActiveWindowAndSwitchTo(target)
        } else {
            focusedMonitor.switchTo(target)
        }
        if target != previous {
            queueHUD(workspaceIndex: target, direction: offset > 0 ? 1 : -1)
        }
        commitChanges()
    }

    func moveActiveWindowTo(_ index: Int) {
        focusedMonitor.moveActiveWindowTo(index)
        commitChanges()
    }

    func moveActiveWindowAndSwitchTo(_ index: Int) {
        let previous = focusedMonitor.active
        if index != previous {
            beginManagedWorkspaceSwitch(from: previous, to: index)
        }
        focusedMonitor.moveActiveWindowAndSwitchTo(index)
        if index != previous {
            queueHUD(
                workspaceIndex: index,
                direction: workspaceSwitchDirection(from: previous, to: index)
            )
        }
        commitChanges()
    }

    @discardableResult
    func addWindow(_ window: TrackedWindow, commit: Bool = true) -> WindowUpdate {
        for monitor in monitors {
            let result = monitor.updateExistingWindow(window)
            if result != .missing {
                if result == .replaced {
                    monitor.applyReplacementEffects(for: window)
                }
                if result == .replaced, commit {
                    commitChanges()
                }
                return result
            }
        }
        let placement = placementForWindow(window)
        let result = placement.monitor.addWindow(
            window,
            workspace: placement.assignment?.workspace,
            position: placement.assignment?.position
        )
        if result == .inserted, commit {
            commitChanges()
        }
        return result
    }

    func syncWindows(pid: pid_t, windows: [TrackedWindow]) {
        DebugLog.write("workspace sync begin pid=\(pid) windows=\(DebugLog.describe(windows))")
        let hadTrackedWindows = hasTrackedWindows(pid: pid)
        var changed = false
        for monitor in monitors {
            if monitor.removeStaleWindows(pid: pid, current: windows) {
                changed = true
            }
        }

        for window in windows {
            let result = addWindow(window, commit: false)
            if result == .inserted, hadTrackedWindows {
                externalFocus.suppress(for: pid)
            }
            changed = changed || result == .inserted || result == .replaced
        }

        if changed {
            commitChanges()
        }
        DebugLog.write("workspace sync end pid=\(pid) changed=\(changed)")
    }

    func removeWindow(pid: pid_t) {
        removeWindows { $0.pid == pid }
    }

    func removeWindow(_ window: TrackedWindow) {
        removeWindows { $0.hasElement(window) }
    }

    private func removeWindows(where predicate: (TrackedWindow) -> Bool) {
        var changed = false
        for monitor in monitors {
            if monitor.removeWindows(where: predicate) {
                changed = true
            }
        }
        guard changed else { return }
        commitChanges()
    }

    func focusNext() {
        focusedMonitor.focusNext()
        MonocleBar.shared.update()
    }

    func focusPrev() {
        focusedMonitor.focusPrev()
        MonocleBar.shared.update()
    }

    func moveFocusedWindowNext() {
        focusedMonitor.moveFocusedWindowNext()
        commitChanges()
    }

    func moveFocusedWindowPrev() {
        focusedMonitor.moveFocusedWindowPrev()
        commitChanges()
    }

    func swapMaster() {
        focusedMonitor.swapMaster()
        commitChanges()
    }

    func canResizeMasterRatio(at point: CGPoint) -> Bool {
        focusedMonitor.canResizeMasterRatio(at: point)
    }

    func resizeMasterRatio(at point: CGPoint) {
        guard focusedMonitor.resizeMasterRatio(at: point) else { return }
        commitChanges()
    }

    func toggleLayout() {
        focusedMonitor.toggleLayout()
        commitChanges()
    }

    func focusMonitor(offset: Int) {
        guard monitors.count > 1 else { return }
        focusedMonitor.saveFocusedIndex()
        focusedMonitorIndex = (focusedMonitorIndex + offset + monitors.count) % monitors.count
        let target = focusedMonitor
        target.restoreFocusedWindow()
        commitChanges(rebuildIndex: false)
    }

    func moveWindowToMonitor(offset: Int) {
        guard monitors.count > 1 else { return }
        guard let focused = WindowManager.focusedWindow() else { return }

        let source = focusedMonitor
        guard let i = source.workspaces[source.active].firstIndex(of: focused) else { return }
        let moved = focused.keepingMembers(from: source.workspaces[source.active][i])
        source.workspaces[source.active].remove(at: i)
        source.retile()

        let targetIndex = (focusedMonitorIndex + offset + monitors.count) % monitors.count
        let target = monitors[targetIndex]
        target.insertWindow(moved)
        target.retile()

        focusedMonitorIndex = targetIndex
        moved.focus()
        commitChanges()
    }

    func followExternalFocus(pid: pid_t) {
        externalFocus.follow(pid: pid)
    }

    func followExternalFocusDeferred(pid: pid_t) {
        externalFocus.followDeferred(pid: pid)
    }

    func prepareForWindowCreated(pid: pid_t) {
        externalFocus.prepareForWindowCreated(
            pid: pid,
            suppressFollow: hasTrackedWindows(pid: pid)
        )
    }

    @discardableResult
    func handleWindowGeometryChange(pid: pid_t, element: AXUIElement) -> Bool {
        if Thread.isMainThread {
            return performWindowGeometryChange(pid: pid, element: element)
        }
        return MainThread.runSync { performWindowGeometryChange(pid: pid, element: element) }
    }

    @discardableResult
    private func performWindowGeometryChange(pid: pid_t, element: AXUIElement) -> Bool {
        guard let location = locateWindow(pid: pid, element: element) else { return false }
        let monitor = monitors[location.monitorIndex]
        if monitor.active == location.workspaceIndex {
            monitor.scheduleCorrectiveRetile()
            return true
        }
        let window = monitor.workspaces[location.workspaceIndex][location.windowIndex]
        if window.isTileable() {
            window.hideOffscreen(WindowManager.screenRect(for: monitor.screen))
        }
        return true
    }

    package func handleScreenChange() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [self] in
            performScreenChange()
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performScreenChange() {
        screenChangeWork = nil
        for monitor in monitors {
            monitor.cancelPendingWork()
        }
        let old = Dictionary(uniqueKeysWithValues: monitors.map { ($0.displayID, $0) })
        for oldMonitor in old.values {
            oldMonitor.cancelPendingWork()
        }
        let oldPrimaryID = primaryDisplayID()
        let focusedDisplayID = monitors.isEmpty ? 0 : focusedMonitor.displayID
        rebuildMonitors()

        for monitor in monitors {
            if let existing = old[monitor.displayID] {
                monitor.copyState(from: existing)
            }
        }

        let currentIDs = Set(monitors.map { $0.displayID })
        for (id, oldMonitor) in old where !currentIDs.contains(id) {
            let target = monitors[0]
            for ws in oldMonitor.workspaces {
                for window in ws where !target.containsWindow(window) {
                    target.workspaces[target.active].insert(window, at: 0)
                }
            }
        }

        let newPrimaryID = primaryDisplayID()

        if newPrimaryID != oldPrimaryID,
           let newPrimary = monitors.first(where: { $0.displayID == newPrimaryID }),
           let oldPrimary = monitors.first(where: { $0.displayID == oldPrimaryID }),
           newPrimary.workspaces.allSatisfy({ $0.isEmpty }) {
            newPrimary.copyState(from: oldPrimary)
            oldPrimary.resetState()
        }

        if newPrimaryID != oldPrimaryID {
            focusedMonitorIndex = monitors.firstIndex(where: { $0.displayID == newPrimaryID }) ?? 0
        } else {
            focusedMonitorIndex = monitors.firstIndex(where: { $0.displayID == focusedDisplayID }) ?? 0
        }

        for monitor in monitors {
            monitor.retile()
        }
        commitChanges()
    }

    package func reloadConfig() {
        Config.load()
        let count = Config.shared.workspaceCount
        for monitor in monitors {
            monitor.resizeWorkspaces(to: count)
            monitor.retile()
        }
        commitChanges()
        fputs("piles: config reloaded\n", stderr)
    }

    package func restoreAllWindows() {
        for monitor in monitors {
            monitor.restoreAllWindows()
        }
    }

    private func rebuildMonitors() {
        monitors = NSScreen.screens
            .map { screen in
                Monitor(
                    displayID: WindowManager.displayID(for: screen),
                    screen: screen
                )
            }
            .sorted { $0.screen.frame.origin.x < $1.screen.frame.origin.x }
    }

    private func beginManagedWorkspaceSwitch(from previous: Int, to index: Int) {
        externalFocus.beginManagedWorkspaceSwitch(
            from: previous,
            to: index,
            monitor: focusedMonitor
        )
    }

    private func queueHUD(workspaceIndex: Int, direction: Int?) {
        pendingHUD = (workspaceIndex, direction)
    }

    private func workspaceSwitchDirection(from previous: Int, to index: Int) -> Int? {
        guard previous != index else { return nil }
        return index > previous ? 1 : -1
    }

    private func presentPendingHUD() {
        guard let pending = pendingHUD else { return }
        pendingHUD = nil
        WorkspaceSwitchHUD.shared.show(
            workspaceIndex: pending.workspaceIndex,
            on: focusedMonitor.screen,
            direction: pending.direction
        )
    }

    private func commitChanges(rebuildIndex: Bool = true, refreshUI: Bool = true) {
        if rebuildIndex {
            rebuildLocationIndex()
        }
        if refreshUI {
            presentPendingHUD()
            StatusBar.shared.update()
            WorkspaceOverview.shared.refreshIfVisible()
            WorkspaceGlance.shared.refreshIfVisible()
        }
    }

    private func rebuildLocationIndex() {
        var index: [WindowIdentityKey: LocatedWindow] = [:]
        forEachLocatedWindow { located in
            for key in located.window.identityKeys {
                index[key] = located
            }
            return true
        }
        locationIndex = index
    }

    private func primaryDisplayID() -> CGDirectDisplayID {
        guard !monitors.isEmpty else { return 0 }
        return monitors.first(where: { $0.screen == NSScreen.main })?.displayID ?? monitors[0].displayID
    }

    func locateWindow(_ window: TrackedWindow) -> WorkspaceWindowLocation? {
        for key in window.identityKeys {
            if let located = locationIndex[key] {
                return located.location
            }
        }
        return nil
    }

    private func locateWindow(pid: pid_t, element: AXUIElement) -> WorkspaceWindowLocation? {
        let key = WindowIdentityKey(element: element)
        guard let located = locationIndex[key], located.window.pid == pid else { return nil }
        return located.location
    }

    func singleTrackedWindow(pid: pid_t) -> (window: TrackedWindow, location: WorkspaceWindowLocation)? {
        var result: LocatedWindow?

        forEachLocatedWindow { located in
            guard located.window.pid == pid, located.window.isTrackable() else { return true }
            guard result == nil else {
                result = nil
                return false
            }
            result = located
            return true
        }

        guard let result else { return nil }
        return (result.window, result.location)
    }

    package func hasTrackedWindows(pid: pid_t) -> Bool {
        for monitor in monitors {
            for workspace in monitor.workspaces {
                for window in workspace where window.pid == pid && window.isTrackable() {
                    return true
                }
            }
        }
        return false
    }

    private func forEachLocatedWindow(_ body: (LocatedWindow) -> Bool) {
        for monitorIndex in monitors.indices {
            let monitor = monitors[monitorIndex]
            for workspaceIndex in monitor.workspaces.indices {
                for windowIndex in monitor.workspaces[workspaceIndex].indices {
                    let window = monitor.workspaces[workspaceIndex][windowIndex]
                    let located = LocatedWindow(
                        window: window,
                        location: WorkspaceWindowLocation(
                            monitorIndex: monitorIndex,
                            workspaceIndex: workspaceIndex,
                            windowIndex: windowIndex
                        )
                    )
                    guard body(located) else { return }
                }
            }
        }
    }

    private func monitorForWindow(_ window: TrackedWindow) -> Monitor {
        guard monitors.count > 1, let frame = window.getFrame() else {
            return monitors[0]
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for monitor in monitors {
            let rect = WindowManager.screenRect(for: monitor.screen)
            if rect.contains(center) {
                return monitor
            }
        }
        return monitors[0]
    }

    private func placementForWindow(_ window: TrackedWindow) -> (monitor: Monitor, assignment: WindowAssignment?) {
        let assignment = Config.shared.assignment(
            app: window.appName(),
            bundleID: window.bundleID(),
            title: window.title()
        )

        if let monitor = assignment?.monitor, monitors.indices.contains(monitor - 1) {
            return (monitors[monitor - 1], assignment)
        }

        if assignment != nil {
            return (focusedMonitor, assignment)
        }

        return (monitorForWindow(window), nil)
    }
}

extension WorkspaceManager: ExternalFocusHost {
    func setFocusedMonitorIndex(_ index: Int) {
        focusedMonitorIndex = index
    }

    func queueWorkspaceSwitchHUD(workspaceIndex: Int, from previousWorkspace: Int) {
        guard workspaceIndex != previousWorkspace else { return }
        queueHUD(
            workspaceIndex: workspaceIndex,
            direction: workspaceSwitchDirection(from: previousWorkspace, to: workspaceIndex)
        )
    }

    func commitExternalFocusChanges() {
        commitChanges()
    }
}
