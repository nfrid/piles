import ApplicationServices
import CoreGraphics
import Foundation

final class MasterRatioDragHandler {
    enum Disposition {
        case notHandled
        case consume
        case passThrough(Unmanaged<CGEvent>)
    }

    private var isResizing = false
    private var resizeRegion: CGRect?
    private var pendingPoint: CGPoint?
    private var resizeWork: DispatchWorkItem?
    private var generation = 0
    private let resize: (CGPoint) -> Void

    init(resize: @escaping (CGPoint) -> Void = { WorkspaceManager.shared.resizeMasterRatio(at: $0) }) {
        self.resize = resize
    }

    func updateResizeRegion(_ region: CGRect?) {
        resizeRegion = region
        if region == nil { reset() }
    }

    func reset() {
        generation += 1
        isResizing = false
        pendingPoint = nil
        resizeWork?.cancel()
        resizeWork = nil
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
            scheduleResize(at: event.location)
            return .consume

        case .leftMouseDragged:
            guard isResizing else { return .notHandled }
            if !config.matchesConfiguredModifier(flags) {
                reset()
                return .passThrough(Self.passThrough(event))
            }
            scheduleResize(at: event.location)
            return .consume

        case .leftMouseDown:
            guard config.matchesConfiguredModifier(flags) else { return .notHandled }
            isResizing = resizeRegion?.contains(event.location) ?? false
            return isResizing ? .consume : .passThrough(Self.passThrough(event))

        default:
            return .notHandled
        }
    }

    private func scheduleResize(at point: CGPoint) {
        pendingPoint = point
        guard resizeWork == nil else { return }
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.resizeWork = nil
            guard let point = self.pendingPoint else { return }
            self.pendingPoint = nil
            self.resize(point)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    private static func passThrough(_ event: CGEvent) -> Unmanaged<CGEvent> {
        Unmanaged.passUnretained(event)
    }
}
