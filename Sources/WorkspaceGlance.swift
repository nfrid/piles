import AppKit

private enum GlanceMetrics {
    static let screenFraction: CGFloat = 0.8
    static let gridColumns = 3
    static let headerFontSize: CGFloat = 17
    static let bodyFontSize: CGFloat = 13
    static let hintFontSize: CGFloat = 12

    struct Typography {
        let appFontSize: CGFloat
        let titleFontSize: CGFloat
        let iconSize: CGFloat
        let contentSpacing: CGFloat
        let captionSpacing: CGFloat
        let titleLineCount: Int
    }

    static func typography(forCellHeight cellHeight: CGFloat) -> Typography {
        let minHeight: CGFloat = 72
        let maxHeight: CGFloat = 210
        let t = min(max((cellHeight - minHeight) / (maxHeight - minHeight), 0), 1)
        func lerp(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * t }

        let iconCap = max(cellHeight * 0.4, 24)
        return Typography(
            appFontSize: lerp(11, 18),
            titleFontSize: lerp(9, 14),
            iconSize: min(lerp(26, 52), iconCap),
            contentSpacing: lerp(4, 10),
            captionSpacing: lerp(1, 3),
            titleLineCount: cellHeight < 96 ? 1 : 2
        )
    }
}

package final class WorkspaceGlance {
    package static let shared = WorkspaceGlance()
    private let animationDuration: TimeInterval = 0.14
    private var panel: NSPanel?
    package private(set) var isVisible = false
    private var selectedWindow = 0
    private var viewedWorkspaceIndex: Int?

    private init() {}

    package func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    package func show() {
        viewedWorkspaceIndex = nil
        guard let state = captureState() else { return }
        WorkspaceOverview.shared.hide()
        resetSelection(from: state)
        isVisible = true
        present(state: state)
    }

    package func show(workspaceIndex: Int, windowIndex: Int? = nil) {
        viewedWorkspaceIndex = workspaceIndex
        guard let state = captureState() else { return }
        WorkspaceOverview.shared.hide()
        if let windowIndex {
            selectedWindow = windowIndex
            clampSelection(to: state)
        } else {
            resetSelection(from: state)
        }
        isVisible = true
        present(state: state)
    }

    package func hide() {
        guard isVisible else { return }
        isVisible = false
        viewedWorkspaceIndex = nil
        guard let panel, panel.isVisible else {
            self.panel = nil
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
            if !self.isVisible {
                self.panel = nil
            }
        }
    }

    package func refreshIfVisible() {
        guard isVisible else { return }
        guard let state = captureState() else {
            hide()
            return
        }
        clampSelection(to: state)
        present(state: state, animated: false)
    }

    package func handleKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
        guard isVisible else { return false }

        if keyCode == Key.escape {
            DispatchQueue.main.async { self.hide() }
            return true
        }

        if flags.contains(.maskCommand) {
            return false
        }

        if let number = config.numberKeys[keyCode] {
            let index = number - 1
            DispatchQueue.main.async {
                self.activate(windowIndex: index)
                self.hide()
            }
            return true
        }

        let binding = config.bindings.workspaceGlance
        let hasShift = flags.contains(.maskShift)
        if config.matchesConfiguredModifier(flags),
           keyCode == binding.key,
           hasShift == binding.shift {
            DispatchQueue.main.async { self.hide() }
            return true
        }

        switch keyCode {
        case Key.h:
            DispatchQueue.main.async { self.moveWindowHorizontal(-1) }
            return true
        case Key.l:
            DispatchQueue.main.async { self.moveWindowHorizontal(1) }
            return true
        case Key.j:
            DispatchQueue.main.async { self.moveWindowRow(1) }
            return true
        case Key.k:
            DispatchQueue.main.async { self.moveWindowRow(-1) }
            return true
        case Key.return, Key.m:
            DispatchQueue.main.async { self.confirmSelection() }
            return true
        default:
            return true
        }
    }

    private func resetSelection(from state: GlanceState) {
        selectedWindow = state.focusedWindowIndex
    }

    private func clampSelection(to state: GlanceState) {
        guard !state.windows.isEmpty else {
            selectedWindow = 0
            return
        }
        selectedWindow = min(max(selectedWindow, 0), state.windows.count - 1)
    }

    private func moveWindowHorizontal(_ delta: Int) {
        guard let state = captureState() else { return }
        let count = state.windows.count
        let columns = GlanceMetrics.gridColumns
        guard count > 0 else { return }

        let row = selectedWindow / columns
        let rowStart = row * columns
        let slots = min(columns, count - rowStart)
        guard slots > 0 else { return }

        let column = selectedWindow - rowStart
        selectedWindow = rowStart + (column + delta + slots) % slots
        present(state: state, animated: false)
    }

    private func moveWindowRow(_ delta: Int) {
        guard let state = captureState() else { return }
        let count = state.windows.count
        guard count > 0 else { return }
        let step = delta * GlanceMetrics.gridColumns
        selectedWindow = (selectedWindow + step + count) % count
        present(state: state, animated: false)
    }

    private func confirmSelection() {
        activate(windowIndex: selectedWindow)
        hide()
    }

    private func activate(windowIndex: Int) {
        guard let state = captureState(),
              state.windows.indices.contains(windowIndex)
        else { return }
        WorkspaceManager.shared.focusWindow(
            workspaceIndex: state.workspaceIndex,
            windowIndex: windowIndex
        )
    }

    private func present(state: GlanceState, animated: Bool = true) {
        let panel = panel(for: state.screen)
        panel.contentView = GlanceRootView(
            state: state,
            selectedWindow: selectedWindow,
            onSelectWindow: { [weak self] index in
                self?.activate(windowIndex: index)
                self?.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        panel.setFrame(state.screen.frame, display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        guard animated else {
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func panel(for screen: NSScreen) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func captureState() -> GlanceState? {
        GlanceState.capture(workspaceIndex: viewedWorkspaceIndex)
    }
}

private struct GlanceState {
    let screen: NSScreen
    let monitorLabel: String?
    let workspaceIndex: Int
    let workspaceNumber: Int
    let windows: [GlanceWindow]
    let focusedWindowIndex: Int

    static func capture(workspaceIndex: Int? = nil) -> GlanceState? {
        let ws = WorkspaceManager.shared
        guard !ws.monitors.isEmpty else { return nil }

        let monitor = ws.focusedMonitor
        let workspaceIndex = workspaceIndex ?? monitor.active
        guard monitor.workspaces.indices.contains(workspaceIndex) else { return nil }
        let tracked = monitor.workspaces[workspaceIndex]
        let focusedIndex = tracked.isEmpty
            ? 0
            : min(monitor.focusedIndices[workspaceIndex], tracked.count - 1)
        let windows = tracked.enumerated().map { windowIndex, window in
            let labels = window.displayLabels()
            return GlanceWindow(
                appName: labels.appName,
                windowTitle: labels.windowTitle,
                icon: window.appIcon(),
                focused: windowIndex == focusedIndex
            )
        }

        let monitorLabel = ws.monitors.count > 1 ? "Monitor \(ws.focusedMonitorIndex + 1)" : nil
        return GlanceState(
            screen: monitor.screen,
            monitorLabel: monitorLabel,
            workspaceIndex: workspaceIndex,
            workspaceNumber: workspaceIndex + 1,
            windows: windows,
            focusedWindowIndex: focusedIndex
        )
    }

}

private struct GlanceWindow {
    let appName: String
    let windowTitle: String
    let icon: NSImage
    let focused: Bool
}

private final class GlanceRootView: NSView {
    private let onDismiss: () -> Void
    private weak var cardView: GlanceCardView?

    init(
        state: GlanceState,
        selectedWindow: Int,
        onSelectWindow: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        let backdrop = GlanceBackdropView(onDismiss: onDismiss)
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let effect = GlanceDimmingView()
        effect.translatesAutoresizingMaskIntoConstraints = false

        let card = GlanceCardView(
            state: state,
            selectedWindow: selectedWindow,
            onSelectWindow: onSelectWindow
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        cardView = card

        addSubview(backdrop)
        addSubview(effect)
        addSubview(card)

        let visible = state.screen.visibleFrame
        let cardWidth = visible.width * GlanceMetrics.screenFraction
        let cardHeight = visible.height * GlanceMetrics.screenFraction

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: cardWidth),
            card.heightAnchor.constraint(equalToConstant: cardHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if cardView?.frame.contains(point) != true {
            onDismiss()
        }
    }
}

private final class GlanceDimmingView: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class GlanceBackdropView: NSView {
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onDismiss()
    }
}

private final class GlanceCardView: NSVisualEffectView {
    init(
        state: GlanceState,
        selectedWindow: Int,
        onSelectWindow: @escaping (Int) -> Void
    ) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        self.state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "h/l column · j/k row · return/m focus · 1–9 jump · esc close")
        hint.font = .systemFont(ofSize: GlanceMetrics.hintFontSize, weight: .medium)
        hint.textColor = .tertiaryLabelColor

        let grid = GlanceWindowGridView(
            windows: state.windows,
            selectedWindow: selectedWindow,
            onSelectWindow: onSelectWindow
        )

        let padding: CGFloat = 16
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Workspace \(state.workspaceNumber)")
        title.font = .systemFont(ofSize: GlanceMetrics.headerFontSize, weight: .bold)
        title.textColor = .labelColor
        header.addArrangedSubview(title)

        if let monitorLabel = state.monitorLabel {
            let label = NSTextField(labelWithString: monitorLabel)
            label.font = .systemFont(ofSize: GlanceMetrics.hintFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            header.addArrangedSubview(label)
        }
        header.addArrangedSubview(hint)

        addSubview(header)
        addSubview(grid)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class GlanceWindowGridView: NSView {
    private let columns = GlanceMetrics.gridColumns
    private let spacing: CGFloat = 10
    private var tiles: [GlanceWindowCell] = []

    init(
        windows: [GlanceWindow],
        selectedWindow: Int,
        onSelectWindow: @escaping (Int) -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if windows.isEmpty {
            let empty = GlanceEmptyView()
            addSubview(empty)
            tiles = []
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: topAnchor),
                empty.leadingAnchor.constraint(equalTo: leadingAnchor),
                empty.trailingAnchor.constraint(equalTo: trailingAnchor),
                empty.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            return
        }

        for (index, window) in windows.enumerated() {
            let cell = GlanceWindowCell(
                window: window,
                selected: index == selectedWindow,
                onSelect: { onSelectWindow(index) }
            )
            tiles.append(cell)
            addSubview(cell)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }

        let count = tiles.count
        let rowCount = (count + columns - 1) / columns
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0, rowCount > 0 else { return }

        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (height - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)

        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let column = index % columns
            tile.frame = CGRect(
                x: CGFloat(column) * (cellWidth + spacing),
                y: CGFloat(row) * (cellHeight + spacing),
                width: cellWidth,
                height: cellHeight
            )
            tile.updateTypography(forCellHeight: cellHeight)
        }
    }
}

private final class GlanceEmptyView: NSView {
    init() {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "No windows on this workspace")
        label.font = .systemFont(ofSize: GlanceMetrics.bodyFontSize, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class GlanceWindowCell: NSView {
    private let onSelect: () -> Void
    private let selected: Bool
    private let appLabel: GlanceLabel
    private let titleLabel: GlanceLabel
    private let iconView: GlanceIconView
    private let iconWidthConstraint: NSLayoutConstraint
    private let iconHeightConstraint: NSLayoutConstraint
    private let caption: NSStackView
    private let content: NSStackView
    private var lastCellHeight: CGFloat = 0

    init(window: GlanceWindow, selected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.selected = selected
        appLabel = GlanceLabel(
            text: window.appName,
            font: .systemFont(ofSize: GlanceMetrics.bodyFontSize, weight: .semibold),
            color: selected ? .controlAccentColor : .labelColor,
            maximumNumberOfLines: 1,
            alignment: .center
        )
        titleLabel = GlanceLabel(
            text: window.windowTitle,
            font: .systemFont(ofSize: GlanceMetrics.hintFontSize, weight: selected ? .medium : .regular),
            color: selected ? .controlAccentColor : .secondaryLabelColor,
            maximumNumberOfLines: 2,
            alignment: .center,
            wraps: true
        )
        iconView = GlanceIconView()
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 44)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 44)
        caption = NSStackView(views: [appLabel, titleLabel])
        content = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        applyStyle(selected: selected, focused: window.focused)

        iconView.image = window.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([iconWidthConstraint, iconHeightConstraint])

        caption.orientation = .vertical
        caption.alignment = .centerX
        caption.translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .centerX
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(iconView)
        content.addArrangedSubview(caption)

        addSubview(content)
        let horizontalInset: CGFloat = 10
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.widthAnchor.constraint(equalTo: widthAnchor, constant: -horizontalInset * 2),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalInset),
            caption.widthAnchor.constraint(equalTo: content.widthAnchor),
            appLabel.widthAnchor.constraint(equalTo: caption.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: caption.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateTypography(forCellHeight cellHeight: CGFloat) {
        guard abs(cellHeight - lastCellHeight) > 0.5 else { return }
        lastCellHeight = cellHeight

        let type = GlanceMetrics.typography(forCellHeight: cellHeight)
        iconWidthConstraint.constant = type.iconSize
        iconHeightConstraint.constant = type.iconSize
        content.spacing = type.contentSpacing
        caption.spacing = type.captionSpacing

        appLabel.font = .systemFont(ofSize: type.appFontSize, weight: .semibold)
        titleLabel.font = .systemFont(
            ofSize: type.titleFontSize,
            weight: selected ? .medium : .regular
        )
        titleLabel.maximumNumberOfLines = type.titleLineCount
        titleLabel.invalidateIntrinsicContentSize()
    }

    private func applyStyle(selected: Bool, focused: Bool) {
        if selected {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else if focused {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class GlanceIconView: NSImageView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class GlanceLabel: NSTextField {
    init(
        text: String,
        font: NSFont,
        color: NSColor,
        maximumNumberOfLines: Int = 1,
        alignment: NSTextAlignment = .natural,
        wraps: Bool = false
    ) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        self.alignment = alignment
        self.maximumNumberOfLines = maximumNumberOfLines
        if wraps {
            usesSingleLineMode = false
            lineBreakMode = .byWordWrapping
            cell?.wraps = true
            cell?.isScrollable = false
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        } else {
            lineBreakMode = .byTruncatingTail
            setContentHuggingPriority(.required, for: .vertical)
        }
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
