import Foundation
@testable import PilesCore

enum IPCCommandTests {
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

        func resolves(_ line: String, to action: HotkeyAction, workspaceCount: Int = 9) {
            switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
            case .success(let parsed):
                check(parsed == action, "'\(line)' resolves to \(action)")
            case .failure(.invalid(let error)):
                check(false, "'\(line)' failed: \(error)")
            }
        }

        func rejects(_ line: String, workspaceCount: Int = 9) {
            switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
            case .success:
                check(false, "'\(line)' should have failed")
            case .failure:
                check(true, "'\(line)' is rejected")
            }
        }

        check(IPCCommandParser.isPing("ping"), "ping detection")
        check(!IPCCommandParser.isPing("workspace 1"), "non-ping detection")

        resolves("workspace 3", to: .switchTo(2))
        resolves("workspace 3 --move", to: .moveActiveWindowAndSwitchTo(2))
        resolves("workspace next", to: .switchToOccupied(offset: 1, movingFocusedWindow: false))
        resolves("workspace prev --move", to: .switchToOccupied(offset: -1, movingFocusedWindow: true))
        resolves("workspace last", to: .switchToLast)
        resolves("overview", to: .toggleWorkspaceOverview)
        resolves("glance", to: .toggleWorkspaceGlance)
        resolves("focus next", to: .focusNext)
        resolves("window move prev", to: .moveFocusedWindowPrev)
        resolves("layout toggle", to: .toggleLayout)
        resolves("master swap", to: .swapMaster)
        resolves("monitor focus next", to: .focusMonitor(1))

        rejects("workspace 0")
        rejects("workspace 10", workspaceCount: 9)
        rejects("workspace last --move")
        rejects("unknown")

        return (passed, failed)
    }
}
