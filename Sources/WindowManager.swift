import AppKit
import ApplicationServices

struct WindowGroupKey: Hashable {
    let pid: pid_t
    let frame: WindowFrameKey

    init(pid: pid_t, frame: CGRect) {
        self.pid = pid
        self.frame = WindowFrameKey(frame)
    }
}

struct WindowFrameKey: Hashable {
    private static let unit: CGFloat = 16

    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: CGRect) {
        x = Self.quantize(frame.origin.x)
        y = Self.quantize(frame.origin.y)
        width = Self.quantize(frame.width)
        height = Self.quantize(frame.height)
    }

    private static func quantize(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value / unit).rounded())
    }
}

struct TrackedWindow: Equatable {
    let element: AXUIElement
    let focusElement: AXUIElement
    let members: [AXUIElement]
    let pid: pid_t
    let group: WindowGroupKey

    init(element: AXUIElement, pid: pid_t, members: [AXUIElement] = [], group: WindowGroupKey? = nil) {
        let window = WindowManager.canonicalWindowElement(element) ?? element
        self.element = window
        self.focusElement = element
        self.members = TrackedWindow.unique([window] + members)
        self.pid = pid
        self.group = group ?? WindowGroupKey(pid: pid, frame: WindowManager.frame(of: window) ?? .null)
    }

    static func == (lhs: TrackedWindow, rhs: TrackedWindow) -> Bool {
        lhs.hasElement(rhs)
    }

    func hasElement(_ other: TrackedWindow) -> Bool {
        references.contains { left in
            other.references.contains { CFEqual(left, $0) }
        }
    }

    func hasSameMembers(_ other: TrackedWindow) -> Bool {
        members.count == other.members.count
            && members.allSatisfy { member in other.members.contains { CFEqual(member, $0) } }
    }

    func containsElement(_ element: AXUIElement) -> Bool {
        references.contains { CFEqual($0, element) }
    }

    func getFrame() -> CGRect? {
        WindowManager.frame(of: element)
    }

    func keepingMembers(from current: TrackedWindow) -> TrackedWindow {
        TrackedWindow(element: focusElement, pid: pid, members: current.members, group: group)
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        for member in members {
            AXUIElementSetAttributeValue(member, kAXPositionAttribute as CFString, value)
        }
    }

