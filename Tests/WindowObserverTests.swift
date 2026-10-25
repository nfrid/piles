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
