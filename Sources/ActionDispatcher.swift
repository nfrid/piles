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
            MainThread.run { WorkspaceManager.shared.switchTo(index) }
        case .moveActiveWindowTo(let index):
            MainThread.run { WorkspaceManager.shared.moveActiveWindowTo(index) }
        case .focusMonitor(let offset):
            MainThread.run { WorkspaceManager.shared.focusMonitor(offset: offset) }
        case .moveWindowToMonitor(let offset):
            MainThread.run { WorkspaceManager.shared.moveWindowToMonitor(offset: offset) }
        case .switchToOccupied(let offset, let movingFocusedWindow):
            MainThread.run {
                WorkspaceManager.shared.switchToOccupied(
                    offset: offset,
                    movingFocusedWindow: movingFocusedWindow
                )
            }
        case .switchToLast:
            MainThread.run { WorkspaceManager.shared.switchToLast() }
        case .focusNext:
            MainThread.run { WorkspaceManager.shared.focusNext() }
        case .focusPrev:
            MainThread.run { WorkspaceManager.shared.focusPrev() }
        case .moveFocusedWindowNext:
            MainThread.run { WorkspaceManager.shared.moveFocusedWindowNext() }
        case .moveFocusedWindowPrev:
            MainThread.run { WorkspaceManager.shared.moveFocusedWindowPrev() }
        case .swapMaster:
            MainThread.run { WorkspaceManager.shared.swapMaster() }
        case .toggleLayout:
            MainThread.run { WorkspaceManager.shared.toggleLayout() }
        case .toggleWorkspaceOverview:
            MainThread.run { WorkspaceOverview.shared.toggle() }
        case .toggleWorkspaceGlance:
            MainThread.run { WorkspaceGlance.shared.toggle() }
        }
    }
}
