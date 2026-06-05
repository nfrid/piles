import ApplicationServices
import CoreGraphics

final class MasterRatioDragHandler {
    enum Disposition {
        case notHandled
        case consume
        case passThrough(Unmanaged<CGEvent>)
    }

    private var isResizing = false

    func reset() {
        isResizing = false
    }

    func handle(
        type: CGEventType,
        event: CGEvent,
        flags: CGEventFlags,
        config: Config
    ) -> Disposition {
        switch type {
        case .leftMouseUp:
            guard isResizing else { return .notHandled }
            isResizing = false
            MainThread.run {
                WorkspaceManager.shared.resizeMasterRatio(at: event.location)
            }
            return .consume

        case .leftMouseDragged:
            guard isResizing else { return .notHandled }
            if !config.matchesConfiguredModifier(flags) {
                isResizing = false
                return .passThrough(Self.passThrough(event))
            }
            MainThread.run {
                WorkspaceManager.shared.resizeMasterRatio(at: event.location)
            }
            return .consume

        case .leftMouseDown:
            guard config.matchesConfiguredModifier(flags) else { return .notHandled }
            let started = MainThread.runSync {
                WorkspaceManager.shared.canResizeMasterRatio(at: event.location)
            }
            isResizing = started
            return started ? .consume : .passThrough(Self.passThrough(event))

        default:
            return .notHandled
        }
    }

    private static func passThrough(_ event: CGEvent) -> Unmanaged<CGEvent> {
        Unmanaged.passUnretained(event)
    }
}
