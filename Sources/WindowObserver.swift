import AppKit
import ApplicationServices

package final class WindowObserver {
    package static let shared = WindowObserver()

    private static let maxRetries = 10
    private static let retryInterval: TimeInterval = 0.05

    private static let appNotifications: [CFString] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
    ].map { $0 as CFString }

    private static let windowNotifications: [CFString] = [
        kAXUIElementDestroyedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
    ].map { $0 as CFString }

    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: [pid_t: Set<WindowIdentityKey>] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var stopped = false

    private init() {}

    package func start() {
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
            WindowObserver.shared.stopObservingApp(pid: pid)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            WorkspaceManager.shared.followExternalFocus(pid: app.processIdentifier)
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            WorkspaceManager.shared.syncWindows(pid: app.processIdentifier, windows: [])
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            WindowObserver.shared.trySyncWindows(pid: app.processIdentifier, attempt: 0)
        })

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            observeApp(pid: pid)
            if let windows = WindowManager.windows(pid: pid) {
                observeWindows(windows, pid: pid)
            }
        }
    }

    package func stop() {
        guard !stopped else { return }
        stopped = true

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
        trySyncWindows(pid: pid, attempt: 0)
    }

    private func trySyncWindows(pid: pid_t, attempt: Int) {
        guard !stopped else { return }
        guard let windows = WindowManager.windows(pid: pid), !windows.isEmpty else {
            DebugLog.write("sync retry pid=\(pid) attempt=\(attempt)")
            retrySyncWindows(pid: pid, attempt: attempt)
            return
        }

        DebugLog.write("sync pid=\(pid) attempt=\(attempt) windows=\(DebugLog.describe(windows))")
        WorkspaceManager.shared.syncWindows(pid: pid, windows: windows)
        observeWindows(windows, pid: pid)
    }

    private func retrySyncWindows(pid: pid_t, attempt: Int) {
        guard !stopped, attempt < Self.maxRetries else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
            self.trySyncWindows(pid: pid, attempt: attempt + 1)
        }
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
        guard let obs = observers.removeValue(forKey: pid) else { return }

        let appRef = AXUIElementCreateApplication(pid)
        for notification in Self.appNotifications {
            removeNotification(obs, appRef, notification, context: "pid=\(pid) target=app shutdown")
        }

        if let keys = observedWindows.removeValue(forKey: pid) {
            for key in keys {
                for notification in Self.windowNotifications {
                    removeNotification(
                        obs,
                        key.element,
                        notification,
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
                WindowObserver.shared.trySyncWindows(pid: pidValue, attempt: 0)
            }
        } else if notif == kAXUIElementDestroyedNotification {
            MainThread.run {
                WindowObserver.shared.stopObservingWindow(element: element, pid: pidValue)
                let windows = WindowManager.windows(pid: pidValue) ?? []
                DebugLog.write("destroy sync pid=\(pidValue) windows=\(DebugLog.describe(windows))")
                WorkspaceManager.shared.syncWindows(pid: pidValue, windows: windows)
            }
        } else if notif == kAXFocusedWindowChangedNotification || notif == kAXFocusedUIElementChangedNotification {
            WorkspaceManager.shared.followExternalFocus(pid: pidValue)
        } else if notif == kAXMovedNotification || notif == kAXResizedNotification {
            WorkspaceManager.shared.handleWindowGeometryChange(pid: pidValue, element: element)
        }
    }

    private func observeWindow(element: AXUIElement, pid: pid_t) {
        guard let obs = observers[pid] else { return }
        let key = WindowIdentityKey(element: element)
        var observed = observedWindows[pid] ?? []
        guard observed.insert(key).inserted else { return }

        var added: [CFString] = []
        for notification in Self.windowNotifications {
            guard addNotification(obs, element, notification, context: "pid=\(pid) target=window") else {
                for previous in added {
                    removeNotification(obs, element, previous, context: "pid=\(pid) target=window cleanup=partial")
                }
                observed.remove(key)
                observedWindows[pid] = observed.isEmpty ? nil : observed
                return
            }
            added.append(notification)
        }

        observedWindows[pid] = observed
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
              observed.remove(key) != nil
        else { return }

        for notification in Self.windowNotifications {
            removeNotification(obs, element, notification, context: "pid=\(pid) target=window")
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
        guard result == .success else {
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
