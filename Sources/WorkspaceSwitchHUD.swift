import AppKit
import QuartzCore

private enum WorkspaceSwitchHUDMetrics {
    static let height: CGFloat = 34
    static let topMargin: CGFloat = 10
    static let displayDuration: TimeInterval = 0.5
    static let slideDuration: TimeInterval = 0.10
    static let resizeDuration: TimeInterval = 0.10
    static let accentWidth: CGFloat = 4
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let chevronWidth: CGFloat = 10
}

package final class WorkspaceSwitchHUD {
    package static let shared = WorkspaceSwitchHUD()

    private var panel: NSPanel?
    private var hudView: WorkspaceSwitchHUDView?
    private var hideWork: DispatchWorkItem?
    private var displayedWorkspaceIndex: Int?
    private var presentationGeneration = 0

    private init() {}

    package func show(workspaceIndex: Int, on screen: NSScreen, direction: Int?) {
        hideWork?.cancel()
        hideWork = nil
        presentationGeneration += 1
        let generation = presentationGeneration

        let appearance = Config.shared.appearanceSnapshot
        let style = appearance.uiStyle(forWorkspace: workspaceIndex)
        let state = WorkspaceSwitchHUDState(
            workspaceIndex: workspaceIndex,
            title: style.displayName,
            accentColor: style.accent,
            direction: direction
        )

        let panel = ensurePanel()
        dismissGhostPanelIfNeeded(panel)
        let view = ensureView(on: panel)
        let targetFrame = frame(on: screen, contentWidth: WorkspaceSwitchHUDView.contentWidth(for: state))
        let transitioning = displayedWorkspaceIndex != workspaceIndex
        displayedWorkspaceIndex = workspaceIndex

        let revealedFresh = bringPanelToFront(panel, targetFrame: targetFrame)

        if transitioning {
            view.transition(to: state, direction: direction)
        } else {
            view.apply(state: state)
        }

        if !revealedFresh {
            animateFrame(panel, to: targetFrame)
        }
        scheduleHide(generation: generation)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = FloatingPanel.make(style: FloatingPanel.workspaceHUD)
        self.panel = panel
        return panel
    }

    private func ensureView(on panel: NSPanel) -> WorkspaceSwitchHUDView {
        if let hudView {
            return hudView
        }

        let view = WorkspaceSwitchHUDView()
        panel.contentView = view
        hudView = view
        return view
    }

    private func dismissGhostPanelIfNeeded(_ panel: NSPanel) {
        guard panel.isVisible, panel.alphaValue <= 0.01 else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        displayedWorkspaceIndex = nil
    }

    @discardableResult
    private func bringPanelToFront(_ panel: NSPanel, targetFrame: NSRect) -> Bool {
        if !panel.isEffectivelyVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let needsFrame = !NSEqualRects(panel.frame, targetFrame)
            PanelAnimation.run(duration: PanelAnimation.hudFadeInDuration, timing: .easeOut) {
                panel.animator().alphaValue = 1
                if needsFrame {
                    panel.animator().setFrame(targetFrame, display: true)
                }
            }
            return true
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        return false
    }

    private func frame(on screen: NSScreen, contentWidth: CGFloat) -> NSRect {
        let visible = screen.visibleFrame
        let height = WorkspaceSwitchHUDMetrics.height
        return NSRect(
            x: visible.midX - contentWidth / 2,
            y: visible.maxY - height - WorkspaceSwitchHUDMetrics.topMargin,
            width: contentWidth,
            height: height
        )
    }

    private func animateFrame(_ panel: NSPanel, to targetFrame: NSRect) {
        guard !NSEqualRects(panel.frame, targetFrame) else { return }
        PanelAnimation.run(duration: WorkspaceSwitchHUDMetrics.resizeDuration, timing: .easeOut) {
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func scheduleHide(generation: Int) {
        let work = DispatchWorkItem { [self] in
            guard generation == presentationGeneration else { return }
            guard let panel, panel.isVisible else { return }
            fadeOutAndHide(panel: panel, generation: generation)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WorkspaceSwitchHUDMetrics.displayDuration,
            execute: work
        )
    }

    private func fadeOutAndHide(panel: NSPanel, generation: Int) {
        let duration = PanelAnimation.hudFadeOutDuration
        let start = ProcessInfo.processInfo.systemUptime
        let startAlpha = panel.alphaValue

        func tick() {
            guard generation == presentationGeneration else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let progress = min(elapsed / duration, 1)
            panel.alphaValue = startAlpha * (1 - progress)
            guard progress < 1 else {
                guard generation == presentationGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                displayedWorkspaceIndex = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: tick)
        }

        tick()
    }
}

private struct WorkspaceSwitchHUDState: Equatable {
    let workspaceIndex: Int
    let title: String
    let accentColor: NSColor
    let direction: Int?
}

private final class WorkspaceSwitchHUDView: NSVisualEffectView {
    private let accentBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let contentStack: NSStackView
    private var slideGeneration = 0

    init() {
        contentStack = NSStackView()
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        self.state = .active
        wantsLayer = true
        layer?.cornerRadius = OverlayMetrics.barCornerRadius
        layer?.masksToBounds = true

        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = OverlayMetrics.accentStripCornerRadius
        accentBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.wantsLayer = true

        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevronView.contentTintColor = .white.withAlphaComponent(0.82)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = WorkspaceSwitchHUDMetrics.spacing
        contentStack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: WorkspaceSwitchHUDMetrics.inset,
            bottom: 0,
            right: WorkspaceSwitchHUDMetrics.inset
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(accentBar)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(chevronView)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            accentBar.widthAnchor.constraint(equalToConstant: WorkspaceSwitchHUDMetrics.accentWidth),
            accentBar.heightAnchor.constraint(equalToConstant: 18),

            chevronView.widthAnchor.constraint(equalToConstant: WorkspaceSwitchHUDMetrics.chevronWidth),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: WorkspaceSwitchHUDState) {
        slideGeneration += 1
        titleLabel.layer?.removeAllAnimations()
        titleLabel.layer?.transform = CATransform3DIdentity
        titleLabel.alphaValue = 1

        titleLabel.stringValue = state.title
        titleLabel.textColor = .white.withAlphaComponent(0.94)
        accentBar.layer?.backgroundColor = state.accentColor.cgColor
        updateChevron(direction: state.direction)
    }

    func transition(to state: WorkspaceSwitchHUDState, direction: Int?) {
        slideGeneration += 1
        let generation = slideGeneration
        let offset = slideOffset(for: direction)

        titleLabel.layer?.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(offset, 0, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = WorkspaceSwitchHUDMetrics.slideDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = true
        titleLabel.layer?.transform = CATransform3DIdentity
        titleLabel.layer?.add(animation, forKey: "slide")

        DispatchQueue.main.asyncAfter(deadline: .now() + WorkspaceSwitchHUDMetrics.slideDuration / 2) {
            [weak self] in
            guard let self, generation == self.slideGeneration else { return }
            self.apply(state: state)
            self.titleLabel.layer?.transform = CATransform3DMakeTranslation(-offset, 0, 0)

            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(-offset, 0, 0))
            settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            settle.duration = WorkspaceSwitchHUDMetrics.slideDuration
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            settle.isRemovedOnCompletion = true
            self.titleLabel.layer?.transform = CATransform3DIdentity
            self.titleLabel.layer?.add(settle, forKey: "slide")
        }
    }

    static func contentWidth(for state: WorkspaceSwitchHUDState) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let titleWidth = min(
            (state.title as NSString).size(withAttributes: [.font: font]).width,
            280
        )
        let chevronWidth = state.direction == nil ? 0 : WorkspaceSwitchHUDMetrics.chevronWidth
        let chevronSpacing = state.direction == nil ? 0 : WorkspaceSwitchHUDMetrics.spacing
        return WorkspaceSwitchHUDMetrics.inset * 2
            + WorkspaceSwitchHUDMetrics.accentWidth
            + WorkspaceSwitchHUDMetrics.spacing
            + ceil(titleWidth)
            + chevronSpacing
            + chevronWidth
    }

    private func updateChevron(direction: Int?) {
        guard let direction, direction != 0 else {
            chevronView.isHidden = true
            chevronView.image = nil
            return
        }

        let symbol = direction > 0 ? "chevron.right" : "chevron.left"
        chevronView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )
        chevronView.isHidden = false
    }

    private func slideOffset(for direction: Int?) -> CGFloat {
        guard let direction, direction != 0 else { return 10 }
        return direction > 0 ? 14 : -14
    }
}

private extension NSPanel {
    var isEffectivelyVisible: Bool {
        isVisible && alphaValue > 0.01
    }
}
