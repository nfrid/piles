package enum IPCCommandParser {
    package enum ParseError: Error, Equatable {
        case invalid(String)
    }

    package static func parse(_ line: String, workspaceCount: Int) -> Result<HotkeyAction, ParseError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalid("empty command"))
        }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = parts.first?.lowercased() else {
            return .failure(.invalid("empty command"))
        }

        switch verb {
        case "ping":
            guard parts.count == 1 else { return .failure(.invalid("ping takes no arguments")) }
            return .success(.passThrough)

        case "workspace":
            return parseWorkspace(parts.dropFirst(), workspaceCount: workspaceCount)

        case "overview":
            guard parts.count == 1 else { return .failure(.invalid("overview takes no arguments")) }
            return .success(.toggleWorkspaceOverview)

        case "glance":
            guard parts.count == 1 else { return .failure(.invalid("glance takes no arguments")) }
            return .success(.toggleWorkspaceGlance)

        case "focus":
            return parseFocus(parts.dropFirst())

        case "window":
            return parseWindow(parts.dropFirst())

        case "layout":
            return parseLayout(parts.dropFirst())

        case "master":
            return parseMaster(parts.dropFirst())

        case "monitor":
            return parseMonitor(parts.dropFirst())

        default:
            return .failure(.invalid("unknown command '\(verb)'"))
        }
    }

    package static func isPing(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ping"
    }

    private static func parseWorkspace(
        _ parts: ArraySlice<String>,
        workspaceCount: Int
    ) -> Result<HotkeyAction, ParseError> {
        guard let sub = parts.first?.lowercased() else {
            return .failure(.invalid("workspace needs a subcommand"))
        }

        let moveWindow = parts.contains { $0.lowercased() == "--move" }

        switch sub {
        case "last":
            guard parts.count == 1 || (parts.count == 2 && moveWindow) else {
                return .failure(.invalid("workspace last takes no arguments besides --move"))
            }
            guard !moveWindow else {
                return .failure(.invalid("workspace last does not support --move"))
            }
            return .success(.switchToLast)

        case "next", "prev":
            let extra = parts.dropFirst().map { $0.lowercased() }
            let allowed = Set(["--move"])
            guard extra.allSatisfy({ allowed.contains($0) }) else {
                return .failure(.invalid("workspace \(sub) only supports --move"))
            }
            let offset = sub == "next" ? 1 : -1
            return .success(.switchToOccupied(offset: offset, movingFocusedWindow: moveWindow))

        default:
            guard let number = Int(sub), number >= 1, number <= workspaceCount else {
                return .failure(.invalid("workspace index must be 1-\(workspaceCount)"))
            }
            let trailing = parts.dropFirst()
            guard trailing.isEmpty || (trailing.count == 1 && trailing.first?.lowercased() == "--move") else {
                return .failure(.invalid("workspace <n> only supports --move"))
            }
            let index = number - 1
            if moveWindow {
                return .success(.moveActiveWindowTo(index))
            }
            return .success(.switchTo(index))
        }
    }

    private static func parseFocus(_ parts: ArraySlice<String>) -> Result<HotkeyAction, ParseError> {
        guard parts.count == 1, let dir = parts.first?.lowercased() else {
            return .failure(.invalid("focus expects: next | prev"))
        }
        switch dir {
        case "next": return .success(.focusNext)
        case "prev": return .success(.focusPrev)
        default: return .failure(.invalid("focus expects: next | prev"))
        }
    }

    private static func parseWindow(_ parts: ArraySlice<String>) -> Result<HotkeyAction, ParseError> {
        guard parts.count == 2,
              parts.first?.lowercased() == "move",
              let dir = parts.dropFirst().first?.lowercased()
        else {
            return .failure(.invalid("window expects: move next | move prev"))
        }
        switch dir {
        case "next": return .success(.moveFocusedWindowNext)
        case "prev": return .success(.moveFocusedWindowPrev)
        default: return .failure(.invalid("window expects: move next | move prev"))
        }
    }

    private static func parseLayout(_ parts: ArraySlice<String>) -> Result<HotkeyAction, ParseError> {
        guard parts.count == 1, parts.first?.lowercased() == "toggle" else {
            return .failure(.invalid("layout expects: toggle"))
        }
        return .success(.toggleLayout)
    }

    private static func parseMaster(_ parts: ArraySlice<String>) -> Result<HotkeyAction, ParseError> {
        guard parts.count == 1, parts.first?.lowercased() == "swap" else {
            return .failure(.invalid("master expects: swap"))
        }
        return .success(.swapMaster)
    }

    private static func parseMonitor(_ parts: ArraySlice<String>) -> Result<HotkeyAction, ParseError> {
        guard parts.count == 2,
              let kind = parts.first?.lowercased(),
              let dir = parts.dropFirst().first?.lowercased()
        else {
            return .failure(.invalid("monitor expects: focus next|prev | move next|prev"))
        }
        let offset: Int
        switch dir {
        case "next": offset = 1
        case "prev": offset = -1
        default: return .failure(.invalid("monitor expects: focus next|prev | move next|prev"))
        }
        switch kind {
        case "focus": return .success(.focusMonitor(offset))
        case "move": return .success(.moveWindowToMonitor(offset))
        default: return .failure(.invalid("monitor expects: focus next|prev | move next|prev"))
        }
    }
}
