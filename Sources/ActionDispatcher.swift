import Cocoa

package enum ActionDispatcher {
    package static func perform(_ action: HotkeyAction) {
        switch action {
        case .passThrough:
            break
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
        case .switchTo(let index):
            onMain { WorkspaceManager.shared.switchTo(index) }
        case .moveActiveWindowAndSwitchTo(let index):
            onMain { WorkspaceManager.shared.moveActiveWindowAndSwitchTo(index) }
        case .focusMonitor(let offset):
            onMain { WorkspaceManager.shared.focusMonitor(offset: offset) }
        case .moveWindowToMonitor(let offset):
            onMain { WorkspaceManager.shared.moveWindowToMonitor(offset: offset) }
        case .switchToOccupied(let offset, let movingFocusedWindow):
            onMain {
                WorkspaceManager.shared.switchToOccupied(
                    offset: offset,
                    movingFocusedWindow: movingFocusedWindow
                )
            }
        case .switchToLast:
            onMain { WorkspaceManager.shared.switchToLast() }
        case .focusNext:
            onMain { WorkspaceManager.shared.focusNext() }
        case .focusPrev:
            onMain { WorkspaceManager.shared.focusPrev() }
        case .moveFocusedWindowNext:
            onMain { WorkspaceManager.shared.moveFocusedWindowNext() }
        case .moveFocusedWindowPrev:
            onMain { WorkspaceManager.shared.moveFocusedWindowPrev() }
        case .swapMaster:
            onMain { WorkspaceManager.shared.swapMaster() }
        case .toggleLayout:
            onMain { WorkspaceManager.shared.toggleLayout() }
        case .toggleWorkspaceOverview:
            onMain { WorkspaceOverview.shared.toggle() }
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
