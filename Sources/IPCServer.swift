import Darwin
import Dispatch
import Foundation

package final class IPCServer {
    package static let shared = IPCServer()

    private static let maxConcurrentClients = 16
    private static let clientTimeoutSeconds = 1

    private let queue = DispatchQueue(label: "com.piles.ipc", qos: .userInitiated)
    private let clientQueue = DispatchQueue(
        label: "com.piles.ipc.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let clientSlots = DispatchSemaphore(value: maxConcurrentClients)
    private let queueKey = DispatchSpecificKey<Void>()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var activeClientFDs: Set<Int32> = []
    private var boundSocketPath: String?
    private var boundSocketIdentity: (dev_t, ino_t)?
    private var generation = 0

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    package func start() {
        onQueue { [self] in
            guard Config.shared.ipcEnabled, listenFD < 0 else { return }
            guard bindAndListen() else { return }
            generation += 1
            installAcceptSource()
        }
    }

    package func reconfigure() {
        onQueue { [self] in
            stopOnQueue()
            guard Config.shared.ipcEnabled, bindAndListen() else { return }
            generation += 1
            installAcceptSource()
        }
    }

    package func stop() {
        onQueue { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        generation += 1
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        for fd in activeClientFDs { shutdown(fd, SHUT_RDWR) }
        if let path = boundSocketPath {
            removeBoundSocket(path)
            boundSocketPath = nil
            boundSocketIdentity = nil
        }
    }

    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func bindAndListen() -> Bool {
        let path = Config.shared.expandedIPCSocketPath
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        guard prepareSocketPath(path) else { return false }

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

        boundSocketIdentity = socketIdentity(path)

        guard setNonBlocking(fd: fd) else {
            close(fd)
            removeBoundSocket(path)
            return false
        }

        guard listen(fd, 8) == 0 else {
            logErrno("listen")
            close(fd)
            removeBoundSocket(path)
            return false
        }

        listenFD = fd
        boundSocketPath = path
        boundSocketIdentity = socketIdentity(path)
        fputs("piles: ipc listening on \(path)\n", stderr)
        return true
    }

    private func socketIdentity(_ path: String) -> (dev_t, ino_t)? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private func prepareSocketPath(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            fputs("piles: refusing to replace non-socket IPC path \(path)\n", stderr)
            return false
        }
        let identity = (info.st_dev, info.st_ino)
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { logErrno("socket probe"); return false }
        defer { close(probe) }
        let flags: Int32
        while true {
            let result = fcntl(probe, F_GETFL)
            if result >= 0 { flags = result; break }
            if errno != EINTR { return false }
        }
        while fcntl(probe, F_SETFL, flags | O_NONBLOCK) < 0 {
            if errno != EINTR { return false }
        }
        let probeResult = connectToPath(probe, path)
        if probeResult == 0 || errno == EINPROGRESS || errno == EALREADY || errno == EAGAIN || errno == EWOULDBLOCK {
            fputs("piles: IPC socket already has a listener at \(path)\n", stderr)
            return false
        }
        while probeResult < 0 && errno == EINTR {
            if connectToPath(probe, path) == 0 || errno == EINPROGRESS || errno == EALREADY || errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
        }
        guard errno == ECONNREFUSED else { return false }
        var current = stat()
        guard lstat(path, &current) == 0, current.st_dev == identity.0,
              current.st_ino == identity.1, (current.st_mode & S_IFMT) == S_IFSOCK else { return false }
        return unlink(path) == 0
    }

    private func removeBoundSocket(_ path: String) {
        guard let identity = boundSocketIdentity, let current = socketIdentity(path),
              current.0 == identity.0, current.1 == identity.1 else { return }
        unlink(path)
    }

    private func connectToPath(_ fd: Int32, _ path: String) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { errno = ENAMETOOLONG; return -1 }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            bytes.withUnsafeBytes { memcpy(ptr, $0.baseAddress!, $0.count) }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func setNonBlocking(fd: Int32) -> Bool {
        setBlocking(fd: fd, nonBlocking: true)
    }

    private func setBlocking(fd: Int32) -> Bool {
        setBlocking(fd: fd, nonBlocking: false)
    }

    private func setBlocking(fd: Int32, nonBlocking: Bool) -> Bool {
        let flags: Int32
        while true {
            let result = fcntl(fd, F_GETFL)
            if result >= 0 {
                flags = result
                break
            }
            if errno != EINTR {
                logErrno("fcntl(F_GETFL)")
                return false
            }
        }

        let newFlags = nonBlocking ? flags | O_NONBLOCK : flags & ~O_NONBLOCK
        while fcntl(fd, F_SETFL, newFlags) < 0 {
            if errno != EINTR {
                logErrno("fcntl(F_SETFL)")
                return false
            }
        }
        return true
    }

    private func installAcceptSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClients()
        }
        // Socket ownership stays with this queue. The source is canceled
        // before the fd is closed in stop(), avoiding delayed fd reuse.
        source.setCancelHandler {}
        acceptSource = source
        source.resume()
    }

    private func acceptClients() {
        let fd = listenFD
        guard fd >= 0 else { return }

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                logErrno("accept")
                break
            }

            // Some platforms inherit O_NONBLOCK from the listening socket;
            // keep the per-client read semantics blocking on its own worker.
            guard setBlocking(fd: client) else {
                close(client)
                continue
            }
            guard preventSIGPIPE(fd: client), setClientTimeout(fd: client) else {
                close(client)
                continue
            }

            // Reads are isolated on bounded workers and time out, so abandoned
            // clients cannot permanently consume all client slots.
            // Reject excess clients instead of blocking the accept queue.
            guard clientSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            activeClientFDs.insert(client)
            let acceptedGeneration = generation
            clientQueue.async { [self] in
                defer {
                    finishClient(fd: client)
                    clientSlots.signal()
                }
                handleClient(fd: client, generation: acceptedGeneration)
            }
        }
    }

    private func preventSIGPIPE(fd: Int32) -> Bool {
        var value: Int32 = 1
        while setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) < 0 {
            if errno == EINTR { continue }
            logErrno("setsockopt(SO_NOSIGPIPE)")
            return false
        }
        return true
    }

    private func setClientTimeout(fd: Int32) -> Bool {
        var timeout = timeval(tv_sec: Self.clientTimeoutSeconds, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            if setsockopt(
                fd,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) < 0 {
                logErrno("setsockopt(timeout)")
                return false
            }
        }
        return true
    }

    private func finishClient(fd: Int32) {
        onQueue { activeClientFDs.remove(fd) }
        close(fd)
    }

    private func isCurrent(generation: Int) -> Bool {
        var current = false
        onQueue {
            current = listenFD >= 0 && self.generation == generation
        }
        return current
    }

    private func handleClient(fd: Int32, generation: Int) {
        guard let line = readLine(fd: fd), isCurrent(generation: generation) else { return }

        if IPCCommandParser.isPing(line) {
            writeResponse(fd: fd, "pong\n")
            return
        }

        let workspaceCount = MainThread.runSync { Config.shared.workspaceCount }
        switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
        case .failure(.invalid(let message)):
            writeResponse(fd: fd, "error: \(message)\n")
        case .success(let action):
            guard action != .passThrough else {
                writeResponse(fd: fd, "error: invalid command\n")
                return
            }
            let performed = DispatchQueue.main.sync { [self] in
                guard isCurrent(generation: generation) else { return false }
                ActionDispatcher.perform(action)
                return true
            }
            if performed {
                writeResponse(fd: fd, "ok\n")
            }
        }
    }

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(256)
        var chunk = [UInt8](repeating: 0, count: 256)

        while buffer.count < 4096 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    logErrno("recv")
                }
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
                if n > 0 {
                    sent += n
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0 {
                    let error = errno
                    if error != EPIPE && error != ECONNRESET {
                        logErrno("send")
                    }
                }
                return
            }
        }
    }

    private func logErrno(_ label: String) {
        fputs("piles: ipc \(label) failed: \(String(cString: strerror(errno)))\n", stderr)
    }
}
