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

        let ordinary = path + ".file"
        try? Data("keep".utf8).write(to: URL(fileURLWithPath: ordinary))
        Config.shared.ipcSocketPath = ordinary
        IPCServer.shared.start()
        check((try? String(contentsOfFile: ordinary, encoding: .utf8)) == "keep", "preserves ordinary files at configured socket paths")
        IPCServer.shared.stop()
        unlink(ordinary)

        let target = path + ".target"
        let linkPath = path + ".link"
        try? Data("target".utf8).write(to: URL(fileURLWithPath: target))
        Darwin.symlink(target, linkPath)
        Config.shared.ipcSocketPath = linkPath
        IPCServer.shared.start()
        var linkInfo = stat()
        check(lstat(linkPath, &linkInfo) == 0 && (linkInfo.st_mode & S_IFMT) == S_IFLNK, "preserves symlinks at configured socket paths")
        IPCServer.shared.stop()
        unlink(linkPath)
        unlink(target)

        Config.shared.ipcSocketPath = path
        IPCServer.shared.stop()

        let livePath = path + ".live"
        let liveFD = createListener(livePath)
        if liveFD >= 0 {
            Config.shared.ipcSocketPath = livePath
            IPCServer.shared.start()
            let liveProbe = connect(to: livePath)
            check(liveProbe != nil, "does not remove a live socket endpoint")
            if let liveProbe { close(liveProbe) }
            IPCServer.shared.stop()
            close(liveFD)
            unlink(livePath)
        } else { check(false, "creates live competing listener") }

        Config.shared.ipcSocketPath = path
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
            let fillDeadline = Date().addingTimeInterval(0.7)
            while idleClients.count < 16 && Date() < fillDeadline {
                if let client = connect(to: path) { idleClients.append(client) }
                else { usleep(5_000) }
            }
            let saturationDeadline = Date().addingTimeInterval(0.7)
            var rejectedWhileFull = false
            while Date() < saturationDeadline, !rejectedWhileFull {
                if send("ping\n", to: path) == nil { rejectedWhileFull = true }
                else { usleep(10_000) }
            }
            check(idleClients.count == 16, "connects enough idle clients to fill the worker pool")
            check(rejectedWhileFull, "rejects clients while the worker pool is saturated")
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

        // A stale socket inode can be replaced, but only after a failed probe.
        let stale = path + ".stale"
        let staleFD = createListener(stale)
        if staleFD >= 0 {
            close(staleFD)
            unlink(stale)
            let staleNodeFD = socket(AF_UNIX, SOCK_STREAM, 0)
            if staleNodeFD >= 0 {
                _ = bindSocket(staleNodeFD, stale)
                close(staleNodeFD)
                Config.shared.ipcSocketPath = stale
                IPCServer.shared.start()
                check(waitForSocket(stale) && send("ping\n", to: stale) == "pong\n", "recovers and serves on a stale socket path")
                IPCServer.shared.stop()
            } else { check(false, "creates stale socket node") }
        } else { check(false, "creates stale listener") }
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

        let firstPath = path + ".reconfigure-a"
        let secondPath = path + ".reconfigure-b"
        Config.shared.ipcEnabled = true
        Config.shared.ipcSocketPath = firstPath
        IPCServer.shared.reconfigure()
        check(waitForSocket(firstPath), "reconfigure starts IPC at configured path")
        Config.shared.ipcSocketPath = secondPath
        IPCServer.shared.reconfigure()
        check(waitForSocket(secondPath) && !FileManager.default.fileExists(atPath: firstPath), "reconfigure moves listener to changed path")
        Config.shared.ipcEnabled = false
        IPCServer.shared.reconfigure()
        check(!FileManager.default.fileExists(atPath: secondPath), "reconfigure stops IPC when disabled")
        Config.shared.ipcEnabled = true
        Config.shared.ipcSocketPath = path
        IPCServer.shared.start()
        if FileManager.default.fileExists(atPath: path) {
            unlink(path)
            let replacement = createListener(path)
            IPCServer.shared.stop()
            let replacementProbe = connect(to: path)
            check(replacement >= 0 && replacementProbe != nil, "stop preserves a replacement endpoint at the bound path")
            if let replacementProbe { close(replacementProbe) }
            if replacement >= 0 { close(replacement); unlink(path) }
        } else { check(false, "recreates listener for replacement test") }

        let lockPath = path + ".lock"
        switch PilesInstanceLock.acquire(lockFilePath: lockPath) {
        case .success:
            let heldFD = PilesInstanceLock.descriptorForTesting
            let descriptorFlags = fcntl(heldFD, F_GETFD)
            let other = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            var lockFailed = other >= 0 && flock(other, LOCK_EX | LOCK_NB) != 0 && (errno == EWOULDBLOCK || errno == EAGAIN)
            if other >= 0 { close(other) }
            lockFailed = lockFailed && descriptorFlags >= 0 && descriptorFlags & FD_CLOEXEC != 0
            PilesInstanceLock.release()
            let afterRelease = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if afterRelease >= 0 { lockFailed = lockFailed && flock(afterRelease, LOCK_EX | LOCK_NB) == 0; close(afterRelease) }
            check(lockFailed, "instance lock excludes another opener and releases without unlinking")
        case .failure:
            check(false, "acquires temporary instance lock")
        }
        unlink(lockPath)
        let lockTarget = lockPath + ".target"
        let lockSymlink = lockPath + ".link"
        _ = FileManager.default.createFile(atPath: lockTarget, contents: Data())
        Darwin.symlink(lockTarget, lockSymlink)
        if case .failure = PilesInstanceLock.acquire(lockFilePath: lockSymlink) { passed += 1 } else { failed += 1; PilesInstanceLock.release() }
        unlink(lockSymlink)
        unlink(lockTarget)

        let clientResults = runClientFakeServerTests()
        passed += clientResults.passed
        failed += clientResults.failed
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

    private static func createListener(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, bindSocket(fd, path) == 0, listen(fd, 4) == 0 else { if fd >= 0 { close(fd) }; return -1 }
        return fd
    }

    private static func bindSocket(_ fd: Int32, _ path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { ptr in bytes.withUnsafeBytes { memcpy(ptr, $0.baseAddress!, $0.count) } }
        return withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }

    private static func runClientFakeServerTests() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        let basePath = "/tmp/piles-ipc-client-\(getpid())-\(UUID().uuidString).sock"

        func runFake(_ suffix: String, timeout: TimeInterval, command: String, behavior: @escaping (Int32) -> Void) -> Result<String, IPCClient.StringError>? {
            let path = basePath + suffix
            let listener = createListener(path)
            guard listener >= 0 else { return nil }
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 1_000) > 0 {
                    let client = accept(listener, nil, nil)
                    if client >= 0 {
                        behavior(client)
                        close(client)
                    }
                }
                finished.signal()
            }
            let result = IPCClient.request(command, socketPath: path, timeout: timeout)
            let workerFinished = finished.wait(timeout: .now() + 2) == .success
            close(listener)
            unlink(path)
            if !workerFinished { return nil }
            return result
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutResult = runFake(".timeout", timeout: 0.15, command: "ping\n") { _ in
            usleep(400_000)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        if case .failure(let error) = timeoutResult, error.message == "recv timed out", elapsed < 1 { passed += 1 } else { failed += 1 }

        let disconnect = runFake(".disconnect", timeout: 1, command: "ping\n") { fd in
            var byte: UInt8 = 0
            _ = recv(fd, &byte, 1, 0)
        }
        if case .failure(let error) = disconnect, error.message == "empty response from piles" { passed += 1 } else { failed += 1 }

        let response = runFake(".roundtrip", timeout: 1, command: "ping\n") { fd in
            var received = [UInt8]()
            var byte: UInt8 = 0
            while received.last != 10 {
                guard recv(fd, &byte, 1, 0) == 1 else { return }
                received.append(byte)
            }
            let response = Array("pong\n".utf8)
            response.withUnsafeBytes { raw in
                _ = Darwin.send(fd, raw.baseAddress!, raw.count, 0)
            }
        }
        if case .success("pong\n") = response { passed += 1 } else { failed += 1 }

        let sendStart = DispatchTime.now().uptimeNanoseconds
        let nonReader = runFake(".send-timeout", timeout: 0.15, command: String(repeating: "x", count: 8 * 1024 * 1024)) { _ in
            usleep(400_000)
        }
        let sendElapsed = Double(DispatchTime.now().uptimeNanoseconds - sendStart) / 1_000_000_000
        if case .failure(let error) = nonReader, error.message == "send timed out", sendElapsed < 1 { passed += 1 } else { failed += 1 }
        return (passed, failed)
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
