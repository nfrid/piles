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
            monitor.paused = true
            let kept = testWindow(pid: 5001)
            let removed = testWindow(pid: 5002)
            monitor.state.workspaces[0] = [kept, removed]

            check(
                monitor.removeStaleWindows(pid: 5002, current: [kept], isConfirmedInvalid: { $0.pid == 5002 }),
                "removeStaleWindows reports change"
            )
            check(
                monitor.state.workspaces[0].map(\.pid) == [5001],
                "removeStaleWindows drops confirmed-invalid windows missing from sync list"
            )

            monitor.state.workspaces[0] = [removed]
            check(
                !monitor.removeStaleWindows(pid: 5002, current: [], attributesFor: { _ in nil }) { _ in false },
                "removeStaleWindows retains windows after uncertain AX errors"
            )

            let dialog = testWindow(pid: 5003)
            let unknown = testWindow(pid: 5004)
            let standard = testWindow(pid: 5005)
            monitor.state.workspaces[0] = [dialog, unknown, standard]
            let dialogAttributes = WindowAttributes(
                role: kAXWindowRole, subrole: kAXDialogSubrole,
                minimized: false, fullscreen: false
            )
            let standardAttributes = WindowAttributes(
                role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                minimized: false, fullscreen: false
            )
            check(
                monitor.removeStaleWindows(pid: 5003, current: [], attributesFor: { window in
                    window == standard ? standardAttributes : (window == dialog ? dialogAttributes : nil)
                }, isConfirmedInvalid: { _ in false }),
                "stale cleanup removes a live window with known untrackable dialog attributes"
            )
            check(monitor.state.workspaces[0] == [unknown, standard], "stale cleanup preserves unknown and standard windows")
            monitor.state.workspaces[0] = [unknown]
            let partialAttributes = WindowAttributes(
                role: kAXWindowRole, subrole: nil, minimized: false, fullscreen: false
            )
            check(
                !monitor.removeStaleWindows(pid: 5004, current: [], attributesFor: { _ in partialAttributes }) { _ in false },
                "stale cleanup preserves partially known role attributes"
            )
            monitor.state.workspaces[0] = [standard]
            check(
                !monitor.removeStaleWindows(pid: 5005, current: [], attributesFor: { _ in standardAttributes }) { _ in false },
                "stale cleanup retains an absent but still-valid standard window of the same PID"
            )
            let unknownMinimized = WindowAttributes(
                role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                minimized: false, fullscreen: false, minimizedKnown: false
            )
            check(
                !monitor.removeStaleWindows(pid: 5005, current: [], attributesFor: { _ in unknownMinimized }) { _ in false },
                "stale cleanup retains standard windows when minimized state is unknown"
            )
        }

        do {
            let monitor = Monitor(displayID: 0, screen: screen)
            let invalid = testWindow(pid: 5051)
            let live = testWindow(pid: 5052)
            monitor.state.workspaces[0] = [invalid, live]
            monitor.state.focusedIndices[0] = 1
            var notifications = 0
            monitor.onStateChange = { notifications += 1 }
            _ = monitor.cleanActiveWorkspace(
                attributesFor: { _ in nil },
                isConfirmedInvalid: { $0 == invalid }
            )
            check(monitor.state.workspaces[0] == [live], "cleanup removes confirmed-invalid window and preserves live uncertain window")
            check(monitor.state.focusedIndices[0] == 0, "cleanup repairs focus after invalid removal")
            check(notifications == 1, "cleanup notifies workspace owner after membership and focus change")

            monitor.state.workspaces[0] = [invalid, live]
            monitor.state.focusedIndices[0] = 1
            _ = monitor.cleanActiveWorkspace(
                applyChanges: false,
                attributesFor: { _ in nil },
                isConfirmedInvalid: { $0 == invalid }
            )
            check(monitor.state.workspaces[0] == [invalid, live], "non-mutating cleanup leaves workspace membership unchanged")
            check(monitor.state.focusedIndices[0] == 1, "non-mutating cleanup leaves focus unchanged")
            check(notifications == 1, "non-mutating cleanup does not notify workspace owner")
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
            let unknown = testWindow(pid: 5251)
            let cleaned = Monitor.cleanActiveWorkspaceWindows([unknown]) { _ in nil }
            check(cleaned.windows == [unknown], "clean retains a window after an uncertain AX read")
            check(cleaned.snapshots.isEmpty, "clean excludes unknown windows from geometry snapshots")

            let unknownMinimized = WindowAttributes(
                role: kAXWindowRole,
                subrole: kAXStandardWindowSubrole,
                minimized: false,
                fullscreen: false,
                minimizedKnown: false
            )
            let minimizedReadFailed = Monitor.cleanActiveWorkspaceWindows([unknown]) { _ in unknownMinimized }
            check(minimizedReadFailed.windows == [unknown], "clean retains a standard window when minimized read fails")
            check(minimizedReadFailed.snapshots.isEmpty, "clean excludes unknown minimized state from geometry")

            let missingSubrole = WindowAttributes(
                role: kAXWindowRole,
                subrole: nil,
                minimized: false,
                fullscreen: false
            )
            let partialRole = Monitor.cleanActiveWorkspaceWindows([unknown]) { _ in missingSubrole }
            check(partialRole.windows == [unknown], "clean retains a window when role or subrole is unknown")
            check(partialRole.snapshots.isEmpty, "clean excludes partial role data from geometry")

            let invalid = Monitor.cleanActiveWorkspaceWindows(
                [unknown],
                attributesFor: { _ in nil },
                isConfirmedInvalid: { _ in true }
            )
            check(invalid.windows.isEmpty, "clean removes nil-attribute windows confirmed invalid")

            let unknownFullscreen = WindowAttributes(
                role: kAXWindowRole,
                subrole: kAXStandardWindowSubrole,
                minimized: false,
                fullscreen: false,
                fullscreenKnown: false
            )
            check(!unknownFullscreen.isTileable, "unknown fullscreen state prevents geometry writes")
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

        do {
            let before = testWindow(pid: 5901)
            let focused = testWindow(pid: 5902)
            let duplicateFocused = testWindow(pid: 5902)
            var focusedIndex = 2
            let cleaned = Monitor.cleanActiveWorkspaceWindows(
                [before, focused, duplicateFocused],
                focusedIndex: &focusedIndex
            ) { _ in trackable }
            check(cleaned.windows.map(\.pid) == [5901, 5902], "clean removes duplicate after focused window")
            check(focusedIndex == 1, "clean preserves focused identity after duplicate removal")

            let stale = testWindow(pid: 5903)
            focusedIndex = 1
            let staleCleaned = Monitor.cleanActiveWorkspaceWindows(
                [stale, focused],
                focusedIndex: &focusedIndex
            ) { window in
                window.pid == 5903 ? minimized : trackable
            }
            check(staleCleaned.windows.map(\.pid) == [5902], "clean removes stale window before focused window")
            check(focusedIndex == 0, "clean shifts focus index after stale removal")
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
