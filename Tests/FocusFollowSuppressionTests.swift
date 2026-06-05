import Foundation
@testable import PilesCore

enum FocusFollowSuppressionTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
            } else {
                failed += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        var suppression = FocusFollowSuppression()
        let pid: pid_t = 42_001

        check(!suppression.isSuppressed(pid: pid, now: 10), "starts unsuppressed")
        suppression.suppress(pid: pid, duration: 0.25, now: 10)
        check(suppression.isSuppressed(pid: pid, now: 10.1), "remains suppressed before duration elapses")
        check(!suppression.isSuppressed(pid: pid, now: 10.25), "expires after duration")
        check(!suppression.isSuppressed(pid: pid, now: 11), "cleans up expired entry")

        suppression.suppress(pid: pid, duration: 0.1, now: 20)
        suppression.suppress(pid: pid, duration: 0.3, now: 20.05)
        check(suppression.isSuppressed(pid: pid, now: 20.34), "extends suppression to the latest deadline")
        check(!suppression.isSuppressed(pid: pid, now: 20.35), "releases at the extended deadline")

        return (passed, failed)
    }
}
