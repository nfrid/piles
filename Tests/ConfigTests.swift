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
            workspace_count = 4

            [[assign]]
            app = "Terminal"
            workspace = 2
            position = 1

            [[assign]]
            bundle_id = "com.apple.Safari"
            title_contains = "Docs"
            monitor = 2
            workspace = 3
            position = 2
            """)

            check(Config.shared.assignments.count == 2, "loads window assignments")
            let terminal = Config.shared.assignment(app: "Terminal", bundleID: nil, title: "zsh")
            check(terminal?.workspace == 2, "matches app assignment")
            check(terminal?.position == 1, "loads assignment position")

            let safari = Config.shared.assignment(
                app: "Safari",
                bundleID: "com.apple.Safari",
                title: "Apple Developer Docs"
            )
            check(safari?.monitor == 2, "loads assignment monitor")
            check(safari?.workspace == 3, "matches bundle and title_contains assignment")
            check(Config.shared.assignment(app: "Safari", bundleID: "com.apple.Safari", title: "News") == nil, "rejects title mismatch")
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

        do {
            var diagnostics: [String] = []
            let config = ConfigParser.parse(text: """
            workspace_count = 0

            [bindings]
            focus_next = "notakey"

            [[custom]]
            key = "shift+nope"
            command = "true"

            [[assign]]
            position = 0
            """) { diagnostics.append($0) }

            check(config != nil, "invalid values still produce fallback config")
            check(diagnostics.contains("workspace_count must be between 1 and 9, using 9"), "captures workspace diagnostic")
            check(diagnostics.contains("unknown key 'notakey' for binding 'focus_next'"), "captures binding diagnostic")
            check(diagnostics.contains("unknown key 'shift+nope' in custom binding"), "captures custom binding diagnostic")
            check(diagnostics.contains("assignment needs app, bundle_id, title, or title_contains"), "captures assignment diagnostic")
        }

        do {
            let before = Config.shared
            var diagnostics: [String] = []
            Config.load(text: "workspace_count =")
            check(Config.shared.workspaceCount == before.workspaceCount, "load keeps existing config on parse error")

            let parsed = ConfigParser.parse(text: "workspace_count =") {
                diagnostics.append($0)
            }
            check(parsed == nil, "parser returns nil on TOML parse error")
            check(diagnostics.count == 1, "parser reports parse error once")
            check(diagnostics[0].hasPrefix("config parse error:"), "parser captures parse error diagnostic")
        }

        Config.shared = Config()
        return (passed, failed)
    }
}
