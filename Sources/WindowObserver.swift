import AppKit
import ApplicationServices

package final class WindowObserver {
    package static let shared = WindowObserver()

    private static let appNotifications: [CFString] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
    ].map { $0 as CFString }

    private static let windowNotifications: [CFString] = [
        kAXUIElementDestroyedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        kAXTitleChangedNotification,
    ].map { $0 as CFString }

    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: [pid_t: [WindowIdentityKey: WindowNotificationSubscriptions]] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var stopped = false
    private var titleRefreshWork: DispatchWorkItem?
    private lazy var syncScheduler = WindowSyncScheduler { [weak self] pid in
        self?.syncWindows(pid: pid) ?? true
    }
    private lazy var hideCleanupScheduler = WindowSyncScheduler(retryDelay: 0.05, maxRetries: 4) { pid in
        guard !WindowManager.isAppHidden(pid: pid) else { return true }
        WorkspaceManager.shared.syncWindows(pid: pid, windows: [], hiddenCleanup: true)
        return !WorkspaceManager.shared.hasStoredWindows(pid: pid)
    }

    private init() {}

    package func start() {
        guard workspaceObservers.isEmpty else { return }
        stopped = false
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            self?.handleAppLaunched(app)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            WorkspaceManager.shared.removeWindow(pid: pid)
            WindowObserver.shared.hideCleanupScheduler.cancel(pid: pid)
            WindowObserver.shared.stopObservingApp(pid: pid)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            let pid = app.processIdentifier
            WorkspaceManager.shared.followExternalFocusDeferred(pid: pid)
            guard !WorkspaceManager.shared.hasTrackedWindows(pid: pid) else { return }
            WindowObserver.shared.syncScheduler.sync(pid: pid)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let observer = WindowObserver.shared
            let pid = app.processIdentifier
            observer.syncScheduler.cancel(pid: pid)
            observer.hideCleanupScheduler.sync(pid: pid)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            let observer = WindowObserver.shared
            observer.hideCleanupScheduler.cancel(pid: app.processIdentifier)
            observer.syncScheduler.sync(pid: app.processIdentifier)
        })

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            observeApp(pid: pid)
            syncScheduler.sync(pid: pid)
        }
    }

    package func stop() {
        guard !stopped else { return }
        stopped = true
        syncScheduler.cancelAll()
        hideCleanupScheduler.cancelAll()
        titleRefreshWork?.cancel()
        titleRefreshWork = nil

        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            nc.removeObserver(token)
        }
        workspaceObservers.removeAll()

        for pid in observers.keys {
            stopObservingApp(pid: pid)
        }
        observers.removeAll()
        observedWindows.removeAll()
    }

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard !stopped else { return }
        let pid = app.processIdentifier
        observeApp(pid: pid)
        syncScheduler.sync(pid: pid)
    }

    private func syncWindows(pid: pid_t) -> Bool {
        guard !stopped, !WindowManager.isAppHidden(pid: pid) else { return true }
        guard WindowSnapshotReconciliation.applyOrdinary(WindowManager.windows(pid: pid), sync: { windows in
            DebugLog.write("sync pid=\(pid) windows=\(DebugLog.describe(windows))")
            WorkspaceManager.shared.syncWindows(pid: pid, windows: windows)
            observeWindows(windows, pid: pid)
        }) else { return false }
        return true
    }

    private func scheduleTitleRefresh() {
        guard !stopped, titleRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.titleRefreshWork = nil
            WorkspaceOverview.shared.refreshIfVisible(windowTitlesChanged: true)
            WorkspaceGlance.shared.refreshIfVisible(windowTitlesChanged: true)
            MonocleBar.shared.update()
        }
        titleRefreshWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func observeApp(pid: pid_t) {
        guard !stopped, observers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, WindowObserver.axCallback, &observer)
        guard result == .success, let obs = observer else { return }

        let appRef = AXUIElementCreateApplication(pid)
        addNotification(obs, appRef, kAXWindowCreatedNotification as CFString, context: "pid=\(pid) target=app")
        addNotification(obs, appRef, kAXFocusedWindowChangedNotification as CFString, context: "pid=\(pid) target=app")
        addNotification(obs, appRef, kAXFocusedUIElementChangedNotification as CFString, context: "pid=\(pid) target=app")
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)

        observers[pid] = obs
    }

    private func stopObservingApp(pid: pid_t) {
        syncScheduler.cancel(pid: pid)
        hideCleanupScheduler.cancel(pid: pid)
        guard let obs = observers.removeValue(forKey: pid) else { return }

        let appRef = AXUIElementCreateApplication(pid)
        for notification in Self.appNotifications {
            removeNotification(obs, appRef, notification, context: "pid=\(pid) target=app shutdown")
        }

        if let windows = observedWindows.removeValue(forKey: pid) {
            for (key, subscriptions) in windows {
                for notification in subscriptions.notifications {
                    removeNotification(
                        obs,
                        key.element,
                        notification as CFString,
                        context: "pid=\(pid) target=window shutdown"
                    )
                }
            }
        }

        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static let axCallback: AXObserverCallback = { _, element, notification, _ in
        let notif = notification as String
        var pidValue: pid_t = 0
        AXUIElementGetPid(element, &pidValue)
        DebugLog.write("ax notification=\(notif) pid=\(pidValue)")

        if notif == kAXWindowCreatedNotification {
            MainThread.run {
                WorkspaceManager.shared.prepareForWindowCreated(pid: pidValue)
                WindowObserver.shared.syncScheduler.sync(pid: pidValue)
            }
        } else if notif == kAXUIElementDestroyedNotification {
            MainThread.run {
                WindowObserver.shared.stopObservingWindow(element: element, pid: pidValue)
                let workspace = WorkspaceManager.shared
                let focusedWasOccupied = !workspace.monitors.isEmpty
                    && !workspace.focusedMonitor.workspaces[workspace.focusedMonitor.active].isEmpty
                let windows = WindowManager.windows(pid: pidValue)
                WindowSnapshotReconciliation.applyDestroyed(
                    element,
                    snapshot: windows,
                    remove: { workspace.removeWindow(element: $0, focusedWasOccupied: focusedWasOccupied) },
                    sync: { current in
                        DebugLog.write("destroy sync pid=\(pidValue) windows=\(DebugLog.describe(current))")
                        WorkspaceManager.shared.syncWindows(pid: pidValue, windows: current)
                        WindowObserver.shared.observeWindows(current, pid: pidValue)
                    }
                )
                if windows == nil {
                    WindowObserver.shared.syncScheduler.sync(pid: pidValue)
                }
            }
        } else if notif == kAXTitleChangedNotification {
            MainThread.run { WindowObserver.shared.scheduleTitleRefresh() }
        } else if notif == kAXFocusedWindowChangedNotification || notif == kAXFocusedUIElementChangedNotification {
            WorkspaceManager.shared.followExternalFocus(pid: pidValue)
        } else if notif == kAXMovedNotification || notif == kAXResizedNotification {
            MainThread.run {
                let handled = WorkspaceManager.shared.handleWindowGeometryChange(pid: pidValue, element: element)
                guard !handled else { return }
                WindowObserver.shared.syncScheduler.sync(pid: pidValue)
            }
        }
    }

    private func observeWindow(element: AXUIElement, pid: pid_t) {
        guard let obs = observers[pid] else { return }
        let key = WindowIdentityKey(element: element)
        var subscriptions = observedWindows[pid]?[key] ?? WindowNotificationSubscriptions()
        subscriptions.register(Self.windowNotifications) { notification in
            addNotification(obs, element, notification, context: "pid=\(pid) target=window")
        }
        if !subscriptions.notifications.isEmpty {
            observedWindows[pid, default: [:]][key] = subscriptions
        }
    }

    func observeRescanWindows(_ windows: [TrackedWindow], pid: pid_t) {
        guard !stopped else { return }
        observeApp(pid: pid)
        observeWindows(windows, pid: pid)
    }

    private func observeWindows(_ windows: [TrackedWindow], pid: pid_t) {
        for window in windows {
            for member in window.members {
                observeWindow(element: member, pid: pid)
            }
        }
    }

    private func stopObservingWindow(element: AXUIElement, pid: pid_t) {
        guard let obs = observers[pid] else { return }
        let key = WindowIdentityKey(element: element)
        guard var observed = observedWindows[pid],
              let subscriptions = observed.removeValue(forKey: key)
        else { return }

        for notification in subscriptions.notifications {
            removeNotification(obs, element, notification as CFString, context: "pid=\(pid) target=window")
        }
        observedWindows[pid] = observed.isEmpty ? nil : observed
    }

    @discardableResult
    private func addNotification(
        _ observer: AXObserver,
        _ element: AXUIElement,
        _ notification: CFString,
        context: @autoclosure () -> String
    ) -> Bool {
        let result = AXObserverAddNotification(observer, element, notification, nil)
        guard result == .success || result == .notificationAlreadyRegistered else {
            DebugLog.write("ax observer add failed result=\(result) notification=\(notification) context=\(context())")
            return false
        }
        return true
    }

    @discardableResult
    private func removeNotification(
        _ observer: AXObserver,
        _ element: AXUIElement,
        _ notification: CFString,
        context: @autoclosure () -> String
    ) -> Bool {
        let result = AXObserverRemoveNotification(observer, element, notification)
        guard result == .success else {
            DebugLog.write("ax observer remove failed result=\(result) notification=\(notification) context=\(context())")
            return false
        }
        return true
    }
}

