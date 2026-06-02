import ApplicationServices
import CoreGraphics
@testable import PilesCore

enum WindowGroupTests {
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

        let frame = CGRect(x: 256, y: 128, width: 960, height: 640)

        do {
            let shifted = CGRect(x: 259, y: 131, width: 956, height: 643)
            check(WindowFrameKey(frame) == WindowFrameKey(shifted), "small frame drift keeps group")
        }

        do {
            let shifted = CGRect(x: 288, y: 128, width: 960, height: 640)
            check(WindowFrameKey(frame) != WindowFrameKey(shifted), "large frame drift changes group")
        }

        do {
            let left = WindowGroupKey(pid: 10, frame: frame)
            let right = WindowGroupKey(pid: 11, frame: frame)
            check(left != right, "pid separates equal frames")
        }

        do {
            let left = testWindow(pid: 2001)
            let right = testWindow(pid: 2001)
            check(left == right, "equivalent AX elements identify same tracked window")
            check(left.containsElement(AXUIElementCreateApplication(2001)), "contains equivalent AX reference")
        }

        do {
            let a = AXUIElementCreateApplication(2101)
            let b = AXUIElementCreateApplication(2102)
            let left = TrackedWindow(
                element: a,
                pid: 2100,
                members: [a, b],
                group: WindowGroupKey(pid: 2100, frame: .null)
            )
            let right = TrackedWindow(
                element: a,
                pid: 2100,
                members: [b, a],
                group: WindowGroupKey(pid: 2100, frame: .null)
            )
            check(left.hasSameMembers(right), "member comparison ignores order")
            check(left.members.count == 2, "members are deduplicated")
        }

        do {
            let windows = [
                testWindow(pid: 1001),
                testWindow(pid: 1002),
                testWindow(pid: 1003),
            ]
            var focusedIndex = 1
            let remaining = Monitor.windowsAfterRemoving(from: windows, focusedIndex: &focusedIndex) { $0.pid == 1001 }
            check(remaining.map(\.pid) == [1002, 1003], "removes minimized window")
            check(focusedIndex == 0, "focused index follows selected window after earlier removal")
        }

        do {
            let windows = [
                testWindow(pid: 1001),
                testWindow(pid: 1002),
                testWindow(pid: 1003),
            ]
            var focusedIndex = 0
            let remaining = Monitor.windowsAfterRemoving(from: windows, focusedIndex: &focusedIndex) { $0.pid == 1001 }
            check(remaining.map(\.pid) == [1002, 1003], "removes focused minimized window")
            check(focusedIndex == 0, "focused removal selects replacement at same position")
        }

        do {
            check(Monitor.wrappedIndex(-1, count: 3) == 2, "moving first window prev wraps to last")
            check(Monitor.wrappedIndex(3, count: 3) == 0, "moving last window next wraps to first")
        }

        do {
            let windows = [
                testWindow(pid: 3301),
                testWindow(pid: 3302),
                testWindow(pid: 3303),
                testWindow(pid: 3304),
            ]

            let lastMovedDown = Monitor.windowsByMoving(windows, from: 3, offset: 1)
            check(lastMovedDown.items.map(\.pid) == [3304, 3301, 3302, 3303], "moving last window next rotates it to front")
            check(lastMovedDown.movedIndex == 0, "moving last window next focuses wrapped front")

            let firstMovedUp = Monitor.windowsByMoving(windows, from: 0, offset: -1)
            check(firstMovedUp.items.map(\.pid) == [3302, 3303, 3304, 3301], "moving first window prev rotates it to back")
            check(firstMovedUp.movedIndex == 3, "moving first window prev focuses wrapped back")

            let middleMovedDown = Monitor.windowsByMoving(windows, from: 1, offset: 1)
            check(middleMovedDown.items.map(\.pid) == [3301, 3303, 3302, 3304], "moving middle window next reorders adjacent windows")
            check(middleMovedDown.movedIndex == 2, "moving middle window next focuses moved position")
        }

        do {
            var state = MonitorState(count: 3, defaultLayout: .monocle)
            let previous = state.activate(2)
            check(previous == 0, "state activation returns previous workspace")
            check(state.active == 2, "state activation changes active workspace")
            check(state.previousActive == 0, "state activation records previous workspace")
            check(state.activate(2) == nil, "state activation ignores current workspace")
            check(state.activate(4) == nil, "state activation rejects out-of-range workspace")
        }

        do {
            var state = MonitorState(count: 3, defaultLayout: .monocle)
            let a = testWindow(pid: 3001)
            let b = testWindow(pid: 3002)
            let c = testWindow(pid: 3003)

            state.insertWindow(a)
            state.insertWindow(b, workspace: 2, position: 5)
            state.insertWindow(c, workspace: 2, position: 1)

            check(state.workspaces[0].map(\.pid) == [3001], "state inserts into active workspace by default")
            check(state.workspaces[1].map(\.pid) == [3003, 3002], "state clamps insertion positions")
        }

        do {
            var state = MonitorState(count: 3, defaultLayout: .monocle)
            let a = testWindow(pid: 3101)
            let b = testWindow(pid: 3102)
            let c = testWindow(pid: 3103)
            state.workspaces[0] = [a, b, c]
            state.focusedIndices[0] = 2

            let result = state.removeWindows { $0.pid == 3102 }

            check(result.changed, "state reports removed windows")
            check(result.activeChanged, "state reports active workspace removal")
            check(state.workspaces[0].map(\.pid) == [3101, 3103], "state removes matching windows")
            check(state.focusedIndices[0] == 1, "state repairs focus index after removal")
        }

        do {
            var state = MonitorState(count: 4, defaultLayout: .tile)
            let a = testWindow(pid: 3201)
            let b = testWindow(pid: 3202)
            let c = testWindow(pid: 3203)
            state.workspaces[0] = [a]
            state.workspaces[2] = [b]
            state.workspaces[3] = [c]
            state.active = 3
            state.previousActive = 2

            state.resize(to: 2, defaultLayout: .monocle)

            check(state.workspaces.count == 2, "state shrinks workspace count")
            check(state.active == 1, "state clamps active workspace on shrink")
            check(state.previousActive == 1, "state clamps previous workspace on shrink")
            check(state.workspaces[1].map(\.pid) == [3202, 3203], "state preserves overflow windows on shrink")

            state.resize(to: 4, defaultLayout: .monocle)

            check(state.workspaces.count == 4, "state grows workspace count")
            check(state.layouts[2] == .monocle, "state uses supplied layout for new workspaces")
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
