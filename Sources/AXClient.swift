import AppKit
import ApplicationServices

enum AXClient {
    @discardableResult
    static func setAttribute(
        _ attribute: CFString,
        value: CFTypeRef,
        on element: AXUIElement,
        context: @autoclosure () -> String
    ) -> Bool {
        let result = AXUIElementSetAttributeValue(element, attribute, value)
        guard result == .success else {
            DebugLog.write("ax set failed result=\(result) attribute=\(attribute) context=\(context())")
            return false
        }
        return true
    }

    static func withEnhancedUserInterfaceDisabled<T>(
        for pid: pid_t,
        operation: () -> T
    ) -> T {
        guard !NSWorkspace.shared.isVoiceOverEnabled,
              !NSWorkspace.shared.isSwitchControlEnabled else {
            return operation()
        }

        let application = AXUIElementCreateApplication(pid)
        return withEnhancedUserInterfaceDisabled(
            isAssistiveTechnologyEnabled: false,
            read: {
                var value: AnyObject?
                guard AXUIElementCopyAttributeValue(
                    application,
                    "AXEnhancedUserInterface" as CFString,
                    &value
                ) == .success else { return nil }
                return value as? Bool
            },
            write: { enabled in
                setAttribute(
                    "AXEnhancedUserInterface" as CFString,
                    value: enabled ? kCFBooleanTrue : kCFBooleanFalse,
                    on: application,
                    context: "pid=\(pid) enhancedUserInterface=\(enabled)"
                )
            },
            operation: operation
        )
    }

    static func withEnhancedUserInterfaceDisabled<T>(
        isAssistiveTechnologyEnabled: Bool,
        read: () -> Bool?,
        write: (Bool) -> Bool,
        operation: () -> T
    ) -> T {
        guard !isAssistiveTechnologyEnabled, read() == true, write(false) else {
            return operation()
        }
        defer { _ = write(true) }
        return operation()
    }

    @discardableResult
    static func performAction(
        _ action: CFString,
        on element: AXUIElement,
        context: @autoclosure () -> String
    ) -> Bool {
        let result = AXUIElementPerformAction(element, action)
        guard result == .success else {
            DebugLog.write("ax action failed result=\(result) action=\(action) context=\(context())")
            return false
        }
        return true
    }
}
