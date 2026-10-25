import ApplicationServices
@testable import PilesCore

enum WindowRescanTests {
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

        var identity: pid_t = 900_000
        func window(_ pid: pid_t) -> TrackedWindow {
            identity += 1
            return TrackedWindow(element: AXUIElementCreateApplication(identity), pid: pid,
                                 group: WindowGroupKey(pid: pid, frame: .zero))
        }
        let first = window(11)
        let second = window(12)
        let third = window(11)
        let trackedOnly = window(13)
        let batches = WorkspaceManager.rescanBatches(
            discovered: [first, second, third],
            tracked: [window(12), trackedOnly, window(13)]
        )
        check(batches.map(\.pid) == [11, 12, 13], "batches retain first-seen PID order without duplicates")
        check(batches[0].windows == [first, third], "windows retain discovery order within a PID")
        check(batches[1].windows == [second], "tracked PIDs already discovered keep their incoming windows")
        check(batches[2].windows.isEmpty, "tracked-only PIDs receive an empty incoming batch")
        check(WorkspaceManager.rescanBatches(discovered: [], tracked: []).isEmpty,
              "empty inventory and tracked state produce no batches")
        check(WorkspaceManager.rescanBatches(discovered: [], tracked: [trackedOnly]).map(\.pid) == [13],
              "an unavailable or absent app is represented only by an empty batch for conservative sync")
        return (passed, failed)
    }
}
