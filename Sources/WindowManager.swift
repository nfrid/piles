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

private enum AXClient {
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

struct TrackedWindow: Equatable {
    let element: AXUIElement
    let focusElement: AXUIElement
    let members: [AXUIElement]
    let pid: pid_t
    let group: WindowGroupKey
    private let referenceIdentities: Set<WindowIdentityKey>
    private let memberIdentities: Set<WindowIdentityKey>

    init(element: AXUIElement, pid: pid_t, members: [AXUIElement] = [], group: WindowGroupKey? = nil) {
        let window = WindowManager.canonicalWindowElement(element) ?? element
        let uniqueMembers = TrackedWindow.unique([window] + members)
        let uniqueReferences = TrackedWindow.unique([window, element] + uniqueMembers)
        self.element = window
        self.focusElement = element
        self.members = uniqueMembers
        self.pid = pid
        self.group = group ?? WindowGroupKey(pid: pid, frame: WindowManager.frame(of: window) ?? .null)
        self.referenceIdentities = Set(uniqueReferences.map(WindowIdentityKey.init))
        self.memberIdentities = Set(uniqueMembers.map(WindowIdentityKey.init))
    }

    static func == (lhs: TrackedWindow, rhs: TrackedWindow) -> Bool {
        lhs.hasElement(rhs)
    }

    func hasElement(_ other: TrackedWindow) -> Bool {
        !referenceIdentities.isDisjoint(with: other.referenceIdentities)
    }

    func hasSameMembers(_ other: TrackedWindow) -> Bool {
        memberIdentities == other.memberIdentities
    }

    func containsElement(_ element: AXUIElement) -> Bool {
        referenceIdentities.contains(WindowIdentityKey(element: element))
    }

    var identityKeys: Set<WindowIdentityKey> {
        referenceIdentities
    }

    package var overlayIdentityToken: Int {
        identityKeys.map(\.hashValue).max() ?? Int(truncatingIfNeeded: UInt32(pid))
    }

    func getFrame() -> CGRect? {
        WindowManager.frame(of: element)
    }

    func keepingMembers(from current: TrackedWindow) -> TrackedWindow {
        TrackedWindow(element: focusElement, pid: pid, members: current.members, group: group)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else {
            DebugLog.write("ax value create failed type=cgPoint pid=\(pid)")
            return false
        }
        var success = true
        for member in members {
            success = AXClient.setAttribute(
                kAXPositionAttribute as CFString,
                value: value,
                on: member,
                context: "pid=\(pid) position=(\(Int(point.x)),\(Int(point.y)))"
            ) && success
        }
        return success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else {
            DebugLog.write("ax value create failed type=cgSize pid=\(pid)")
            return false
        }
        var success = true
        for member in members {
            success = AXClient.setAttribute(
                kAXSizeAttribute as CFString,
                value: value,
                on: member,
                context: "pid=\(pid) size=\(Int(size.width))x\(Int(size.height))"
            ) && success
        }
        return success
    }

    @discardableResult
    func hideOffscreen(_ screen: CGRect) -> Bool {
        guard !isFullscreen() else { return false }
        return setPosition(CGPoint(x: screen.origin.x + 1 - screen.width, y: screen.maxY - 1))
    }

    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        guard isTileable() else { return false }
        return setFrameUnchecked(rect)
    }

    @discardableResult
    func setFrameUnchecked(_ rect: CGRect) -> Bool {
        let positioned = setPosition(rect.origin)
        let sized = setSize(rect.size)
        return positioned && sized
    }

    @discardableResult
    func focus() -> Bool {
        var success = true
        if let app = NSRunningApplication(processIdentifier: pid) {
            let activated = app.activate()
            if !activated {
                DebugLog.write("app activate failed pid=\(pid)")
            }
            success = activated && success
        }
        success = AXClient.performAction(
            kAXRaiseAction as CFString,
            on: element,
            context: "pid=\(pid)"
        ) && success
        success = AXClient.setAttribute(
            kAXMainAttribute as CFString,
            value: kCFBooleanTrue,
            on: element,
            context: "pid=\(pid) target=window"
        ) && success
        success = AXClient.setAttribute(
            kAXFocusedAttribute as CFString,
            value: kCFBooleanTrue,
            on: element,
            context: "pid=\(pid) target=window"
        ) && success
        success = AXClient.setAttribute(
            kAXMainAttribute as CFString,
            value: kCFBooleanTrue,
            on: focusElement,
            context: "pid=\(pid) target=focusElement"
        ) && success
        success = AXClient.setAttribute(
            kAXFocusedAttribute as CFString,
            value: kCFBooleanTrue,
            on: focusElement,
            context: "pid=\(pid) target=focusElement"
        ) && success
        return success
    }

    @discardableResult
    func raise() -> Bool {
        AXClient.performAction(kAXRaiseAction as CFString, on: element, context: "pid=\(pid)")
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

    func attributes() -> WindowAttributes? {
        WindowManager.attributes(of: element)
    }

    func title() -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func appName() -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    func displayTitle(fallback: String = "Window") -> String {
        if let title = title()?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let appName = appName()?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            return appName
        }
        return fallback
    }

    func displayLabels() -> (appName: String, windowTitle: String) {
        let trimmedApp = appName()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = (trimmedApp?.isEmpty == false) ? trimmedApp! : "App"
        let trimmedTitle = title()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : "Untitled window"
        return (appName, windowTitle)
    }

    func bundleID() -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    func appIcon() -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid),
           let icon = app.icon {
            return icon
        }
        if let bundleID = bundleID(),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private static func unique(_ elements: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var identities: Set<WindowIdentityKey> = []
        for element in elements where identities.insert(WindowIdentityKey(element: element)).inserted {
            result.append(element)
        }
        return result
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