    func setSize(_ size: CGSize) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        for member in members {
            AXUIElementSetAttributeValue(member, kAXSizeAttribute as CFString, value)
        }
    }

    func hideOffscreen(_ screen: CGRect) {
        guard !isFullscreen() else { return }
        setPosition(CGPoint(x: screen.origin.x + 1 - screen.width, y: screen.maxY - 1))
    }

    func setFrame(_ rect: CGRect) {
        guard isTileable() else { return }
        setPosition(rect.origin)
        setSize(rect.size)
    }

    func focus() {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(focusElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(focusElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func isTileable() -> Bool {
        WindowManager.isTileable(element)
    }

    func isTrackable() -> Bool {
        WindowManager.isTrackable(element)
    }

    func isFullscreen() -> Bool {
        WindowManager.isFullscreen(element)
    }

    func title() -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func unique(_ elements: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for element in elements where !result.contains(where: { CFEqual($0, element) }) {
            result.append(element)
        }
        return result
    }

    private var references: [AXUIElement] {
        TrackedWindow.unique([element, focusElement] + members)
    }
}

enum WindowManager {
    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let candidate = value,
              CFGetTypeID(candidate) == AXUIElementGetTypeID()
        else { return nil }
        return (candidate as! AXUIElement)
    }

    private static func axValueAttribute(_ element: AXUIElement, _ attribute: CFString, type: AXValueType) -> AXValue? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let candidate = value,
              CFGetTypeID(candidate) == AXValueGetTypeID(),
              AXValueGetType(candidate as! AXValue) == type
        else { return nil }
        return (candidate as! AXValue)
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String
        else { return nil }
        return string
    }

    private static func axBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let bool = value as? Bool
        else { return nil }
        return bool
    }

    private static func axWindowAttributes(_ element: AXUIElement) -> (role: String?, subrole: String?, minimized: Bool, fullscreen: Bool)? {
        let role = axStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = axStringAttribute(element, kAXSubroleAttribute as CFString)
        guard role != nil || subrole != nil else { return nil }

        return (
            role: role,
            subrole: subrole,
            minimized: axBoolAttribute(element, kAXMinimizedAttribute as CFString) ?? false,
            fullscreen: axBoolAttribute(element, "AXFullScreen" as CFString) ?? false
        )
    }

    static func allWindows() -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)

            var windowsValue: AnyObject?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement]
            else { continue }

            result.append(contentsOf: trackedWindows(pid: pid, windows: windows))
        }
        return result
    }

    static func windows(pid: pid_t) -> [TrackedWindow]? {
        let appRef = AXUIElementCreateApplication(pid)

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return nil }

        return trackedWindows(pid: pid, windows: windows)
    }

    static func trackedWindows(pid: pid_t, windows: [AXUIElement]) -> [TrackedWindow] {
        let candidates = windows.compactMap { WindowCandidate(element: $0, pid: pid) }
        var result: [TrackedWindow] = []

        for candidate in candidates {
            let related = candidates
                .filter { candidate.matches($0) }
                .map(\.window)
            let window = TrackedWindow(element: candidate.element, pid: pid, members: related, group: candidate.group)
            guard !result.contains(window) else { continue }
            result.append(window)
        }

        return result
    }

    static func focusedWindow() -> TrackedWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        return focusedWindow(pid: pid)
    }

    static func focusedWindow(pid: pid_t) -> TrackedWindow? {
        let appRef = AXUIElementCreateApplication(pid)

        if let focused = trackedWindow(appRef, kAXFocusedUIElementAttribute as CFString, pid: pid) {
            return focused
        }
        return trackedWindow(appRef, kAXFocusedWindowAttribute as CFString, pid: pid)
    }

    private static func trackedWindow(_ appRef: AXUIElement, _ attribute: CFString, pid: pid_t) -> TrackedWindow? {
        guard let element = axElementAttribute(appRef, attribute) else { return nil }
        let window = TrackedWindow(element: element, pid: pid)
        guard window.isTrackable() else { return nil }
        return window
    }

    static func isTrackable(_ element: AXUIElement) -> Bool {
        guard let attrs = axWindowAttributes(element) else { return false }
        return attrs.role == kAXWindowRole
            && attrs.subrole == kAXStandardWindowSubrole
            && !attrs.minimized
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        axWindowAttributes(element)?.fullscreen ?? false
    }

    static func isTileable(_ element: AXUIElement) -> Bool {
        guard let attrs = axWindowAttributes(element) else { return false }
        return attrs.role == kAXWindowRole
            && attrs.subrole == kAXStandardWindowSubrole
            && !attrs.minimized
            && !attrs.fullscreen
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard let attrs = axWindowAttributes(element) else { return false }
        return attrs.role == kAXWindowRole && attrs.subrole == kAXStandardWindowSubrole
    }

    static func canonicalWindowElement(_ element: AXUIElement) -> AXUIElement? {
        guard let window = axElementAttribute(element, kAXWindowAttribute as CFString) else { return nil }
        guard isStandardWindow(window) else { return nil }
        return window
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue = axValueAttribute(element, kAXPositionAttribute as CFString, type: .cgPoint),
              let sizeValue = axValueAttribute(element, kAXSizeAttribute as CFString, type: .cgSize)
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func screenFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        return screenFrame(for: screen)
    }

    static func screenFrame(for screen: NSScreen) -> CGRect {
        convertRect(screen.visibleFrame)
    }

    static func screenRect(for screen: NSScreen) -> CGRect {
        convertRect(screen.frame)
    }

    private static func convertRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 1080
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

private struct WindowCandidate {
    let element: AXUIElement
    let window: AXUIElement
    let frame: CGRect
    let group: WindowGroupKey

    init?(element: AXUIElement, pid: pid_t) {
        let window = WindowManager.canonicalWindowElement(element) ?? element
        guard WindowManager.isTrackable(window), let frame = WindowManager.frame(of: window) else { return nil }
        self.element = element
        self.window = window
        self.frame = frame
        self.group = WindowGroupKey(pid: pid, frame: frame)
    }

    func matches(_ other: WindowCandidate) -> Bool {
        CFEqual(window, other.window)
    }
}
