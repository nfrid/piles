import AppKit
import ApplicationServices

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
        if let current = getFrame(), WorkspaceWindows.isHiddenOffscreen(frame: current, screen: screen) {
            return true
        }
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

    @discardableResult
    func close() -> Bool {
        if let closeButton = WindowManager.closeButton(of: element) {
            return AXClient.performAction(
                kAXPressAction as CFString,
                on: closeButton,
                context: "pid=\(pid) closeButton"
            )
        }
        return AXClient.performAction("AXClose" as CFString, on: element, context: "pid=\(pid)")
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
