import Darwin
import Foundation

package enum PilesInstanceLock {
    package struct LockError: Error {
        package let message: String
    }

    private static var descriptor: Int32 = -1

    package static func acquire(lockFilePath: String? = nil) -> Result<Void, LockError> {
        if descriptor >= 0 { return .success(()) }

        let directory = NSString(string: "~/.config/piles").expandingTildeInPath
        if lockFilePath == nil {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                return .failure(LockError(message: "cannot create instance lock directory: \(error.localizedDescription)"))
            }
        }

        let path = lockFilePath ?? (directory as NSString).appendingPathComponent("instance.lock")
        var fd: Int32
        repeat {
            fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        } while fd < 0 && errno == EINTR
        guard fd >= 0 else {
            return .failure(LockError(message: "cannot open instance lock: \(String(cString: strerror(errno)))"))
        }

        var info = stat()
        var inspectResult: Int32
        repeat {
            inspectResult = fstat(fd, &info)
        } while inspectResult < 0 && errno == EINTR
        guard inspectResult == 0 else {
            let error = errno
            close(fd)
            return .failure(LockError(message: "cannot inspect instance lock: \(String(cString: strerror(error)))"))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return .failure(LockError(message: "instance lock is not a regular file"))
        }

        while flock(fd, LOCK_EX | LOCK_NB) < 0 {
            if errno == EINTR { continue }
            let error = errno
            close(fd)
            if error == EWOULDBLOCK || error == EAGAIN {
                return .failure(LockError(message: "another piles instance is already running"))
            }
            return .failure(LockError(message: "cannot acquire instance lock: \(String(cString: strerror(error)))"))
        }

        descriptor = fd
        return .success(())
    }

    package static func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    package static var descriptorForTesting: Int32 { descriptor }
}