enum WindowSnapshotReconciliation {
    static func applyOrdinary(_ snapshot: [TrackedWindow]?, sync: ([TrackedWindow]) -> Void) -> Bool {
        guard let snapshot, !snapshot.isEmpty else { return false }
        sync(snapshot)
        return true
    }

    static func applyDestroyed(
        _ element: AXUIElement,
        snapshot: [TrackedWindow]?,
        remove: (AXUIElement) -> Void,
        sync: ([TrackedWindow]) -> Void
    ) {
        if let snapshot {
            let current = snapshot.compactMap { window in
                window.containsElement(element) ? window.withoutMember(element) : window
            }
            if !current.isEmpty { sync(current) }
        }
        remove(element)
    }
}

extension TrackedWindow {
    func withoutMember(_ element: AXUIElement) -> TrackedWindow? {
        let identity = WindowIdentityKey(element: element)
        let remaining = members.filter { WindowIdentityKey(element: $0) != identity }
        guard let first = remaining.first else { return nil }
        return TrackedWindow(element: first, pid: pid, members: Array(remaining.dropFirst()), group: group)
    }
}

struct WindowNotificationSubscriptions {
    private(set) var notifications: Set<String> = []

    mutating func register(_ requested: [CFString], add: (CFString) -> Bool) {
        for notification in requested where !notifications.contains(notification as String) {
            if add(notification) {
                notifications.insert(notification as String)
            }
        }
    }
}

