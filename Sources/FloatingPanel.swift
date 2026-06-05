import AppKit

enum FloatingPanel {
    struct Style {
        let level: NSWindow.Level
        let ignoresMouseEvents: Bool
        let collectionBehavior: NSWindow.CollectionBehavior
    }

    static let overlay = Style(
        level: .modalPanel,
        ignoresMouseEvents: false,
        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]
    )

    static let monocleBar = Style(
        level: .statusBar,
        ignoresMouseEvents: true,
        collectionBehavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    )

    static func make(contentRect: NSRect = .zero, style: Style) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = style.ignoresMouseEvents
        panel.level = style.level
        panel.collectionBehavior = style.collectionBehavior
        return panel
    }
}

enum PanelAnimation {
    static let overlayDuration: TimeInterval = 0.10
    static let monocleDuration: TimeInterval = 0.12
    static let hudFadeInDuration: TimeInterval = 0.05
    static let hudFadeOutDuration: TimeInterval = 0.08

    static func run(
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            changes()
        } completionHandler: {
            completion?()
        }
    }

    static func fadeIn(_ panel: NSPanel, duration: TimeInterval = overlayDuration) {
        run(duration: duration, timing: .easeOut) {
            panel.animator().alphaValue = 1
        }
    }

    static func fadeOut(
        _ panel: NSPanel,
        duration: TimeInterval = overlayDuration,
        completion: @escaping () -> Void
    ) {
        run(duration: duration, timing: .easeIn, changes: {
            panel.animator().alphaValue = 0
        }, completion: completion)
    }
}
