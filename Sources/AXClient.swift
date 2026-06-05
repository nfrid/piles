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
