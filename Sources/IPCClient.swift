import Darwin
import Foundation

package enum IPCClient {
    package struct StringError: Error {
        package let message: String

        package init(_ message: String) {
            self.message = message
        }
    }

    package static func request(
        _ command: String,
        socketPath: String,
        timeout: TimeInterval = 2
    ) -> Result<String, StringError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(StringError("socket: \(String(cString: strerror(errno)))"))
        }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        guard setNoSigPipe(fd, &noSigPipe) else {
            return .failure(StringError("setsockopt(SO_NOSIGPIPE): \(String(cString: strerror(errno)))"))
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(max(0, timeout) * 1_000_000_000)
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanos)
        let deadlineNanos = overflow ? UInt64.max : deadline

        guard let flags = getFlags(fd), setFlags(fd, flags | O_NONBLOCK) else {
            return .failure(StringError("fcntl: \(String(cString: strerror(errno)))"))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .failure(StringError("socket path too long"))
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pathBytes.withUnsafeBytes { raw in
                memcpy(pointer, raw.baseAddress!, raw.count)
            }
        }

        let connectResult: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connectWithRetry(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size), deadline: deadlineNanos)
            }
        }
        if connectResult != 0 {
            let connectError = errno
            guard connectError == EINPROGRESS || connectError == EALREADY || connectError == EWOULDBLOCK,
                  wait(fd, POLLOUT, deadlineNanos) else {
                return .failure(connectionError(connectError, socketPath))
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getSocketError(fd, &socketError, &length), socketError == 0 else {
                let error = socketError == 0 ? errno : socketError
                return .failure(StringError("connect: \(String(cString: strerror(error)))"))
            }
        }

        let bytes = Array(command.utf8)
        var sent = 0
        while sent < bytes.count {
            guard DispatchTime.now().uptimeNanoseconds < deadlineNanos else {
                return .failure(StringError("send timed out"))
            }
            let count = bytes.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            if count > 0 {
                sent += count
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if wait(fd, POLLOUT, deadlineNanos) { continue }
                return .failure(StringError("send timed out"))
            }
            return .failure(StringError("send: \(String(cString: strerror(errno)))"))
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        while response.count < 4096 {
            guard DispatchTime.now().uptimeNanoseconds < deadlineNanos else {
                return .failure(StringError("recv timed out"))
            }
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                response.append(contentsOf: chunk[..<count])
                if response.contains(10) { break }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if (errno == EAGAIN || errno == EWOULDBLOCK) && wait(fd, POLLIN, deadlineNanos) {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .failure(StringError("recv timed out"))
            }
            return .failure(StringError("recv: \(String(cString: strerror(errno)))"))
        }

        guard let text = String(data: response, encoding: .utf8), !text.isEmpty else {
            return .failure(StringError("empty response from piles"))
        }
        return .success(text)
    }

    private static func connectionError(_ error: Int32, _ path: String) -> StringError {
        if error == ENOENT || error == ECONNREFUSED {
            return StringError("could not connect to \(path) (is piles running?)")
        }
        return StringError("connect: \(String(cString: strerror(error)))")
    }

    private static func getFlags(_ fd: Int32) -> Int32? {
        while true {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { return flags }
            if errno != EINTR { return nil }
        }
    }

    private static func setFlags(_ fd: Int32, _ flags: Int32) -> Bool {
        while fcntl(fd, F_SETFL, flags) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func setNoSigPipe(_ fd: Int32, _ value: inout Int32) -> Bool {
        while setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func connectWithRetry(
        _ fd: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t,
        deadline: UInt64
    ) -> Int32 {
        while true {
            let result = Darwin.connect(fd, address, length)
            if result == 0 || errno != EINTR { return result }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                errno = ETIMEDOUT
                return -1
            }
        }
    }

    private static func getSocketError(_ fd: Int32, _ error: inout Int32, _ length: inout socklen_t) -> Bool {
        while getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private static func wait(_ fd: Int32, _ events: Int32, _ deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = deadline - now
            let roundedMilliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            let milliseconds = min(UInt64(Int32.max), roundedMilliseconds)
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(milliseconds))
            if result > 0 {
                return descriptor.revents & Int16(events | POLLERR | POLLHUP) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }
}
