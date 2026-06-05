import AppKit
import Foundation

struct WorkspaceWindowLocation {
    let monitorIndex: Int
    let workspaceIndex: Int
    let windowIndex: Int
}

protocol ExternalFocusHost: AnyObject {
    var monitors: [Monitor] { get }
    func setFocusedMonitorIndex(_ index: Int)
    func locateWindow(_ window: TrackedWindow) -> WorkspaceWindowLocation?
    func singleTrackedWindow(pid: pid_t) -> (window: TrackedWindow, location: WorkspaceWindowLocation)?
    func queueWorkspaceSwitchHUD(workspaceIndex: Int, from previousWorkspace: Int)
    func commitExternalFocusChanges()
}

final class ExternalFocusCoordinator {
    private static let focusFollowRetryDelay: TimeInterval = 0.015
    private static let focusFollowMaxAttempts = 5
    private static let activationFollowDelay: TimeInterval = 0.05

    private unowned let host: ExternalFocusHost
    private static let managedSwitchSuppressionDuration: TimeInterval = 0.35

    private var focusFollowWork: DispatchWorkItem?
    private var deferredActivationFollowWork: [pid_t: DispatchWorkItem] = [:]
    private var focusFollowSuppression = FocusFollowSuppression()
    private var managedSwitchSuppressedUntil: TimeInterval = 0

    init(host: ExternalFocusHost) {
        self.host = host
    }

    func follow(pid: pid_t) {
        MainThread.run { self.start(pid: pid) }
    }

    func followDeferred(pid: pid_t) {
        MainThread.run { self.scheduleDeferred(pid: pid) }
    }

    func prepareForWindowCreated(pid: pid_t, suppressFollow: Bool) {
        cancelDeferred(pid: pid)
        if suppressFollow {
            suppress(for: pid)
        }
    }

    func suppress(for pid: pid_t) {
        focusFollowSuppression.suppress(pid: pid)
    }

    func beginManagedWorkspaceSwitch(
        from previous: Int,
        to index: Int,
        monitor: Monitor,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        focusFollowWork?.cancel()
        focusFollowWork = nil
        managedSwitchSuppressedUntil = max(
            managedSwitchSuppressedUntil,
            now + Self.managedSwitchSuppressionDuration
        )
        for workspaceIndex in [previous, index] {
            guard monitor.workspaces.indices.contains(workspaceIndex) else { continue }
            for window in monitor.workspaces[workspaceIndex] {
                focusFollowSuppression.suppress(
                    pid: window.pid,
                    duration: Self.managedSwitchSuppressionDuration,
                    now: now
                )
            }
        }
    }

    private func start(pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        DebugLog.write("external focus start pid=\(pid)")
        focusFollowWork?.cancel()
        perform(pid: pid, attempt: 0)
    }

    private func schedule(pid: pid_t, attempt: Int) {
        focusFollowWork?.cancel()
        let work = DispatchWorkItem { [self] in
            perform(pid: pid, attempt: attempt)
        }
        focusFollowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusFollowRetryDelay, execute: work)
    }

    private func perform(pid: pid_t, attempt: Int) {
        focusFollowWork = nil
        guard !host.monitors.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }

        if isManagedSwitchSuppressed() {
            DebugLog.write("external focus suppressed managed switch pid=\(pid) attempt=\(attempt)")
            return
        }

        if focusFollowSuppression.isSuppressed(pid: pid) {
            DebugLog.write("external focus suppressed pid=\(pid) attempt=\(attempt)")
            return
        }

        if let focused = WindowManager.focusedWindow(pid: pid),
           let location = host.locateWindow(focused) {
            DebugLog.write("external focus matched pid=\(pid) attempt=\(attempt) window=\(DebugLog.describe(focused)) monitor=\(location.monitorIndex) workspace=\(location.workspaceIndex) index=\(location.windowIndex)")
            reveal(focused, at: location)
            return
        }

        if let fallback = host.singleTrackedWindow(pid: pid) {
            DebugLog.write("external focus fallback pid=\(pid) attempt=\(attempt) window=\(DebugLog.describe(fallback.window)) monitor=\(fallback.location.monitorIndex) workspace=\(fallback.location.workspaceIndex) index=\(fallback.location.windowIndex)")
            reveal(fallback.window, at: fallback.location)
            return
        }

        DebugLog.write("external focus retry pid=\(pid) attempt=\(attempt)")
        retry(pid: pid, attempt: attempt)
    }

    private func reveal(_ window: TrackedWindow, at location: WorkspaceWindowLocation) {
        let monitor = host.monitors[location.monitorIndex]
        if monitor.active == location.workspaceIndex {
            host.setFocusedMonitorIndex(location.monitorIndex)
            if monitor.workspaces[monitor.active].indices.contains(location.windowIndex) {
                monitor.focusedIndices[monitor.active] = location.windowIndex
            }
            monitor.rememberFocusedWindow(window)
            host.commitExternalFocusChanges()
            return
        }

        let previousWorkspace = monitor.active
        host.setFocusedMonitorIndex(location.monitorIndex)
        monitor.revealWorkspace(location.workspaceIndex, focusing: window)
        host.queueWorkspaceSwitchHUD(
            workspaceIndex: location.workspaceIndex,
            from: previousWorkspace
        )
        host.commitExternalFocusChanges()
    }

    private func retry(pid: pid_t, attempt: Int) {
        guard attempt < Self.focusFollowMaxAttempts else { return }
        schedule(pid: pid, attempt: attempt + 1)
    }

    private func scheduleDeferred(pid: pid_t) {
        cancelDeferred(pid: pid)
        let work = DispatchWorkItem { [self] in
            deferredActivationFollowWork.removeValue(forKey: pid)
            start(pid: pid)
        }
        deferredActivationFollowWork[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationFollowDelay, execute: work)
    }

    private func cancelDeferred(pid: pid_t) {
        deferredActivationFollowWork.removeValue(forKey: pid)?.cancel()
    }

    private func isManagedSwitchSuppressed(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        now < managedSwitchSuppressedUntil
    }
}
