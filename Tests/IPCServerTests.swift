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
        check(!IPCServer.shared.reconfigure(), "reconfigure reports a path conflict")
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

            // Never bootstrap monitors here. Even rescan must stay a no-op on real windows.
            check(WorkspaceManager.shared.monitors.isEmpty, "IPC diagnostics fixture has no live monitors")
            if WorkspaceManager.shared.monitors.isEmpty {
                let status = queryPumpingMain("status\n", path: path).flatMap {
                    try? JSONDecoder().decode(DiagnosticsStatus.self, from: Data($0.utf8))
                }
                check(status?.monitors.isEmpty == true && status?.focused_monitor == nil, "status returns a valid empty snapshot over IPC")
                let windows = queryPumpingMain("windows\n", path: path).flatMap {
                    try? JSONDecoder().decode(DiagnosticsWindows.self, from: Data($0.utf8))
                }
                check(windows?.windows.isEmpty == true, "windows returns a valid empty snapshot over IPC")
                let rescan = queryPumpingMain("rescan\n", path: path).flatMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Int]
                }
                check(rescan?["discovered_windows"] == 0 && rescan?["unavailable_apps"] == 0,
                      "rescan without monitors returns an empty report without scanning real windows")
            }

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
        check(IPCServer.shared.reconfigure() && waitForSocket(firstPath), "reconfigure starts IPC at configured path")
        if let connected = connect(to: firstPath) {
            check(IPCServer.shared.reconfigure(), "unchanged IPC configuration remains available")
            let sent = "ping\n".withCString { Darwin.send(connected, $0, 5, 0) }
            var response = [UInt8](repeating: 0, count: 16)
            let received = recv(connected, &response, 5, MSG_WAITALL)
            check(sent == 5 && received == 5 && String(bytes: response.prefix(5), encoding: .utf8) == "pong\n",
                  "unchanged reload preserves connected clients")
            close(connected)
        } else {
            check(false, "connects a client before unchanged reload")
        }
        Config.shared.ipcSocketPath = secondPath
        check(IPCServer.shared.reconfigure() && send("ping\n", to: secondPath) == "pong\n"
              && !FileManager.default.fileExists(atPath: firstPath), "reconfigure moves listener to changed path")
        Config.shared.ipcEnabled = false
        check(IPCServer.shared.reconfigure() && !FileManager.default.fileExists(atPath: secondPath),
              "reconfigure stops IPC when disabled")
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
            let heldFD = PilesInstanceLock.descriptor
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

    private final class PendingQuery {
        var result: Result<String, IPCClient.StringError>?
        let finished = DispatchSemaphore(value: 0)
    }

    private static func queryPumpingMain(_ command: String, path: String) -> String? {
        let query = PendingQuery()
        DispatchQueue.global().async {
            query.result = IPCClient.request(command, socketPath: path, timeout: 1)
            query.finished.signal()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while query.finished.wait(timeout: .now()) == .timedOut {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        switch query.result {
        case .success(let response): return response
        case .failure(let error):
            fputs("IPC query failed: \(error.message)\n", stderr)
            return nil
        case nil: return nil
        }
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
                        var noSigPipe: Int32 = 1
                        var timeout = timeval(tv_sec: 1, tv_usec: 0)
                        let protected = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                                   socklen_t(MemoryLayout<Int32>.size)) == 0
                        let bounded = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                                 socklen_t(MemoryLayout<timeval>.size)) == 0
                        if protected && bounded { behavior(client) }
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
            guard sendAll(fd, Data("pong\n".utf8)) else { return }
        }
        if case .success("pong\n") = response { passed += 1 } else { failed += 1 }

        let longResponse = runFake(".long-response", timeout: 1, command: "windows\n") { fd in
            var received = [UInt8]()
            var byte: UInt8 = 0
            while received.last != 10 {
                guard recv(fd, &byte, 1, 0) == 1 else { return }
                received.append(byte)
            }
            let data = Data(repeating: 120, count: 8_000) + Data([10])
            guard sendAll(fd, data) else { return }
        }
        if case .success(let text) = longResponse, text.utf8.count == 8_001 { passed += 1 } else { failed += 1 }

        let truncated = runFake(".truncated", timeout: 1, command: "ping\n") { fd in
            var byte: UInt8 = 0
            while recv(fd, &byte, 1, 0) == 1 && byte != 10 {}
            guard sendAll(fd, Data("partial".utf8)) else { return }
        }
        if case .failure(let error) = truncated, error.message == "truncated response from piles" { passed += 1 } else { failed += 1 }

        let oversized = runFake(".oversized", timeout: 1, command: "windows\n") { fd in
            var byte: UInt8 = 0
            while recv(fd, &byte, 1, 0) == 1 && byte != 10 {}
            let data = Data(repeating: 120, count: IPCClient.maximumResponseBytes + 1)
            guard sendAll(fd, data) else { return }
        }
        if case .failure(let error) = oversized, error.message == "response exceeds 1 MiB limit" { passed += 1 } else { failed += 1 }

        let exactLimit = runFake(".exact-limit", timeout: 2, command: "status\n") { fd in
            var byte: UInt8 = 0
            while recv(fd, &byte, 1, 0) == 1 && byte != 10 {}
            var data = Data(repeating: 120, count: IPCClient.maximumResponseBytes - 1)
            data.append(10)
            guard sendAll(fd, data) else { return }
        }
        if case .success(let text) = exactLimit, text.utf8.count == IPCClient.maximumResponseBytes { passed += 1 } else { failed += 1 }

        let trailing = runFake(".trailing", timeout: 1, command: "status\n") { fd in
            var byte: UInt8 = 0
            while recv(fd, &byte, 1, 0) == 1 && byte != 10 {}
            guard sendAll(fd, Data("ok\nignored".utf8)) else { return }
        }
        if case .success("ok\n") = trailing { passed += 1 } else { failed += 1 }

        let sendStart = DispatchTime.now().uptimeNanoseconds
        let nonReader = runFake(".send-timeout", timeout: 0.15, command: String(repeating: "x", count: 8 * 1024 * 1024)) { _ in
            usleep(400_000)
        }
        let sendElapsed = Double(DispatchTime.now().uptimeNanoseconds - sendStart) / 1_000_000_000
        if case .failure(let error) = nonReader, error.message == "send timed out", sendElapsed < 1 { passed += 1 } else { failed += 1 }
        return (passed, failed)
    }

    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
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

        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
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
        try? IPCClient.request(command, socketPath: path).get()
    }
}
