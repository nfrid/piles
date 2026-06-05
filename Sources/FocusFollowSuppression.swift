import Foundation

package struct FocusFollowSuppression {
    package static let defaultDuration: TimeInterval = 0.25

    private var suppressedUntil: [pid_t: TimeInterval] = [:]

    package mutating func suppress(
        pid: pid_t,
        duration: TimeInterval = Self.defaultDuration,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let until = now + duration
        suppressedUntil[pid] = max(suppressedUntil[pid] ?? 0, until)
    }

    package mutating func isSuppressed(
        pid: pid_t,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let until = suppressedUntil[pid] else { return false }
        if now < until { return true }
        suppressedUntil.removeValue(forKey: pid)
        return false
    }
}
