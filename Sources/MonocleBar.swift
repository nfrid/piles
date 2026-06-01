import AppKit

package final class MonocleBar {
    package static let shared = MonocleBar()

    private let height: CGFloat = 34
    private let horizontalMargin: CGFloat = 12
    private let bottomMargin: CGFloat = 10
    private let animationDuration: TimeInterval = 0.12
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var lastState: MonocleBarState?
    private var optionHeld = false

    private init() {}

    package func setOptionHeld(_ held: Bool) {
        guard optionHeld != held else { return }
        optionHeld = held
        update()
    }

    package func update() {
        guard optionHeld else {
            hideAll()
            return
        }

        let ws = WorkspaceManager.shared
        guard let state = MonocleBarState.capture(ws) else {
            hideAll()
            lastState = nil
            return
        }

        hidePanels(except: state.displayID)
        guard state != lastState else {
            repositionPanel(displayID: state.displayID, screen: state.screen, contentWidth: state.contentWidth)
            showPanel(displayID: state.displayID, screen: state.screen, contentWidth: state.contentWidth)
            return
        }
        lastState = state

        let panel = panel(for: state.displayID)
        panel.contentView = MonocleBarView(items: state.items, focusedIndex: state.focusedIndex)
        showPanel(displayID: state.displayID, screen: state.screen, contentWidth: state.contentWidth)
    }

    private func panel(for displayID: CGDirectDisplayID) -> NSPanel {
        if let panel = panels[displayID] {
            return panel
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panels[displayID] = panel
        return panel
    }

    private func repositionPanel(displayID: CGDirectDisplayID, screen: NSScreen, contentWidth: CGFloat) {
        guard let panel = panels[displayID], panel.isVisible else { return }
        position(panel, screen: screen, contentWidth: contentWidth)
    }

    private func visibleFrame(screen: NSScreen, contentWidth: CGFloat) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = max(160, visible.width - horizontalMargin * 2)
        let width = min(maxWidth, max(160, contentWidth))
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + bottomMargin,
            width: width,
            height: height
        )
    }

    private func hiddenFrame(screen: NSScreen, contentWidth: CGFloat) -> NSRect {
        var frame = visibleFrame(screen: screen, contentWidth: contentWidth)
        frame.origin.y = screen.visibleFrame.minY - height
        return frame
    }

    private func position(_ panel: NSPanel, screen: NSScreen, contentWidth: CGFloat) {
        let frame = visibleFrame(screen: screen, contentWidth: contentWidth)
        panel.setFrame(frame, display: true)
    }

    private func showPanel(displayID: CGDirectDisplayID, screen: NSScreen, contentWidth: CGFloat) {
        let panel = panel(for: displayID)
        let target = visibleFrame(screen: screen, contentWidth: contentWidth)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(hiddenFrame(screen: screen, contentWidth: contentWidth), display: false)
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanels(except displayID: CGDirectDisplayID) {
        for (id, panel) in panels where id != displayID {
            hide(panel, cancelIfOptionHeld: false)
        }
    }

    private func hideAll() {
        lastState = nil
        for panel in panels.values {
            hide(panel, cancelIfOptionHeld: true)
        }
    }

    private func hide(_ panel: NSPanel, cancelIfOptionHeld: Bool) {
        guard panel.isVisible else { return }
        var target = panel.frame
        target.origin.y = panel.screen?.visibleFrame.minY ?? target.minY - height
        target.origin.y -= height

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            guard !cancelIfOptionHeld || !self.optionHeld else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }
}

private struct MonocleBarState: Equatable {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let items: [MonocleBarItem]
    let focusedIndex: Int
    let contentWidth: CGFloat

    static func == (lhs: MonocleBarState, rhs: MonocleBarState) -> Bool {
        lhs.displayID == rhs.displayID
            && lhs.screen.visibleFrame == rhs.screen.visibleFrame
            && lhs.items == rhs.items
            && lhs.focusedIndex == rhs.focusedIndex
    }

    static func capture(_ ws: WorkspaceManager) -> MonocleBarState? {
        guard !ws.monitors.isEmpty else { return nil }
        let monitor = ws.focusedMonitor
        guard monitor.layouts[monitor.active] == .monocle else { return nil }

        let windows = monitor.workspaces[monitor.active]
        guard !windows.isEmpty else { return nil }

        let items = windows.map { MonocleBarItem(title: label(for: $0)) }
        let focusedIndex = min(monitor.focusedIndices[monitor.active], windows.count - 1)
        return MonocleBarState(
            displayID: monitor.displayID,
            screen: monitor.screen,
            items: items,
            focusedIndex: focusedIndex,
            contentWidth: MonocleBarView.contentWidth(for: items)
        )
    }

    private static func label(for window: TrackedWindow) -> String {
        if let title = window.title()?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let app = NSRunningApplication(processIdentifier: window.pid),
           let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Window"
    }
}

private struct MonocleBarItem: Equatable {
    let title: String
}

private final class MonocleBarView: NSVisualEffectView {
    private static let maxItemWidth: CGFloat = 220
    private static let minItemWidth: CGFloat = 54
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 7

    init(items: [MonocleBarItem], focusedIndex: Int) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for index in items.indices {
            stack.addArrangedSubview(MonocleBarItemView(item: items[index], focused: index == focusedIndex))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func contentWidth(for items: [MonocleBarItem]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let widths = items.map { item in
            let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
            return min(maxItemWidth, max(minItemWidth, textWidth + 20))
        }
        let itemWidth = widths.reduce(0, +)
        let spacingWidth = max(0, CGFloat(items.count - 1)) * spacing
        return itemWidth + spacingWidth + inset * 2
    }
}

private final class MonocleBarItemView: NSView {
    private let focused: Bool

    init(item: MonocleBarItem, focused: Bool) {
        self.focused = focused
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = focused ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.backgroundColor = focused
            ? NSColor.white.withAlphaComponent(0.92).cgColor
            : NSColor.black.withAlphaComponent(0.18).cgColor

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.textColor = focused ? .black : .white.withAlphaComponent(0.88)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
