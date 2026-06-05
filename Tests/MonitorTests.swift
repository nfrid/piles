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

        runCleanupTests { condition, message, file, line in
            check(condition, message, file: file, line: line)
        }

        guard let screen = NSScreen.screens.first else {
            fputs("skip MonitorTests: no screens available\n", stderr)
            return (passed, failed)
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

    private static func runCleanupTests(record: (Bool, String, String, Int) -> Void) {
        func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
            record(condition, message, file, line)
        }

        let trackable = WindowAttributes(
            role: kAXWindowRole,
            subrole: kAXStandardWindowSubrole,
            minimized: false,
            fullscreen: false
        )
        let minimized = WindowAttributes(
            role: kAXWindowRole,
            subrole: kAXStandardWindowSubrole,
            minimized: true,
            fullscreen: false
        )
        let panel = WindowAttributes(
            role: kAXWindowRole,
            subrole: "AXFloatingWindowSubrole",
            minimized: false,
            fullscreen: false
        )

        do {
            let first = testWindow(pid: 5201)
            let second = testWindow(pid: 5202)
            let third = testWindow(pid: 5203)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([first, second, third]) { _ in trackable }
            check(cleaned.windows.map(\.pid) == [5201, 5202, 5203], "clean keeps trackable windows in order")
            check(cleaned.snapshots.count == 3, "clean returns one snapshot per kept window")
            check(cleaned.snapshots.allSatisfy(\.isTileable), "clean snapshots expose tileable attributes")
        }

        do {
            let kept = testWindow(pid: 5301)
            let duplicate = testWindow(pid: 5301)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([kept, duplicate]) { _ in trackable }
            check(cleaned.windows.map(\.pid) == [5301], "clean drops duplicate identity")
            check(cleaned.snapshots.count == 1, "clean returns one snapshot for duplicate identity")
        }

        do {
            let kept = testWindow(pid: 5401)
            let minimizedWindow = testWindow(pid: 5402)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([kept, minimizedWindow]) { window in
                window.pid == 5401 ? trackable : minimized
            }
            check(cleaned.windows.map(\.pid) == [5401], "clean drops minimized windows")
        }

        do {
            let kept = testWindow(pid: 5501)
            let panelWindow = testWindow(pid: 5502)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([kept, panelWindow]) { window in
                window.pid == 5501 ? trackable : panel
            }
            check(cleaned.windows.map(\.pid) == [5501], "clean drops non-standard windows")
        }

        do {
            let fullscreen = WindowAttributes(
                role: kAXWindowRole,
                subrole: kAXStandardWindowSubrole,
                minimized: false,
                fullscreen: true
            )
            let window = testWindow(pid: 5601)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([window]) { _ in fullscreen }
            check(cleaned.windows.map(\.pid) == [5601], "clean keeps trackable fullscreen windows")
            check(cleaned.snapshots.first?.isFullscreen == true, "clean snapshots preserve fullscreen attribute")
            check(cleaned.snapshots.first?.isTileable == false, "clean snapshots mark fullscreen as not tileable")
        }

        do {
            let first = testWindow(pid: 5701)
            let second = testWindow(pid: 5702)
            var attributeReads = 0
            let cleaned = Monitor.cleanActiveWorkspaceWindows([first, second, first]) { _ in
                attributeReads += 1
                return trackable
            }
            check(cleaned.windows.map(\.pid) == [5701, 5702], "clean keeps first occurrence when duplicate appears later")
            check(attributeReads == 2, "clean skips attribute reads for duplicate identities")
            check(cleaned.snapshots[0].attributes.isTrackable, "clean reuses attributes snapshot for kept windows")
        }

        do {
            let window = testWindow(pid: 5801)
            var attributeReads = 0
            let cleaned = Monitor.cleanActiveWorkspaceWindows([window, window]) { _ in
                attributeReads += 1
                return attributeReads == 1 ? minimized : trackable
            }
            check(cleaned.windows.map(\.pid) == [5801], "clean can keep a later duplicate if the first snapshot is not trackable")
            check(attributeReads == 2, "clean does not mark unkept duplicate identities as seen")
        }
    }

    private static func testWindow(pid: pid_t) -> TrackedWindow {
        TrackedWindow(
            element: AXUIElementCreateApplication(pid),
            pid: pid,
            group: WindowGroupKey(pid: pid, frame: .null)
        )
    }
}
