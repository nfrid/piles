import Foundation
@testable import PilesCore

enum AXClientTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else {
                failed += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        var value: Bool? = true
        var writes: [Bool] = []
        var observed: [Bool?] = []
        let result = AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { value },
            write: { enabled in writes.append(enabled); value = enabled; return true },
            operation: { observed.append(value); return 7 }
        )
        check(result == 7 && writes == [false, true] && observed == [false], "disables for operation and restores true")

        writes = []
        value = false
        AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { value },
            write: { enabled in writes.append(enabled); return true },
            operation: {}
        )
        check(writes.isEmpty, "leaves already-disabled value unchanged")

        var readCount = 0
        AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: true,
            read: { readCount += 1; return true },
            write: { _ in false },
            operation: {}
        )
        check(readCount == 0, "skips attribute reads with assistive technology enabled")

        writes = []
        AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { nil },
            write: { enabled in writes.append(enabled); return false },
            operation: {}
        )
        check(writes.isEmpty, "unavailable value does not trigger writes")

        writes = []
        var ran = false
        AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { true },
            write: { enabled in writes.append(enabled); return false },
            operation: { ran = true }
        )
        check(ran && writes == [false], "failed disable still runs operation without restoring")

        writes = []
        let failedGeometryResult = AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { true },
            write: { enabled in writes.append(enabled); return true },
            operation: { false }
        )
        check(!failedGeometryResult && writes == [false, true], "restores after a false geometry result")

        writes = []
        let geometryResult = AXClient.withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: { true },
            write: { enabled in writes.append(enabled); return !enabled },
            operation: { true }
        )
        check(geometryResult && writes == [false, true], "failed restoration preserves successful geometry result")

        return (passed, failed)
    }
}
