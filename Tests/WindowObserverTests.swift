import ApplicationServices
import Foundation
@testable import PilesCore

enum WindowObserverTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 }
            else {
                failed += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        let destroyedElement = AXUIElementCreateApplication(9101)
        let survivingElement = AXUIElementCreateApplication(9102)
        let destroyedWindow = TrackedWindow(element: destroyedElement, pid: 9101)
        let survivingWindow = TrackedWindow(element: survivingElement, pid: 9102)
        var removedElement: AXUIElement?
        var destroySync: [TrackedWindow]?
        var destroyOrder: [String] = []
        var fallbackAfterRemoval: Int?
        WindowSnapshotReconciliation.applyDestroyed(
            destroyedElement,
            snapshot: [destroyedWindow, survivingWindow],
            remove: {
                removedElement = $0
                destroyOrder.append("remove")
                fallbackAfterRemoval = WorkspaceManager.closeFallbackTarget(
                    isFocusedMonitor: true,
                    wasActiveOccupied: true,
                    activeIsEmpty: (destroySync?.isEmpty ?? true),
                    nextOccupied: 2
                )
            },
            sync: {
                destroySync = $0
                destroyOrder.append("sync")
            }
        )
        check(removedElement.map { WindowIdentityKey(element: $0) } == WindowIdentityKey(element: destroyedElement),
              "destroy event removes its exact AX identity")
        check(destroySync?.count == 1 && destroySync?.first?.containsElement(survivingElement) == true,
              "stale destroy snapshot cannot resurrect destroyed window or drop another window")
        check(destroyOrder == ["sync", "remove"],
              "surviving snapshot windows reconcile before destroy removal and fallback")
        check(fallbackAfterRemoval == nil,
              "newly discovered survivor prevents an empty-workspace fallback")

        let groupedFirst = AXUIElementCreateApplication(9103)
        let groupedSecond = AXUIElementCreateApplication(9104)
        let groupedWindow = TrackedWindow(element: groupedFirst, pid: 9103, members: [groupedSecond])
        var groupedSync: [TrackedWindow]?
        WindowSnapshotReconciliation.applyDestroyed(
            groupedFirst,
            snapshot: [groupedWindow],
            remove: { _ in },
            sync: { groupedSync = $0 }
        )
        check(groupedSync?.count == 1 && groupedSync?.first?.containsElement(groupedSecond) == true,
              "destroying one grouped member preserves its live sibling")
        check(groupedSync?.first?.containsElement(groupedFirst) == false,
              "destroyed grouped member is absent from reconciled entry")

        var groupedState = MonitorState(count: 2)
        groupedState.insertWindow(groupedWindow, floating: true)
        let savedFrame = CGRect(x: 80, y: 90, width: 500, height: 400)
        groupedState.saveParkedFrame(savedFrame, for: groupedWindow)
        if let remaining = groupedSync?.first {
            groupedState.replaceWindow(groupedWindow, with: remaining)
            check(groupedState.isFloating(remaining) && groupedState.parkedFrame(for: remaining) == savedFrame,
                  "closing a grouped member preserves floating mode and restore geometry")
            check(groupedState.windowMetadata[WindowIdentityKey(element: groupedFirst)] == nil,
                  "closing a grouped member removes its dead metadata identity")
        } else {
            check(false, "grouped destroy provides a surviving entry for metadata transfer")
        }

        var activeWindows = [destroyedWindow]
        let focusedWasOccupied = !activeWindows.isEmpty
        var fallbackAfterSnapshot: Int?
        WindowSnapshotReconciliation.applyDestroyed(
            destroyedElement,
            snapshot: [survivingWindow],
            remove: { _ in
                fallbackAfterSnapshot = WorkspaceManager.closeFallbackTarget(
                    isFocusedMonitor: true, wasActiveOccupied: focusedWasOccupied,
                    activeIsEmpty: activeWindows.isEmpty, nextOccupied: 1
                )
            },
            sync: { _ in activeWindows.removeAll() }
        )
        check(fallbackAfterSnapshot == 1,
              "fallback retains pre-snapshot occupancy when sync already removed the invalid closing window")

        var ordinarySyncCount = 0
        check(!WindowSnapshotReconciliation.applyOrdinary(nil) { _ in ordinarySyncCount += 1 },
              "nil ordinary snapshot is not authoritative")
        check(!WindowSnapshotReconciliation.applyOrdinary([]) { _ in ordinarySyncCount += 1 },
              "empty ordinary snapshot is not authoritative")
        check(ordinarySyncCount == 0, "uncertain ordinary snapshots preserve tracked entries")
        check(WorkspaceManager.closeFallbackTarget(
            isFocusedMonitor: false, wasActiveOccupied: true, activeIsEmpty: true, nextOccupied: 2
        ) == nil, "close on another monitor does not steal focus")
        check(WorkspaceManager.closeFallbackTarget(
            isFocusedMonitor: true, wasActiveOccupied: true, activeIsEmpty: true, nextOccupied: 2
        ) == 2, "last focused active close selects the next occupied workspace")
        check(WorkspaceManager.closeFallbackTarget(
            isFocusedMonitor: true, wasActiveOccupied: false, activeIsEmpty: true, nextOccupied: 2
        ) == nil, "a previously empty workspace does not trigger fallback")
        check(WorkspaceManager.closeFallbackTarget(
            isFocusedMonitor: true, wasActiveOccupied: true, activeIsEmpty: false, nextOccupied: 2
        ) == nil, "close does not switch while active workspace remains occupied")
        check(WorkspaceManager.closeFallbackTarget(
            isFocusedMonitor: true, wasActiveOccupied: true, activeIsEmpty: true, nextOccupied: nil
        ) == nil, "close has no fallback when no occupied workspace exists")

        var subscriptions = WindowNotificationSubscriptions()
        let requested = [kAXUIElementDestroyedNotification, kAXMovedNotification,
                         kAXResizedNotification, kAXTitleChangedNotification].map { $0 as CFString }
        subscriptions.register(requested) { ($0 as String) != kAXMovedNotification }
        check(subscriptions.notifications.contains(kAXUIElementDestroyedNotification),
              "unsupported move notification does not remove the destroy subscription")
        check(subscriptions.notifications.contains(kAXTitleChangedNotification),
              "optional notification failure does not prevent title observation")
        var retried: [String] = []
        subscriptions.register(requested) {
            retried.append($0 as String)
            return true
        }
        check(retried == [kAXMovedNotification], "later sync retries only failed subscriptions")
        check(subscriptions.notifications.count == requested.count, "successful subscriptions survive a retry")

        var attempts: [pid_t: Int] = [:]
        let scheduler = WindowSyncScheduler(retryDelay: 0, maxRetries: 4) { pid in
            attempts[pid, default: 0] += 1
            return attempts[pid, default: 0] >= 3
        }
        for _ in 0..<100 { scheduler.sync(pid: 101) }
        scheduler.sync(pid: 102)
        check(attempts[101] == 1, "repeated events share one pending sync chain")
        check(attempts[102] == 1, "another application starts an independent sync")
        waitUntil { attempts[101] == 3 && attempts[102] == 3 }
        check(attempts[101] == 3 && attempts[102] == 3, "successful retries stop independently")

        var failures = 0
        let bounded = WindowSyncScheduler(retryDelay: 0, maxRetries: 2) { _ in
            failures += 1
            return false
        }
        bounded.sync(pid: 103)
        waitUntil { failures == 3 }
        drainMainQueue()
        check(failures == 3, "failed sync stops after the configured retry limit")

        var canceledAttempts = 0
        let canceled = WindowSyncScheduler(retryDelay: 0, maxRetries: 2) { _ in
            canceledAttempts += 1
            return false
        }
        canceled.sync(pid: 104)
        canceled.cancel(pid: 104)
        canceled.sync(pid: 104)
        canceled.cancelAll()
        drainMainQueue()
        check(canceledAttempts == 2, "cancel and stop prevent queued retries, including restarted PIDs")
        return (passed, failed)
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private static func drainMainQueue() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        waitUntil { drained }
    }
}
