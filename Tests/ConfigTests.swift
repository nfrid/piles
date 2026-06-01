import CoreGraphics
@testable import PilesCore

enum ConfigTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                fputs("FAIL \(file):\(line): \(message)\n", stderr)
                failed += 1
            }
        }

        do {
            Config.load(text: """
            workspace_count = 4
            master_ratio = 0.6
            default_layout = "tile"
            modifier = "control"

            [bindings]
            move_next = "shift+l"
            move_prev = "shift+h"
            """)

            check(Config.shared.workspaceCount == 4, "loads workspace count")
            check(Config.shared.numberKeys.count == 4, "trims number key map")
            check(abs(Config.shared.masterRatio - 0.6) < 0.001, "loads master ratio")
            check(Config.shared.defaultLayout == .tile, "loads default layout")
            check(Config.shared.modifier == .maskControl, "loads modifier")
            check(Config.shared.bindings.moveNext == (Key.l, true), "loads move next binding")
            check(Config.shared.bindings.movePrev == (Key.h, true), "loads move prev binding")
        }

        do {
            Config.load(text: """
            workspace_count = 12
            master_ratio = 1.5
            default_layout = "unknown"
            modifier = "unknown"
            """)

            check(Config.shared.workspaceCount == 9, "rejects invalid workspace count")
            check(abs(Config.shared.masterRatio - 0.55) < 0.001, "rejects invalid master ratio")
            check(Config.shared.defaultLayout == .monocle, "rejects invalid layout")
            check(Config.shared.modifier == .maskAlternate, "rejects invalid modifier")
        }

        Config.shared = Config()
        return (passed, failed)
    }
}
