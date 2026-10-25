import CoreGraphics
import Foundation
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
            let text = """
            [bindings]
            toggle_pause = "shift+p"
            toggle_floating = "f"
            [[assign]]
            title_contains = "Settings"
            floating = true
            [[assign]]
            app = "Terminal"
            floating = false
            workspace = 2
            [[assign]]
            app = "Finder"
            workspace = 1
            """
            check(ConfigParser.validate(text: text).isEmpty, "pause and floating configuration validates")
            if let config = ConfigParser.parse(text: text) {
                check(config.bindings.togglePause == (Key.p, true) && config.bindings.toggleFloating == (Key.f, false),
                      "pause and floating bindings use the existing parser")
                check(config.assignment(app: "Terminal", bundleID: nil, title: "Settings")?.floating == true,
                      "first matching floating rule wins")
                check(config.assignment(app: "Terminal", bundleID: nil, title: "Shell")?.floating == false,
                      "explicit tiled assignment is preserved")
                check(config.assignments.count == 3 && config.assignments[2].floating == nil,
                      "old assignment rules do not implicitly specify a floating mode")
            } else {
                check(false, "new window mode configuration parses")
            }
            check(ConfigParser.validate(text: "[[assign]]\napp = \"Terminal\"\nfloating = \"yes\"")
                .contains(where: { $0.contains("floating") && $0.contains("boolean") }), "floating rule requires a boolean")
        }

        do {
            let valid = ConfigParser.validate(text: """
            workspace_count = 3
            master_ratio = 0.6
            default_layout = "tile"
            modifier = "control"
            ipc_enabled = true
            ipc_socket = "~/tmp/piles.sock"
            accent_color = "teal"
            [bindings]
            focus_next = "shift+l"
            [[custom]]
            key = "shift+t"
            command = "true"
            [[assign]]
            app = "Terminal"
            workspace = 2
            [[workspace]]
            index = 1
            name = "Code"
            color = "orange"
            """)
            check(valid.isEmpty, "validates supported configuration")
            let previous = Config.shared
            let invalid = ConfigParser.validate(text: "workspace_count = 0")
            check(invalid.contains("workspace_count must be between 1 and 9, using 9"), "validation reports fallback diagnostics")
            check(Config.shared.workspaceCount == previous.workspaceCount, "validation does not mutate shared configuration")
            check(ConfigParser.validate(text: "workspace_count =").first?.hasPrefix("config parse error:") == true,
                  "validation reports malformed syntax")
            check(ConfigParser.validate(text: "bindings = 1").contains("bindings must be a table"),
                  "validation reports wrong root table shape")
            check(ConfigParser.validate(text: "[[custom]]").contains("custom binding needs key and command"),
                  "validation reports missing required custom fields")

            let unknown = ConfigParser.validate(text: """
            extra = 1
            workspace_count = "3"
            [bindings]
            bogus = "j"
            move_next = 3
            [[custom]]
            key = 2
            command = "true"
            extra = false
            [[assign]]
            app = 4
            mystery = "x"
            [[workspace]]
            index = "1"
            color = false
            extra = 1
            """)
            check(unknown.contains("unknown key 'extra' in root"), "validation reports unknown root keys")
            check(unknown.contains("unknown key 'bogus' in bindings"), "validation reports unknown binding keys")
            check(unknown.contains(where: { $0.contains("workspace_count") && $0.contains("integer") }), "validation reports wrong root types")
            check(unknown.contains(where: { $0.contains("move_next") && $0.contains("string") }), "validation reports wrong binding types")
            check(unknown.contains(where: { $0.contains("unknown key 'extra' in custom entry") }), "validation reports unknown custom keys")
            check(unknown.contains(where: { $0.contains("unknown key 'mystery' in assign entry") }), "validation reports unknown assignment keys")
            check(unknown.contains(where: { $0.contains("unknown key 'extra' in workspace entry") }), "validation reports unknown workspace keys")
            check(unknown.contains(where: { $0.contains("custom entry") && $0.contains("key") }), "validation reports wrong custom field types")
            check(unknown.contains(where: { $0.contains("assign entry") && $0.contains("app") }), "validation reports wrong assignment field types")
            check(unknown.contains(where: { $0.contains("workspace entry") && $0.contains("index") }), "validation reports wrong workspace field types")
            check(unknown.contains(where: { $0.contains("workspace entry") && $0.contains("color") }), "validation reports wrong workspace color type")

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
            let config = ConfigParser.parse(text: "master_ratio = 1") {
                diagnostics.append($0)
            }
            check(abs((config?.masterRatio ?? 0) - 0.55) < 0.001, "rejects integer master ratio endpoint")
            check(
                diagnostics.contains("master_ratio must be between 0.1 and 0.9, using 0.55"),
                "diagnoses integer master ratio endpoint with safe bounds"
            )

            let low = LayoutSettings(masterRatio: 0).masterRatio
            let high = LayoutSettings(masterRatio: 1).masterRatio
            check(low == LayoutSettings.minimumMasterRatio, "layout clamps master ratio low endpoint")
            check(high == LayoutSettings.maximumMasterRatio, "layout clamps master ratio high endpoint")
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
            check(Config.load(text: "workspace_count = 2\r\nmaster_ratio = 0.6"), "returns success for CRLF config")
            check(Config.shared.workspaceCount == 2, "parses CRLF lines")
            let strings = (try? Toml.parse(#"""
            quote = "open -a \"Google Chrome\""
            backslash = "\\"
            controls = "tab\tline\nnext\r"
            hash = "inside # string" # comment
            """#)) ?? [:]
            check(strings["quote"] as? String == "open -a \"Google Chrome\"", "decodes escaped quote in command")
            check(strings["backslash"] as? String == "\\", "decodes escaped backslash")
            check(strings["controls"] as? String == "tab\tline\nnext\r", "decodes tab, newline, and carriage return")
            check(strings["hash"] as? String == "inside # string", "preserves hash in string and strips trailing comment")
            check(Config.load(text: #"""
            workspace_count = 3
            [[custom]]
            key = "t"
            command = "open -a \"Google Chrome\""
            """#), "loads a custom shell command with escaped quotes")
            check(Config.shared.customBindings.first?.command == "open -a \"Google Chrome\"", "config preserves decoded shell quoting")
            var before = Config.shared
            check(!Config.load(text: #"command = "bad\q""#), "returns failure for invalid escape")
            check(Config.shared.workspaceCount == before.workspaceCount, "invalid escape retains previous config")
            check(!Config.load(text: #"command = "bad"tail"#), "returns failure for trailing string tokens")
            check(!Config.load(text: #"command = "bad"quote""#), "returns failure for unescaped quote")
            before = Config.shared
            check(!Config.load(text: "workspace_count ="), "returns failure on parse error")
            check(Config.shared.workspaceCount == before.workspaceCount, "load keeps existing config on parse error")

            var diagnostics: [String] = []
            let parsed = ConfigParser.parse(text: "workspace_count =") {
                diagnostics.append($0)
            }
            check(parsed == nil, "parser returns nil on TOML parse error")
            check(diagnostics.count == 1, "parser reports parse error once")
            check(diagnostics[0].hasPrefix("config parse error:"), "parser captures parse error diagnostic")
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piles-config-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config.toml")
            try "workspace_count = 2".write(to: file, atomically: true, encoding: .utf8)
            check(Config.load(path: file.path), "loads configuration from a file")
            check(Config.shared.workspaceCount == 2, "applies the file's configuration")
            try Data([0xFF]).write(to: file)
            check(!Config.load(path: file.path), "invalid UTF-8 reports a read failure")
            check(Config.shared.workspaceCount == 2, "read failure preserves the active configuration")
            check(!Config.load(path: directory.path), "an unreadable config path is not treated as a missing file")
            check(Config.shared.workspaceCount == 2, "an unreadable path preserves the active configuration")
            try FileManager.default.removeItem(at: file)
            check(Config.load(path: file.path), "missing optional config is a successful load")
            check(Config.shared.workspaceCount == Config().workspaceCount, "missing config resets to defaults")
        } catch {
            check(false, "configuration file tests failed: \(error)")
        }

        Config.shared = Config()
        return (passed, failed)
    }
}
