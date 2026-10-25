import AppKit

package enum WindowRecovery {
    package struct Report {
        package fileprivate(set) var restored = 0
        package fileprivate(set) var skipped = 0
        package fileprivate(set) var failed = 0
        package let unavailableApplications: Int

        package var hasFailures: Bool { failed > 0 || unavailableApplications > 0 }
    }

    package enum RecoveryError: Error {
        case noScreens
    }

    /// A one-shot operation. The caller must hold the piles instance lock.
    package static func rescue() -> Result<Report, RecoveryError> {
        let screens = NSScreen.screens.map { WindowManager.screenFrame(for: $0) }
        guard screens.contains(where: isUsable) else { return .failure(.noScreens) }
        let inventory = WindowManager.scanWindows()
        return rescue(
            windows: inventory.windows,
            screens: screens,
            unavailableApplications: inventory.unavailableApplications
        )
    }

    static func rescue(
        windows: [TrackedWindow],
        screens: [CGRect],
        unavailableApplications: Int = 0,
        attributesFor: (TrackedWindow) -> WindowAttributes? = { $0.attributes() },
        frameFor: (TrackedWindow) -> CGRect? = { $0.getFrame() },
        move: (TrackedWindow, CGPoint) -> Bool = { $0.setPosition($1) }
    ) -> Result<Report, RecoveryError> {
        let screens = screens.filter(isUsable)
        guard !screens.isEmpty else { return .failure(.noScreens) }
        var report = Report(unavailableApplications: unavailableApplications)
        for window in windows {
            guard let attributes = attributesFor(window),
                  attributes.trackabilityKnown, attributes.fullscreenKnown else {
                report.failed += 1
                continue
            }
            guard attributes.isTileable else {
                report.skipped += 1
                continue
            }
            guard let frame = frameFor(window), isUsable(frame) else {
                report.failed += 1
                continue
            }
            guard let restored = recoveryFrame(for: frame, screens: screens) else {
                report.skipped += 1
                continue
            }
            if move(window, restored.origin) {
                report.restored += 1
            } else {
                report.failed += 1
            }
        }
        return .success(report)
    }

    /// Preserve size and prefer the display containing most of the window.
    /// Completely offscreen windows go to the nearest display, with stable ties.
    static func recoveryFrame(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard isUsable(frame) else { return nil }
        let screens = screens.filter(isUsable)
        guard !screens.isEmpty, !screens.contains(where: { $0.contains(frame) }) else { return nil }

        var target = screens[0]
        var bestArea: CGFloat = -1
        var bestDistance = CGFloat.infinity
        for screen in screens {
            let intersection = frame.intersection(screen)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let nearestX = min(max(frame.midX, screen.minX), screen.maxX)
            let nearestY = min(max(frame.midY, screen.minY), screen.maxY)
            let dx = frame.midX - nearestX
            let dy = frame.midY - nearestY
            let distance = dx * dx + dy * dy
            if area > bestArea || area == bestArea && distance < bestDistance {
                target = screen
                bestArea = area
                bestDistance = distance
            }
        }
        let restored = WorkspaceWindows.framePreservingSizeInsideScreen(frame, screen: target)
        return restored.origin == frame.origin ? nil : restored
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
