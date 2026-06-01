import Cocoa
import ApplicationServices

package final class Hotkeys {
    package static let shared = Hotkeys()

    private var tap: CFMachPort?
    private var resizingMasterRatio = false

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
        if config.modifier == .maskCommand && keyCode == Key.tab && flags.contains(.maskCommand) {
            return passThrough(event)
        }

        let hasModifier = flags.contains(config.modifier)
        let hasShift = flags.contains(.maskShift)
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

        for binding in config.customBindings {
            guard binding.key == keyCode, binding.shift == hasShift else { continue }
            let cmd = binding.command
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
        }

        if let number = config.numberKeys[keyCode] {
            let index = number - 1
            DispatchQueue.main.async {
                if hasShift {
                    WorkspaceManager.shared.moveActiveWindowAndSwitchTo(index)
                } else {
                    WorkspaceManager.shared.switchTo(index)
                }
            }
            return nil
        }

        let b = config.bindings

        if keyCode == b.focusMonitorPrev.key && hasShift == b.focusMonitorPrev.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.focusMonitor(offset: -1) }
            return nil
        }
        if keyCode == b.focusMonitorNext.key && hasShift == b.focusMonitorNext.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.focusMonitor(offset: 1) }
            return nil
        }
        if keyCode == b.moveMonitorPrev.key && hasShift == b.moveMonitorPrev.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.moveWindowToMonitor(offset: -1) }
            return nil
        }
        if keyCode == b.moveMonitorNext.key && hasShift == b.moveMonitorNext.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.moveWindowToMonitor(offset: 1) }
            return nil
        }
        if keyCode == b.workspacePrev.key && (hasShift || hasShift == b.workspacePrev.shift) {
            DispatchQueue.main.async {
                WorkspaceManager.shared.switchToOccupied(offset: -1, movingFocusedWindow: hasShift)
            }
            return nil
        }
        if keyCode == b.workspaceNext.key && (hasShift || hasShift == b.workspaceNext.shift) {
            DispatchQueue.main.async {
                WorkspaceManager.shared.switchToOccupied(offset: 1, movingFocusedWindow: hasShift)
            }
            return nil
        }
        if keyCode == b.lastWorkspace.key && hasShift == b.lastWorkspace.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.switchToLast() }
            return nil
        }
        if keyCode == b.focusNext.key && hasShift == b.focusNext.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.focusNext() }
            return nil
        }
        if keyCode == b.focusPrev.key && hasShift == b.focusPrev.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.focusPrev() }
            return nil
        }
        if keyCode == b.moveNext.key && hasShift == b.moveNext.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.moveFocusedWindowNext() }
            return nil
        }
        if keyCode == b.movePrev.key && hasShift == b.movePrev.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.moveFocusedWindowPrev() }
            return nil
        }
        if keyCode == b.swapMaster.key && hasShift == b.swapMaster.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.swapMaster() }
            return nil
        }
        if keyCode == b.toggleLayout.key && hasShift == b.toggleLayout.shift {
            DispatchQueue.main.async { WorkspaceManager.shared.toggleLayout() }
            return nil
        }

        return passThrough(event)
    }

    private static func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }
}
