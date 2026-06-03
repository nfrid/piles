import Darwin
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
        switch send(command: command, socketPath: path) {
        case .success(let response):
            print(response.trimmingCharacters(in: .newlines))
            exit(response.hasPrefix("error:") ? 1 : 0)
        case .failure(.message(let message)):
            fputs("piles-ctl: \(message)\n", stderr)
            exit(1)
        }
    }

    private enum ClientError: Error {
        case message(String)
    }

    private static func send(command: String, socketPath: String) -> Result<String, ClientError> {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(.message("socket: \(String(cString: strerror(errno)))"))
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .failure(.message("socket path too long"))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { raw in
                memcpy(ptr, raw.baseAddress!, raw.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED {
                return .failure(.message("could not connect to \(socketPath) (is piles running?)"))
            }
            return .failure(.message("connect: \(String(cString: strerror(errno)))"))
        }

        guard let commandData = command.data(using: .utf8) else {
            return .failure(.message("invalid command encoding"))
        }

        let sendResult = commandData.withUnsafeBytes { raw -> Result<Void, ClientError> in
            guard let base = raw.baseAddress else {
                return .failure(.message("invalid command buffer"))
            }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    return .failure(.message("send: \(String(cString: strerror(errno)))"))
                }
                sent += n
            }
            return .success(())
        }
        if case .failure(let error) = sendResult {
            return .failure(error)
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        while response.count < 4096 {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                return .failure(.message("recv: \(String(cString: strerror(errno)))"))
            }
            if n == 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if response.contains(10) { break }
        }

        guard let text = String(data: response, encoding: .utf8), !text.isEmpty else {
            return .failure(.message("empty response from piles"))
        }
        return .success(text)
    }
}
