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

struct WindowAttributes {
    let role: String?
    let subrole: String?
    let minimized: Bool
    let fullscreen: Bool

    var isStandardWindow: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    var isTrackable: Bool {
        isStandardWindow && !minimized
    }

    var isTileable: Bool {
        isTrackable && !fullscreen
    }
}

package struct WindowIdentityKey: Hashable {
    let element: AXUIElement

    package static func == (lhs: WindowIdentityKey, rhs: WindowIdentityKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
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

    static func attributes(of element: AXUIElement) -> WindowAttributes? {
        let role = axStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = axStringAttribute(element, kAXSubroleAttribute as CFString)
        guard role != nil || subrole != nil else { return nil }

        return WindowAttributes(
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
            guard !app.isHidden else { continue }
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
        guard !isAppHidden(pid: pid) else { return [] }
        let appRef = AXUIElementCreateApplication(pid)

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return nil }

        return trackedWindows(pid: pid, windows: windows)
    }

    static func isAppHidden(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    static func trackedWindows(pid: pid_t, windows: [AXUIElement]) -> [TrackedWindow] {
        let candidates = windows.compactMap { WindowCandidate(element: $0, pid: pid) }
        var groups: [WindowIdentityKey: WindowCandidateGroup] = [:]
        var orderedKeys: [WindowIdentityKey] = []

        for candidate in candidates {
            let key = WindowIdentityKey(element: candidate.window)
            if groups[key] == nil {
                groups[key] = WindowCandidateGroup(first: candidate)
                orderedKeys.append(key)
            }
            groups[key]?.members.append(candidate.window)
        }

        return orderedKeys.compactMap { key in
            guard let group = groups[key] else { return nil }
            return TrackedWindow(
                element: group.first.element,
                pid: pid,
                members: group.members,
                group: group.first.group
            )
        }
    }

    static func focusedWindow() -> TrackedWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        return focusedWindow(pid: pid)
    }

    @discardableResult
    static func closeFocusedWindow() -> Bool {
        focusedWindow()?.close() ?? false
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
        attributes(of: element)?.isTrackable ?? false
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        attributes(of: element)?.fullscreen ?? false
    }

    static func isTileable(_ element: AXUIElement) -> Bool {
        attributes(of: element)?.isTileable ?? false
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        attributes(of: element)?.isStandardWindow ?? false
    }

    static func closeButton(of element: AXUIElement) -> AXUIElement? {
        axElementAttribute(element, kAXCloseButtonAttribute as CFString)
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
    let group: WindowGroupKey

    init?(element: AXUIElement, pid: pid_t) {
        let window = WindowManager.canonicalWindowElement(element) ?? element
        guard WindowManager.isTrackable(window), let frame = WindowManager.frame(of: window) else { return nil }
        self.element = element
        self.window = window
        self.group = WindowGroupKey(pid: pid, frame: frame)
    }
}

private struct WindowCandidateGroup {
    let first: WindowCandidate
    var members: [AXUIElement] = []
}
