import Cocoa
import ApplicationServices

package enum HotkeyAction: Equatable {
    case passThrough
    case runCommand(String)
    case switchTo(Int)
    case moveActiveWindowAndSwitchTo(Int)
    case focusMonitor(Int)
    case moveWindowToMonitor(Int)
    case switchToOccupied(offset: Int, movingFocusedWindow: Bool)
    case switchToLast
    case focusNext
    case focusPrev
    case moveFocusedWindowNext
    case moveFocusedWindowPrev
    case swapMaster
    case toggleLayout
    case toggleWorkspaceOverview
    case toggleWorkspaceGlance
}

package struct HotkeyResolver {
    package init() {}

    package func resolve(keyCode: UInt16, flags: CGEventFlags, config: Config) -> HotkeyAction {
        if config.modifier == .maskCommand && keyCode == Key.tab && flags.contains(.maskCommand) {
            return .passThrough
        }

        guard config.matchesConfiguredModifier(flags) else {
            return .passThrough
        }
        let hasShift = flags.contains(.maskShift)

        for binding in config.customBindings {
            guard binding.key == keyCode, binding.shift == hasShift else { continue }
            return .runCommand(binding.command)
        }

        if let number = config.numberKeys[keyCode] {
            let index = number - 1
            return hasShift ? .moveActiveWindowAndSwitchTo(index) : .switchTo(index)
        }

        let b = config.bindings

        if matches(keyCode, hasShift, b.focusMonitorPrev) { return .focusMonitor(-1) }
        if matches(keyCode, hasShift, b.focusMonitorNext) { return .focusMonitor(1) }
        if matches(keyCode, hasShift, b.moveMonitorPrev) { return .moveWindowToMonitor(-1) }
        if matches(keyCode, hasShift, b.moveMonitorNext) { return .moveWindowToMonitor(1) }
        if keyCode == b.workspacePrev.key && (hasShift || hasShift == b.workspacePrev.shift) {
            return .switchToOccupied(offset: -1, movingFocusedWindow: hasShift)
        }
        if keyCode == b.workspaceNext.key && (hasShift || hasShift == b.workspaceNext.shift) {
            return .switchToOccupied(offset: 1, movingFocusedWindow: hasShift)
        }
        if matches(keyCode, hasShift, b.lastWorkspace) { return .switchToLast }
        if matches(keyCode, hasShift, b.focusNext) { return .focusNext }
        if matches(keyCode, hasShift, b.focusPrev) { return .focusPrev }
        if matches(keyCode, hasShift, b.moveNext) { return .moveFocusedWindowNext }
        if matches(keyCode, hasShift, b.movePrev) { return .moveFocusedWindowPrev }
        if matches(keyCode, hasShift, b.swapMaster) { return .swapMaster }
        if matches(keyCode, hasShift, b.toggleLayout) { return .toggleLayout }
        if matches(keyCode, hasShift, b.workspaceOverview) { return .toggleWorkspaceOverview }
        if matches(keyCode, hasShift, b.workspaceGlance) { return .toggleWorkspaceGlance }

        return .passThrough
    }

    private func matches(
        _ keyCode: UInt16,
        _ hasShift: Bool,
        _ binding: (key: UInt16, shift: Bool)
    ) -> Bool {
        keyCode == binding.key && hasShift == binding.shift
    }
}

package final class Hotkeys {
    package static let shared = Hotkeys()

    private var tap: CFMachPort?
    private var resizingMasterRatio = false
    private let resolver = HotkeyResolver()

    private init() {}

    private static func passThrough(_ event: CGEvent) -> Unmanaged<CGEvent> {
        Unmanaged.passUnretained(event)
    }

    package func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Hotkeys.callback,
            userInfo: nil
        ) else {
            fputs("piles: failed to create event tap (check Input Monitoring permission)\n", stderr)
            exit(1)
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = Hotkeys.shared.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passThrough(event)
        }

        let flags = event.flags
        if type == .flagsChanged {
            let optionHeld = flags.contains(.maskAlternate)
            MainThread.run {
                MonocleBar.shared.setOptionHeld(optionHeld)
            }
            return passThrough(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let config = Config.shared
        if type == .keyDown,
           WorkspaceOverview.shared.handleKey(keyCode: keyCode, flags: flags, config: config)
            || WorkspaceGlance.shared.handleKey(keyCode: keyCode, flags: flags, config: config) {
            return nil
        }

        if type == .leftMouseUp, Hotkeys.shared.resizingMasterRatio {
            Hotkeys.shared.resizingMasterRatio = false
            MainThread.run {
                WorkspaceManager.shared.resizeMasterRatio(at: event.location)
            }
            return nil
        }

        if type == .leftMouseDragged, Hotkeys.shared.resizingMasterRatio, !config.matchesConfiguredModifier(flags) {
            Hotkeys.shared.resizingMasterRatio = false
            return passThrough(event)
        }

        guard config.matchesConfiguredModifier(flags) else {
            return passThrough(event)
        }

        if type == .leftMouseDown {
            let started = MainThread.runSync {
                WorkspaceManager.shared.canResizeMasterRatio(at: event.location)
            }
            Hotkeys.shared.resizingMasterRatio = started
            return started ? nil : passThrough(event)
        }

        if type == .leftMouseDragged {
            guard Hotkeys.shared.resizingMasterRatio else { return passThrough(event) }
            MainThread.run {
                WorkspaceManager.shared.resizeMasterRatio(at: event.location)
            }
            return nil
        }

        guard type == .keyDown else {
            return passThrough(event)
        }

        return Hotkeys.shared.handle(action: Hotkeys.shared.resolver.resolve(
            keyCode: keyCode,
            flags: flags,
            config: config
        ), event: event)
    }

    private func handle(action: HotkeyAction, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch action {
        case .passThrough:
            return Self.passThrough(event)
        default:
            MainThread.run {
                ActionDispatcher.perform(action)
            }
            return nil
        }
    }
}