/// Keeps at most one bounded retry chain per application. All calls use the main queue.
final class WindowSyncScheduler {
    private struct Pending {
        let generation: Int
        let work: DispatchWorkItem
    }

    private var pending: [pid_t: Pending] = [:]
    private var generation = 0
    private let retryDelay: TimeInterval
    private let maxRetries: Int
    private let attempt: (pid_t) -> Bool

    init(retryDelay: TimeInterval = 0.05, maxRetries: Int = 120, attempt: @escaping (pid_t) -> Bool) {
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
        self.attempt = attempt
    }

    func sync(pid: pid_t) {
        guard pending[pid] == nil else { return }
        perform(pid: pid, retry: 0)
    }

    func cancel(pid: pid_t) {
        pending.removeValue(forKey: pid)?.work.cancel()
    }

    func cancelAll() {
        for retry in pending.values { retry.work.cancel() }
        pending.removeAll()
    }

    private func perform(pid: pid_t, retry: Int) {
        guard !attempt(pid), retry < maxRetries else { return }
        generation += 1
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending[pid]?.generation == scheduledGeneration else { return }
            self.pending.removeValue(forKey: pid)
            self.perform(pid: pid, retry: retry + 1)
        }
        pending[pid] = Pending(generation: scheduledGeneration, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }
}
