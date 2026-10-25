import Foundation
import PilesCore

private func printUsage() {
    fputs(
        """
        usage: piles-ctl [--socket PATH] <command>
        commands:
          ping
          status
          windows
          rescan
          rescue
          config validate [PATH]
          workspace <1-9> [--move]
          workspace next|prev [--move]
          workspace last
          overview
          glance
          focus next|prev
          window move next|prev
          window close
          layout toggle
          master swap
          monitor focus next|prev
          monitor move next|prev

        """,
        stderr
    )
}

private func parseArgs(_ args: [String]) -> (socketPath: String?, commandParts: [String])? {
    var socketPath: String?
    var commandParts: [String] = []
    var index = args.startIndex

    while index < args.endIndex {
        let arg = args[index]
        if arg == "--socket" {
            index = args.index(after: index)
            guard index < args.endIndex else { return nil }
            socketPath = args[index]
            index = args.index(after: index)
            continue
        }
        if arg == "-h" || arg == "--help" {
            return nil
        }
        commandParts.append(arg)
        index = args.index(after: index)
    }

    guard !commandParts.isEmpty else { return nil }
    return (socketPath, commandParts)
}

private func validateConfig(at explicitPath: String?) -> Int32 {
    let path = explicitPath.map { NSString(string: $0).expandingTildeInPath } ?? Config.defaultPath
    do {
        let diagnostics = ConfigParser.validate(text: try String(contentsOfFile: path, encoding: .utf8))
        guard diagnostics.isEmpty else {
            for diagnostic in diagnostics {
                fputs("piles-ctl: \(path): \(diagnostic)\n", stderr)
            }
            return 1
        }
        print("configuration valid: \(path)")
        return 0
    } catch {
        let error = error as NSError
        if explicitPath == nil, error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            print("configuration valid: using defaults, no file at \(path)")
            return 0
        }
        fputs("piles-ctl: could not read \(path): \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func rescueWindows() -> Int32 {
    guard let executable = Bundle.main.executableURL else {
        fputs("piles-ctl: could not locate the running executable\n", stderr)
        return 1
    }
    let companion = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("piles")
    guard FileManager.default.isExecutableFile(atPath: companion.path) else {
        fputs("piles-ctl: could not find piles beside piles-ctl; run make install\n", stderr)
        return 1
    }
    let process = Process()
    process.executableURL = companion
    process.arguments = ["--rescue"]
    do {
        try process.run()
    } catch {
        fputs("piles-ctl: could not start rescue: \(error.localizedDescription)\n", stderr)
        return 1
    }
    process.waitUntilExit()
    return process.terminationReason == .exit ? process.terminationStatus : 1
}

@main
enum PilesCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let parsed = parseArgs(args) else {
            printUsage()
            exit(2)
        }

        if parsed.commandParts.first == "config" {
            guard parsed.socketPath == nil,
                  (2...3).contains(parsed.commandParts.count),
                  parsed.commandParts[1] == "validate" else {
                printUsage()
                exit(2)
            }
            exit(validateConfig(at: parsed.commandParts.count == 3 ? parsed.commandParts[2] : nil))
        }
        if parsed.commandParts.first == "rescue" {
            guard parsed.socketPath == nil, parsed.commandParts.count == 1 else {
                printUsage()
                exit(2)
            }
            exit(rescueWindows())
        }

        Config.load()
        let path: String
        if let override = parsed.socketPath {
            path = NSString(string: override).expandingTildeInPath
        } else {
            path = Config.shared.expandedIPCSocketPath
        }

        let command = parsed.commandParts.joined(separator: " ") + "\n"
        switch IPCClient.request(command, socketPath: path) {
        case .success(let response):
            print(response.trimmingCharacters(in: .newlines))
            exit(response.hasPrefix("error:") ? 1 : 0)
        case .failure(let error):
            fputs("piles-ctl: \(error.message)\n", stderr)
            exit(1)
        }
    }
}
