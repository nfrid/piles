import AppKit

enum OverlayMetrics {
    static let screenFraction: CGFloat = 0.8
    static let gridColumns = 3
    static let hintFontSize: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cellCornerRadius: CGFloat = 8
    static let gridSpacing: CGFloat = 10
}

enum OverlayGridNavigation {
    static func moveHorizontal(selected: Int, delta: Int, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }

        let row = selected / columns
        let rowStart = row * columns
        let slots = min(columns, count - rowStart)
        guard slots > 0 else { return nil }

        let column = selected - rowStart
        return rowStart + (column + delta + slots) % slots
    }

    static func moveRow(selected: Int, delta: Int, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        let step = delta * columns
        return (selected + step + count) % count
    }
}

enum OverlayKeyInput {
    case passThrough
    case dismiss
    case navigateHorizontal(Int)
    case navigateVertical(Int)
    case confirm
    case numberJump(Int)
    case unrecognized

    static func resolve(
        keyCode: UInt16,
        flags: CGEventFlags,
        config: Config,
        toggleBinding: (key: UInt16, shift: Bool)
    ) -> OverlayKeyInput {
        if keyCode == Key.escape {
            return .dismiss
        }

        if flags.contains(.maskCommand) {
            return .passThrough
        }

        if let number = config.numberKeys[keyCode] {
            return .numberJump(number - 1)
        }

        let hasShift = flags.contains(.maskShift)
        if config.matchesConfiguredModifier(flags),
           keyCode == toggleBinding.key,
           hasShift == toggleBinding.shift {
            return .dismiss
        }

        switch keyCode {
        case Key.h:
            return .navigateHorizontal(-1)
        case Key.l:
            return .navigateHorizontal(1)
        case Key.j:
            return .navigateVertical(1)
        case Key.k:
            return .navigateVertical(-1)
        case Key.return, Key.m:
            return .confirm
        default:
            return .unrecognized
        }
    }
}

enum SelectionCellStyle {
    static func apply(to layer: CALayer?, selected: Bool, focused: Bool) {
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
}

final class OverlayPanelController {
    private let animationDuration: TimeInterval = 0.14
    private var panel: NSPanel?

    func present(contentView: NSView, on screen: NSScreen, animated: Bool) {
        let panel = panel(for: screen)
        panel.contentView = contentView
        panel.setFrame(screen.frame, display: true)

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

    func dismiss(ifStillHidden: @escaping () -> Bool) {
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
            if ifStillHidden() {
                self.panel = nil
            }
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
}

final class OverlayRootView: NSView {
    private let onDismiss: () -> Void
    private weak var cardView: NSView?

    init(screen: NSScreen, card: NSView, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        let backdrop = OverlayBackdropView(onDismiss: onDismiss)
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let effect = OverlayDimmingView()
        effect.translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        cardView = card

        addSubview(backdrop)
        addSubview(effect)
        addSubview(card)

        let visible = screen.visibleFrame
        let cardWidth = visible.width * OverlayMetrics.screenFraction
        let cardHeight = visible.height * OverlayMetrics.screenFraction

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

final class OverlayDimmingView: NSVisualEffectView {
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

final class OverlayBackdropView: NSView {
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

final class OverlayGridView: NSView {
    private let columns: Int
    private let spacing: CGFloat
    private var cells: [NSView]
    var onCellLayout: ((_ index: Int, _ cellHeight: CGFloat) -> Void)?

    init(
        columns: Int = OverlayMetrics.gridColumns,
        spacing: CGFloat = OverlayMetrics.gridSpacing,
        cells: [NSView]
    ) {
        self.columns = columns
        self.spacing = spacing
        self.cells = cells
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        for cell in cells {
            addSubview(cell)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }

        let frames = Self.layoutFrames(
            count: cells.count,
            columns: columns,
            spacing: spacing,
            width: bounds.width,
            height: bounds.height
        )
        guard !frames.isEmpty else { return }

        let cellHeight = frames[0].height
        for (index, cell) in cells.enumerated() {
            cell.frame = frames[index]
            onCellLayout?(index, cellHeight)
        }
    }

    static func layoutFrames(
        count: Int,
        columns: Int,
        spacing: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> [CGRect] {
        guard count > 0, width > 0, height > 0 else { return [] }

        let rowCount = (count + columns - 1) / columns
        guard rowCount > 0 else { return [] }

        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (height - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            return CGRect(
                x: CGFloat(column) * (cellWidth + spacing),
                y: CGFloat(row) * (cellHeight + spacing),
                width: cellWidth,
                height: cellHeight
            )
        }
    }
}

final class OverlayClickStrip: NSView {
    private let action: () -> Void

    init(action: @escaping () -> Void, content: () -> NSView) {
        self.action = action
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        let body = content()
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        action()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class OverlayIconView: NSImageView {
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

final class OverlayLabel: NSTextField {
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
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false

        if wraps {
            usesSingleLineMode = false
            lineBreakMode = .byWordWrapping
            cell?.wraps = true
            cell?.isScrollable = false
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        } else {
            lineBreakMode = .byTruncatingTail
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            cell?.wraps = false
            cell?.usesSingleLineMode = true
            cell?.lineBreakMode = .byTruncatingTail
            cell?.truncatesLastVisibleLine = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class OverlayFlippedDocumentView: NSView {
    init() {
        super.init(frame: .zero)
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
