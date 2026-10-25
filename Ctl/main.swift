import Foundation
import PilesCore

private func printUsage() {
    fputs(
        """
        usage: piles-ctl [--socket PATH] <command>
        commands:
          ping
          workspace <1-9> [--move]
          workspace next|prev [--move]
          workspace last
          overview
          glance
          focus next|prev
          window move next|prev
          layout toggle
          master swap
          monitor focus next|prev
          monitor move next|prev

        """,
        stderr
    )
}

private func parseArgs(_ args: [String]) -> (socketPath: String?, command: String)? {
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
    return (socketPath, commandParts.joined(separator: " "))
}

@main
enum PilesCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let parsed = parseArgs(args) else {
            printUsage()
            exit(2)
        }

        Config.load()
        let path: String
        if let override = parsed.socketPath {
            path = NSString(string: override).expandingTildeInPath
        } else {
            path = Config.shared.expandedIPCSocketPath
        }

        let command = parsed.command + "\n"
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
