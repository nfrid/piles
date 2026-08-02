import Darwin
import Foundation
@testable import PilesCore

enum IPCServerTests {
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

        let originalConfig = Config.shared
        let path = "/tmp/piles-ipc-tests-\(getpid())-\(UUID().uuidString).sock"
        let changedPath = path + ".changed"
        defer {
            IPCServer.shared.stop()
            Config.shared = originalConfig
            unlink(path)
            unlink(changedPath)
        }

        Config.shared.ipcEnabled = true
        Config.shared.ipcSocketPath = path
        IPCServer.shared.stop()
        IPCServer.shared.start()
        check(waitForSocket(path), "IPC server creates its socket")

        if FileManager.default.fileExists(atPath: path) {
            check(send("ping\n", to: path) == "pong\n", "first sequential ping request")
            check(send("ping\n", to: path) == "pong\n", "second sequential ping request")

            if let idleClient = connect(to: path) {
                usleep(100_000)
                check(send("ping\n", to: path) == "pong\n", "idle client does not block another client")
                close(idleClient)
            } else {
                check(false, "connects an idle client")
            }

            var idleClients: [Int32] = []
            for _ in 0..<16 {
                if let client = connect(to: path) {
                    idleClients.append(client)
                }
            }
            usleep(100_000)
            check(idleClients.count == 16, "fills the bounded client worker pool")
            check(send("ping\n", to: path) == nil, "rejects clients while the worker pool is saturated")
            usleep(1_200_000)
            check(send("ping\n", to: path) == "pong\n", "worker slots recover after idle-client timeouts")
            idleClients.forEach { close($0) }
        }

        // Changing config before stop must not leave the path that was bound.
        Config.shared.ipcSocketPath = changedPath
        IPCServer.shared.stop()
        check(!FileManager.default.fileExists(atPath: path), "stop unlinks the bound socket path")
        IPCServer.shared.stop()
        check(!FileManager.default.fileExists(atPath: path), "stop is idempotent")

        Config.shared.ipcSocketPath = path
        IPCServer.shared.start()
        check(waitForSocket(path), "server restarts after stop")
        if let idleClient = connect(to: path) {
            usleep(100_000)
            IPCServer.shared.stop()
            var byte: UInt8 = 0
            check(recv(idleClient, &byte, 1, 0) <= 0, "stop disconnects active idle clients")
            close(idleClient)
        } else {
            check(false, "connects an idle client before stop")
        }
        IPCServer.shared.start()
        check(waitForSocket(path), "server restarts after disconnecting active clients")
        check(send("ping\n", to: path) == "pong\n", "restarted server handles requests")
        IPCServer.shared.stop()

        return (passed, failed)
    }

    private static func waitForSocket(_ path: String) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            usleep(10_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func connect(to path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pathBytes.withUnsafeBytes { raw in
                memcpy(pointer, raw.baseAddress!, raw.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, addressLength)
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return fd
    }

    private static func send(_ command: String, to path: String) -> String? {
        guard let fd = connect(to: path) else { return nil }
        defer { close(fd) }

        let data = Data(command.utf8)
        let sent = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard sent else { return nil }

        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while !response.contains(10) {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { return nil }
            response.append(contentsOf: chunk[0..<count])
        }
        return String(bytes: response, encoding: .utf8)
    }
}
