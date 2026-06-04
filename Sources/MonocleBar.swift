import AppKit
import QuartzCore

package final class MonocleBar {
    package static let shared = MonocleBar()

    private let height: CGFloat = 34
    private let horizontalMargin: CGFloat = 12
    private let bottomMargin: CGFloat = 10
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
        let updateKind = MonocleBarUpdateKind(previous: lastState, next: state)
        lastState = state

        let panel = panel(for: state.displayID)
        let accent = state.appearance.uiStyle(forWorkspace: state.activeWorkspace).accent
        if let view = panel.contentView as? MonocleBarView {
            switch updateKind {
            case .focusOnly:
                view.applyFocus(focusedIndex: state.focusedIndex, accentColor: accent)
            case .reorder, .inPlaceRefresh:
                view.reorderItems(
                    items: state.items,
                    focusedIndex: state.focusedIndex,
                    accentColor: accent
                )
            case .replace:
                view.transition(
                    items: state.items,
                    focusedIndex: state.focusedIndex,
                    accentColor: accent
                ) { [self] in
                    self.showPanel(
                        displayID: state.displayID,
                        screen: state.screen,
                        contentWidth: state.contentWidth
                    )
                }
                return
            }
            showPanel(
                displayID: state.displayID,
                screen: state.screen,
                contentWidth: state.contentWidth
            )
        } else {
            panel.contentView = MonocleBarView(
                items: state.items,
                focusedIndex: state.focusedIndex,
                accentColor: accent
            )
            showPanel(
                displayID: state.displayID,
                screen: state.screen,
                contentWidth: state.contentWidth
            )
        }
    }

    private func panel(for displayID: CGDirectDisplayID) -> NSPanel {
        if let panel = panels[displayID] {
            return panel
        }

        let panel = FloatingPanel.make(style: FloatingPanel.monocleBar)
        panels[displayID] = panel
        return panel
    }

    private func repositionPanel(displayID: CGDirectDisplayID, screen: NSScreen, contentWidth: CGFloat) {
        guard let panel = panels[displayID], panel.isVisible else { return }
        position(panel, screen: screen, contentWidth: contentWidth)
    }

    private func visibleFrame(screen: NSScreen, contentWidth: CGFloat) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = visible.width - horizontalMargin * 2
        let width = min(maxWidth, contentWidth)
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
        guard panel.isVisible else {
            panel.alphaValue = 0
            panel.setFrame(hiddenFrame(screen: screen, contentWidth: contentWidth), display: false)
            panel.orderFrontRegardless()
            PanelAnimation.run(duration: PanelAnimation.monocleDuration, timing: .easeOut) {
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
            return
        }

        panel.alphaValue = 1
        guard !NSEqualRects(panel.frame, target) else { return }
        PanelAnimation.run(duration: PanelAnimation.monocleDuration, timing: .easeOut) {
            panel.animator().setFrame(target, display: true)
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

        PanelAnimation.run(duration: PanelAnimation.monocleDuration, timing: .easeIn, changes: {
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completion: {
            guard !cancelIfOptionHeld || !self.optionHeld else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }
}

private struct MonocleBarState: Equatable {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let items: [MonocleBarItem]
    let focusedIndex: Int
    let contentWidth: CGFloat
    let appearance: AppearanceSnapshot
    let activeWorkspace: Int

    static func == (lhs: MonocleBarState, rhs: MonocleBarState) -> Bool {
        lhs.displayID == rhs.displayID
            && lhs.screen.visibleFrame == rhs.screen.visibleFrame
            && lhs.items == rhs.items
            && lhs.focusedIndex == rhs.focusedIndex
            && lhs.appearance == rhs.appearance
    }

    static func capture(_ ws: WorkspaceManager) -> MonocleBarState? {
        guard !ws.monitors.isEmpty else { return nil }
        let monitor = ws.focusedMonitor
        let activeWorkspace = monitor.active
        guard monitor.layouts[activeWorkspace] == .monocle else { return nil }

        let windows = monitor.workspaces[activeWorkspace]
        guard !windows.isEmpty else { return nil }

        let appearance = Config.shared.appearanceSnapshot
        let items = windows.map {
            MonocleBarItem(identity: $0.overlayIdentityToken, title: $0.displayTitle())
        }
        let focusedIndex = monitor.clampedFocus(in: activeWorkspace)
        return MonocleBarState(
            displayID: monitor.displayID,
            screen: monitor.screen,
            items: items,
            focusedIndex: focusedIndex,
            contentWidth: MonocleBarView.contentWidth(for: items),
            appearance: appearance,
            activeWorkspace: activeWorkspace
        )
    }
}

private enum MonocleBarUpdateKind {
    case focusOnly
    case reorder
    case inPlaceRefresh
    case replace

    init(previous: MonocleBarState?, next: MonocleBarState) {
        guard let previous else {
            self = .replace
            return
        }
        if previous.activeWorkspace != next.activeWorkspace {
            self = .replace
            return
        }
        if previous.items == next.items {
            self = .focusOnly
            return
        }

        let previousIDs = previous.items.map(\.identity)
        let nextIDs = next.items.map(\.identity)
        guard previousIDs.sorted() == nextIDs.sorted() else {
            self = .replace
            return
        }
        self = previousIDs == nextIDs ? .inPlaceRefresh : .reorder
    }
}

private struct MonocleBarItem: Equatable {
    let identity: Int
    let title: String
}

private final class MonocleBarView: NSVisualEffectView {
    private static let maxItemWidth: CGFloat = 220
    private static let minItemWidth: CGFloat = 54
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 7
    fileprivate static let focusTransitionDuration: TimeInterval = 0.08
    private static let itemDisappearDuration: TimeInterval = 0.04
    private static let itemAppearDuration: TimeInterval = 0.1
    private static let itemAppearStagger: TimeInterval = 0.018
    private static let reorderDuration: TimeInterval = 0.12

    private let stack: NSStackView
    private var itemViews: [MonocleBarItemView] = []
    private var viewsByIdentity: [Int: MonocleBarItemView] = [:]
    private var displayedItems: [MonocleBarItem] = []
    private var contentTransitionGeneration = 0

    init(items: [MonocleBarItem], focusedIndex: Int, accentColor: NSColor) {
        stack = NSStackView()
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)

        rebuildItems(items, focusedIndex: focusedIndex, accentColor: accentColor)
        stack.alphaValue = 1

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.animateItemsAppear()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyFocus(focusedIndex: Int, accentColor: NSColor) {
        for index in displayedItems.indices {
            itemViews[index].apply(
                item: displayedItems[index],
                focused: index == focusedIndex,
                accentColor: accentColor,
                animated: true
            )
        }
    }

    func reorderItems(items: [MonocleBarItem], focusedIndex: Int, accentColor: NSColor) {
        displayedItems = items
        let orderedViews = resolveViews(for: items, accentColor: accentColor)
        removeObsoleteViews(keeping: Set(items.map(\.identity)))

        for view in orderedViews where view.superview !== stack {
            stack.addArrangedSubview(view)
        }

        stack.layoutSubtreeIfNeeded()
        let startCenters = Dictionary(uniqueKeysWithValues: itemViews.map {
            ($0.identity, centerX(for: $0))
        })

        for (targetIndex, view) in orderedViews.enumerated() {
            guard let currentIndex = stack.arrangedSubviews.firstIndex(of: view),
                  currentIndex != targetIndex
            else { continue }
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: targetIndex)
        }

        itemViews = orderedViews
        stack.layoutSubtreeIfNeeded()
        animateSlide(
            from: startCenters,
            focusedIndex: focusedIndex,
            items: items,
            accentColor: accentColor
        )
    }

    private func centerX(for view: NSView) -> CGFloat {
        view.convert(view.bounds, to: self).midX
    }

    private func removeObsoleteViews(keeping identities: Set<Int>) {
        for view in itemViews where !identities.contains(view.identity) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            viewsByIdentity.removeValue(forKey: view.identity)
        }
    }

    private func animateSlide(
        from startCenters: [Int: CGFloat],
        focusedIndex: Int,
        items: [MonocleBarItem],
        accentColor: NSColor
    ) {
        var animatedAny = false

        for view in itemViews {
            guard let startCenter = startCenters[view.identity] else { continue }
            let endCenter = centerX(for: view)
            let deltaX = startCenter - endCenter
            guard abs(deltaX) > 0.5 else { continue }

            animatedAny = true
            view.layer?.removeAnimation(forKey: "reorder")
            let offset = CATransform3DMakeTranslation(deltaX, 0, 0)

            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: offset)
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = Self.reorderDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = true
            view.layer?.transform = CATransform3DIdentity
            view.layer?.add(animation, forKey: "reorder")
        }

        for (index, view) in itemViews.enumerated() {
            view.apply(
                item: items[index],
                focused: index == focusedIndex,
                accentColor: accentColor,
                animated: animatedAny
            )
        }
    }

    private func resolveViews(for items: [MonocleBarItem], accentColor: NSColor) -> [MonocleBarItemView] {
        items.map { item in
            if let existing = viewsByIdentity[item.identity] {
                return existing
            }
            let view = MonocleBarItemView(
                item: item,
                focused: false,
                accentColor: accentColor
            )
            viewsByIdentity[item.identity] = view
            return view
        }
    }

    func transition(
        items: [MonocleBarItem],
        focusedIndex: Int,
        accentColor: NSColor,
        completion: (() -> Void)? = nil
    ) {
        contentTransitionGeneration += 1
        let generation = contentTransitionGeneration

        let reveal = { [self] in
            guard generation == self.contentTransitionGeneration else { return }
            self.rebuildItems(items, focusedIndex: focusedIndex, accentColor: accentColor)
            self.animateItemsAppear(generation: generation)
            completion?()
        }

        guard !itemViews.isEmpty else {
            reveal()
            return
        }

        animateItemsDisappear(generation: generation) {
            reveal()
        }
    }

    private func animateItemsDisappear(generation: Int, completion: @escaping () -> Void) {
        let views = itemViews
        guard !views.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        for view in views {
            group.enter()
            view.animateDisappear(duration: Self.itemDisappearDuration) {
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            guard generation == self.contentTransitionGeneration else { return }
            completion()
        }
    }

    private func animateItemsAppear(generation: Int? = nil) {
        let generation = generation ?? contentTransitionGeneration
        for (index, view) in itemViews.enumerated() {
            view.prepareForAppear()
            view.animateAppear(
                delay: Double(index) * Self.itemAppearStagger,
                duration: Self.itemAppearDuration,
                isCurrent: { [weak self] in
                    self?.contentTransitionGeneration == generation
                }
            )
        }
    }

    private func rebuildItems(_ items: [MonocleBarItem], focusedIndex: Int, accentColor: NSColor) {
        displayedItems = items
        for view in itemViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews = []
        viewsByIdentity = [:]
        itemViews = items.indices.map { index in
            let view = MonocleBarItemView(
                item: items[index],
                focused: index == focusedIndex,
                accentColor: accentColor
            )
            viewsByIdentity[items[index].identity] = view
            view.prepareForAppear()
            stack.addArrangedSubview(view)
            return view
        }
    }

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
    fileprivate let identity: Int
    private var focused: Bool
    private let title: NSTextField

    init(item: MonocleBarItem, focused: Bool, accentColor: NSColor) {
        self.identity = item.identity
        self.focused = focused
        title = NSTextField(labelWithString: item.title)
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
        ]

        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
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

        applyStyle(accentColor: accentColor, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func prepareForAppear() {
        layer?.removeAnimation(forKey: "appear")
        alphaValue = 0
        layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)
    }

    func animateDisappear(duration: TimeInterval, completion: (() -> Void)? = nil) {
        layer?.removeAnimation(forKey: "appear")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: {
            completion?()
        }
    }

    func animateAppear(
        delay: TimeInterval,
        duration: TimeInterval,
        isCurrent: @escaping () -> Bool
    ) {
        let start = { [weak self] in
            guard let self, isCurrent() else { return }
            self.layer?.removeAnimation(forKey: "appear")

            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = self.layer?.transform ?? CATransform3DMakeScale(0.94, 0.94, 1)
            scale.toValue = CATransform3DIdentity
            scale.duration = duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            self.layer?.add(scale, forKey: "appear")

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
        } else {
            start()
        }
    }

    func apply(item: MonocleBarItem, focused: Bool, accentColor: NSColor, animated: Bool) {
        if title.stringValue != item.title {
            title.stringValue = item.title
        }
        let focusChanged = self.focused != focused
        self.focused = focused
        applyStyle(accentColor: accentColor, animated: animated && focusChanged)
    }

    private func applyStyle(accentColor: NSColor, animated: Bool) {
        let apply = {
            self.layer?.borderWidth = self.focused ? 0 : 1
            self.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
            self.layer?.backgroundColor = self.focused
                ? accentColor.cgColor
                : NSColor.black.withAlphaComponent(0.18).cgColor
            self.title.textColor = self.focused
                ? accentColor.contrastingTextColor
                : .white.withAlphaComponent(0.88)
        }

        guard animated else {
            apply()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = MonocleBarView.focusTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            apply()
        }
    }
}
