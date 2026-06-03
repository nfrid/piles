import Darwin
import Dispatch
import Foundation

package final class IPCServer {
    package static let shared = IPCServer()

    private let queue = DispatchQueue(label: "com.piles.ipc", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private init() {}

    package func start() {
        guard Config.shared.ipcEnabled else { return }

        queue.async { [self] in
            guard self.bindAndListen() else { return }
            self.installAcceptSource()
        }
    }

    package func stop() {
        queue.async { [self] in
            self.acceptSource?.cancel()
            self.acceptSource = nil
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            unlink(Config.shared.expandedIPCSocketPath)
        }
    }

    private func bindAndListen() -> Bool {
        let path = Config.shared.expandedIPCSocketPath
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logErrno("socket")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            fputs("piles: ipc socket path too long\n", stderr)
            close(fd)
            return false
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { raw in
                memcpy(ptr, raw.baseAddress!, raw.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            logErrno("bind")
            close(fd)
            return false
        }

        guard listen(fd, 8) == 0 else {
            logErrno("listen")
            close(fd)
            unlink(path)
            return false
        }

        listenFD = fd
        fputs("piles: ipc listening on \(path)\n", stderr)
        return true
    }

    private func installAcceptSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
                self?.listenFD = -1
            }
        }
        acceptSource = source
        source.resume()
    }

    private func acceptClients() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                logErrno("accept")
                break
            }
            handleClient(fd: client)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }

        guard let line = readLine(fd: fd) else { return }

        if IPCCommandParser.isPing(line) {
            writeResponse(fd: fd, "pong\n")
            return
        }

        let workspaceCount = Config.shared.workspaceCount
        switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
        case .failure(.invalid(let message)):
            writeResponse(fd: fd, "error: \(message)\n")
        case .success(let action):
            guard action != .passThrough else {
                writeResponse(fd: fd, "error: invalid command\n")
                return
            }
            DispatchQueue.main.sync {
                ActionDispatcher.perform(action)
            }
            writeResponse(fd: fd, "ok\n")
        }
    }

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(256)
        var chunk = [UInt8](repeating: 0, count: 256)

        while buffer.count < 4096 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                logErrno("recv")
                return nil
            }
            if n == 0 { break }

            for i in 0..<n {
                let byte = chunk[i]
                if byte == 10 {
                    return String(bytes: buffer, encoding: .utf8)
                }
                buffer.append(byte)
            }
        }

        return String(bytes: buffer, encoding: .utf8)
    }

    private func writeResponse(fd: Int32, _ text: String) {
        text.withCString { ptr in
            let len = strlen(ptr)
            var sent = 0
            while sent < len {
                let n = send(fd, ptr + sent, len - sent, 0)
                if n <= 0 {
                    logErrno("send")
                    return
                }
                sent += n
            }
        }
    }

    private func logErrno(_ label: String) {
        fputs("piles: ipc \(label) failed: \(String(cString: strerror(errno)))\n", stderr)
    }
}
