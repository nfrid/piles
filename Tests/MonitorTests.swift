import AppKit
import ApplicationServices
@testable import PilesCore

enum MonitorTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                fputs("fail \(file):\(line): \(message)\n", stderr)
                failed += 1
            }
        }

        guard let screen = NSScreen.screens.first else {
            fputs("skip MonitorTests: no screens available\n", stderr)
            return (0, 0)
        }

        do {
            let monitor = Monitor(displayID: 0, screen: screen)
            let kept = testWindow(pid: 5001)
            let removed = testWindow(pid: 5002)
            monitor.state.workspaces[0] = [kept, removed]

            check(
                monitor.removeStaleWindows(pid: 5002, current: [kept]),
                "removeStaleWindows reports change"
            )
            check(
                monitor.state.workspaces[0].map(\.pid) == [5001],
                "removeStaleWindows drops windows missing from sync list"
            )
        }

        do {
            let monitor = Monitor(displayID: 0, screen: screen)
            let window = testWindow(pid: 5101)
            monitor.state.workspaces[0] = [window]
            monitor.scheduleCorrectiveRetile()
            monitor.cancelPendingWork()
            check(monitor.state.workspaces[0].map(\.pid) == [5101], "cancelPendingWork leaves state intact")
        }

        return (passed, failed)
    }

    private static func testWindow(pid: pid_t) -> TrackedWindow {
        TrackedWindow(
            element: AXUIElementCreateApplication(pid),
            pid: pid,
            group: WindowGroupKey(pid: pid, frame: .null)
        )
    }
}
