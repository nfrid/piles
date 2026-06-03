import CoreGraphics
@testable import PilesCore

enum MonitorStateTests {
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

        do {
            let screen = CGRect(x: 0, y: 0, width: 100, height: 80)
            let frame = CGRect(x: 120, y: 10, width: 40, height: 30)
            let clamped = WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: screen)
            check(clamped.origin.x == 60, "frame clamp moves x inside screen")
            check(clamped.origin.y == 10, "frame clamp preserves y when in bounds")
            check(clamped.size == frame.size, "frame clamp preserves size")
        }

        do {
            let screen = CGRect(x: 0, y: 0, width: 100, height: 80)
            let frame = CGRect(x: 10, y: 90, width: 40, height: 30)
            let clamped = WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: screen)
            check(clamped.origin.y == 50, "frame clamp moves y inside screen")
        }

        do {
            check(WorkspaceWindows.moveIndex(1, offset: 1, count: 4) == 2, "moveIndex advances within range")
            check(WorkspaceWindows.moveIndex(0, offset: -1, count: 4) == 3, "moveIndex wraps backward")
        }

        do {
            var state = MonitorState(count: 3, defaultLayout: .tile)
            check(state.clampedFocus(in: 0) == 0, "clamped focus is zero for empty workspace")
            check(state.clampedFocus(in: 9) == 0, "clamped focus ignores invalid workspace")

            state.workspaces[1] = [
                testWindow(pid: 4001),
                testWindow(pid: 4002),
                testWindow(pid: 4003),
            ]
            state.focusedIndices[1] = 5
            check(state.clampedFocus(in: 1) == 2, "clamped focus caps high index")

            state.focusedIndices[1] = -2
            check(state.clampedFocus(in: 1) == 0, "clamped focus floors low index")
        }

        do {
            var state = MonitorState(count: 3, defaultLayout: .tile)
            state.active = 1
            let focused = testWindow(pid: 4101)
            let other = testWindow(pid: 4102)
            state.workspaces[1] = [other, focused]

            check(state.removeActiveWindow(matching: focused)?.pid == 4101, "removeActiveWindow returns removed window")
            check(state.workspaces[1].map(\.pid) == [4102], "removeActiveWindow updates active workspace")

            state.workspaces[1] = [focused]
            let moved = state.moveActiveWindow(matching: focused, to: 2)
            check(moved?.pid == 4101, "moveActiveWindow returns moved window")
            check(state.workspaces[1].isEmpty, "moveActiveWindow clears source workspace")
            check(state.workspaces[2].map(\.pid) == [4101], "moveActiveWindow inserts at front of target")
            check(state.focusedIndices[2] == 0, "moveActiveWindow resets target focus index")
        }

        do {
            var state = MonitorState(count: 2, defaultLayout: .tile)
            let a = testWindow(pid: 4201)
            let b = testWindow(pid: 4202)
            state.workspaces[0] = [a, b]
            state.focusedIndices[0] = 0

            check(state.rememberFocusedWindow(b), "rememberFocusedWindow updates matching entry")
            check(state.focusedIndices[0] == 1, "rememberFocusedWindow moves focus to remembered window")
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
