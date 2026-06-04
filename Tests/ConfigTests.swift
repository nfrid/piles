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
            accent_color = "teal"

            workspace_count = 3

            [[workspace]]
            index = 1
            name = "Code"
            color = "#5AC8FA"

            [[workspace]]
            index = 3
            name = "Comms"
            color = "orange"
            """)

            check(Config.shared.accent.colorHex == "#30B0C7", "loads accent color")
            check(Config.shared.accent.primary == ConfigColorParser.color(fromHex: "#30B0C7"), "resolves accent primary")
            let appearance = Config.shared.appearanceSnapshot
            check(appearance.workspaces.count == 3, "sizes workspace appearances to workspace count")
            check(appearance.workspace(at: 0).name == "Code", "loads workspace name")
            check(appearance.workspace(at: 0).colorHex == "#5AC8FA", "loads workspace hex color")
            check(appearance.workspace(at: 1).name == nil, "leaves unnamed workspaces empty")
            check(appearance.workspace(at: 2).colorHex == "#FF9500", "loads named workspace color")
            check(appearance.uiStyle(forWorkspace: 2).displayName == "Comms", "uses configured display name")
            check(appearance.uiStyle(forWorkspace: 1).displayName == "Workspace 2", "falls back to numbered display name")
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
            var invalidIndexDiagnostics: [String] = []
            _ = ConfigParser.parse(text: """
            workspace_count = 2

            [[workspace]]
            index = 9
            """) { invalidIndexDiagnostics.append($0) }
            check(
                invalidIndexDiagnostics.contains(where: { $0.contains("workspace entry needs index") }),
                "captures invalid workspace index diagnostic"
            )
            check(
                !invalidIndexDiagnostics.contains(where: { $0.contains("assignment workspace") }),
                "workspace index errors do not use assignment diagnostics"
            )

            var invalidColorDiagnostics: [String] = []
            let config = ConfigParser.parse(text: """
            workspace_count = 2

            [[workspace]]
            index = 1
            color = "not-a-color"
            """) { invalidColorDiagnostics.append($0) }

            check(config?.workspaceAppearances.count == 2, "keeps workspace appearance array on invalid color")
            check(
                invalidColorDiagnostics.contains(where: { $0.contains("invalid workspace color") }),
                "captures invalid workspace color diagnostic"
            )

            var invalidAccentDiagnostics: [String] = []
            let accentConfig = ConfigParser.parse(text: """
            accent_color = "not-a-color"
            """) { invalidAccentDiagnostics.append($0) }
            check(accentConfig?.accent.colorHex == nil, "rejects invalid accent color")
            check(
                invalidAccentDiagnostics.contains(where: { $0.contains("invalid accent_color") }),
                "captures invalid accent color diagnostic"
            )
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
