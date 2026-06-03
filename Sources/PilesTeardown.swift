import Foundation

package enum PilesTeardown {
    private static var didShutdown = false

    package static func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        WindowObserver.shared.stop()
        Hotkeys.shared.stop()
        IPCServer.shared.stop()
        WorkspaceManager.shared.restoreAllWindows()
    }
}
