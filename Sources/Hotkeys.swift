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
}

package struct HotkeyResolver {
    package init() {}

    package func resolve(keyCode: UInt16, flags: CGEventFlags, config: Config) -> HotkeyAction {
        if config.modifier == .maskCommand && keyCode == Key.tab && flags.contains(.maskCommand) {
            return .passThrough
        }

        let hasModifier = flags.contains(config.modifier)
        let hasShift = flags.contains(.maskShift)
        let hasExtraModifiers =
            (config.modifier != .maskCommand && flags.contains(.maskCommand)) ||
            (config.modifier != .maskControl && flags.contains(.maskControl)) ||
            (config.modifier != .maskAlternate && flags.contains(.maskAlternate))

        guard hasModifier, !hasExtraModifiers else {
            return .passThrough
        }

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
            DispatchQueue.main.async {
                MonocleBar.shared.setOptionHeld(optionHeld)
            }
            return passThrough(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let config = Config.shared
        let hasModifier = flags.contains(config.modifier)
        let hasExtraModifiers =
            (config.modifier != .maskCommand && flags.contains(.maskCommand)) ||
            (config.modifier != .maskControl && flags.contains(.maskControl)) ||
            (config.modifier != .maskAlternate && flags.contains(.maskAlternate))

        if type == .leftMouseUp, Hotkeys.shared.resizingMasterRatio {
            Hotkeys.shared.resizingMasterRatio = false
            DispatchQueue.main.async {
                WorkspaceManager.shared.resizeMasterRatio(at: event.location)
            }
            return nil
        }

        if type == .leftMouseDragged, Hotkeys.shared.resizingMasterRatio, !hasModifier {
            Hotkeys.shared.resizingMasterRatio = false
            return passThrough(event)
        }

        guard hasModifier, !hasExtraModifiers else {
            return passThrough(event)
        }

        if type == .leftMouseDown {
            let started = onMain {
                WorkspaceManager.shared.canResizeMasterRatio(at: event.location)
            }
            Hotkeys.shared.resizingMasterRatio = started
            return started ? nil : passThrough(event)
        }

        if type == .leftMouseDragged {
            guard Hotkeys.shared.resizingMasterRatio else { return passThrough(event) }
            DispatchQueue.main.async {
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
        case .runCommand(let cmd):
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", cmd]
                do {
                    try process.run()
                } catch {
                    fputs("piles: failed to run custom command '\(cmd)': \(error)\n", stderr)
                }
            }
            return nil
        case .switchTo(let index):
            DispatchQueue.main.async {
                WorkspaceManager.shared.switchTo(index)
            }
            return nil
        case .moveActiveWindowAndSwitchTo(let index):
            DispatchQueue.main.async {
                WorkspaceManager.shared.moveActiveWindowAndSwitchTo(index)
            }
            return nil
        case .focusMonitor(let offset):
            DispatchQueue.main.async { WorkspaceManager.shared.focusMonitor(offset: offset) }
            return nil
        case .moveWindowToMonitor(let offset):
            DispatchQueue.main.async { WorkspaceManager.shared.moveWindowToMonitor(offset: offset) }
            return nil
        case .switchToOccupied(let offset, let movingFocusedWindow):
            DispatchQueue.main.async {
                WorkspaceManager.shared.switchToOccupied(
                    offset: offset,
                    movingFocusedWindow: movingFocusedWindow
                )
            }
            return nil
        case .switchToLast:
            DispatchQueue.main.async { WorkspaceManager.shared.switchToLast() }
            return nil
        case .focusNext:
            DispatchQueue.main.async { WorkspaceManager.shared.focusNext() }
            return nil
        case .focusPrev:
            DispatchQueue.main.async { WorkspaceManager.shared.focusPrev() }
            return nil
        case .moveFocusedWindowNext:
            DispatchQueue.main.async { WorkspaceManager.shared.moveFocusedWindowNext() }
            return nil
        case .moveFocusedWindowPrev:
            DispatchQueue.main.async { WorkspaceManager.shared.moveFocusedWindowPrev() }
            return nil
        case .swapMaster:
            DispatchQueue.main.async { WorkspaceManager.shared.swapMaster() }
            return nil
        case .toggleLayout:
            DispatchQueue.main.async { WorkspaceManager.shared.toggleLayout() }
            return nil
        }
    }

    private static func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }
}
