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

        return (passed, failed)
    }
}
