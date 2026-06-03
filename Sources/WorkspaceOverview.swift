import AppKit

private enum OverviewMetrics {
    static let screenFraction: CGFloat = 0.8
    static let gridColumns = 3
    static let headerFontSize: CGFloat = 17
    static let bodyFontSize: CGFloat = 13
    static let hintFontSize: CGFloat = 12
    static let cellPadding: CGFloat = 8
    static let windowRowHeight: CGFloat = 22
    static let windowRowSpacing: CGFloat = 4
}

package final class WorkspaceOverview {
    package static let shared = WorkspaceOverview()
    private let animationDuration: TimeInterval = 0.14
    private var panel: NSPanel?
    package private(set) var isVisible = false
    private var selectedWorkspace = 0
    private var selectedWindow = 0

    private init() {}

    package func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    package func show() {
        guard let state = OverviewState.capture() else { return }
        WorkspaceGlance.shared.hide()
        resetSelection(from: state)
        isVisible = true
        present(state: state)
    }

    package func hide() {
        guard isVisible else { return }
        isVisible = false
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
        guard let state = OverviewState.capture() else {
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
                self.activate(workspaceIndex: index, windowIndex: nil)
                self.hide()
            }
            return true
        }

        let binding = config.bindings.workspaceOverview
        let hasModifier = flags.contains(config.modifier)
        let hasExtraModifiers =
            (config.modifier != .maskCommand && flags.contains(.maskCommand)) ||
            (config.modifier != .maskControl && flags.contains(.maskControl)) ||
            (config.modifier != .maskAlternate && flags.contains(.maskAlternate))
        let hasShift = flags.contains(.maskShift)
        if hasModifier,
           !hasExtraModifiers,
           keyCode == binding.key,
           hasShift == binding.shift {
            DispatchQueue.main.async { self.hide() }
            return true
        }

        switch keyCode {
        case Key.h:
            DispatchQueue.main.async { self.moveWorkspaceHorizontal(-1) }
            return true
        case Key.l:
            DispatchQueue.main.async { self.moveWorkspaceHorizontal(1) }
            return true
        case Key.j:
            DispatchQueue.main.async { self.moveWorkspaceRow(1) }
            return true
        case Key.k:
            DispatchQueue.main.async { self.moveWorkspaceRow(-1) }
            return true
        case Key.return, Key.m:
            DispatchQueue.main.async { self.confirmSelection() }
            return true
        default:
            return true
        }
    }

    private func resetSelection(from state: OverviewState) {
        selectedWorkspace = state.activeWorkspace
        syncWindowSelection(from: state)
    }

    private func clampSelection(to state: OverviewState) {
        selectedWorkspace = min(max(selectedWorkspace, 0), state.workspaces.count - 1)
        syncWindowSelection(from: state)
    }

    private func syncWindowSelection(from state: OverviewState) {
        guard state.workspaces.indices.contains(selectedWorkspace) else {
            selectedWindow = 0
            return
        }
        selectedWindow = state.workspaces[selectedWorkspace].focusedWindowIndex
    }

    private func moveWorkspaceHorizontal(_ delta: Int) {
        guard let state = OverviewState.capture() else { return }
        let count = state.workspaces.count
        let columns = OverviewMetrics.gridColumns
        guard count > 0 else { return }

        let row = selectedWorkspace / columns
        let rowStart = row * columns
        let slots = min(columns, count - rowStart)
        guard slots > 0 else { return }

        let column = selectedWorkspace - rowStart
        selectedWorkspace = rowStart + (column + delta + slots) % slots
        syncWindowSelection(from: state)
        present(state: state, animated: false)
    }

    private func moveWorkspaceRow(_ delta: Int) {
        guard let state = OverviewState.capture() else { return }
        let count = state.workspaces.count
        guard count > 0 else { return }
        let step = delta * OverviewMetrics.gridColumns
        selectedWorkspace = (selectedWorkspace + step + count) % count
        syncWindowSelection(from: state)
        present(state: state, animated: false)
    }

    private func confirmSelection() {
        WorkspaceManager.shared.switchTo(selectedWorkspace)
        hide()
    }

    private func activate(workspaceIndex: Int, windowIndex: Int?) {
        guard let state = OverviewState.capture(),
              state.workspaces.indices.contains(workspaceIndex)
        else { return }

        let windows = state.workspaces[workspaceIndex].windows
        if let windowIndex, windows.indices.contains(windowIndex) {
            WorkspaceManager.shared.focusWindow(workspaceIndex: workspaceIndex, windowIndex: windowIndex)
        } else {
            WorkspaceManager.shared.switchTo(workspaceIndex)
        }
    }

    private func present(state: OverviewState, animated: Bool = true) {
        let panel = panel(for: state.screen)
        let selection = OverviewSelection(workspace: selectedWorkspace, window: selectedWindow)
        panel.contentView = OverviewRootView(
            state: state,
            selection: selection,
            onSelectWorkspace: { [weak self] index in
                self?.activate(workspaceIndex: index, windowIndex: nil)
                self?.hide()
            },
            onSelectWindow: { [weak self] workspaceIndex, windowIndex in
                self?.activate(workspaceIndex: workspaceIndex, windowIndex: windowIndex)
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
}

private struct OverviewSelection {
    let workspace: Int
    let window: Int
}

private struct OverviewState {
    let screen: NSScreen
    let monitorLabel: String?
    let workspaceCount: Int
    let activeWorkspace: Int
    let workspaces: [OverviewWorkspace]

    static func capture() -> OverviewState? {
        let ws = WorkspaceManager.shared
        guard !ws.monitors.isEmpty else { return nil }

        let monitor = ws.focusedMonitor
        let count = Config.shared.workspaceCount
        var workspaces: [OverviewWorkspace] = []
        workspaces.reserveCapacity(count)

        for index in 0..<count {
            let windows = monitor.workspaces[index]
            let focusedIndex = windows.isEmpty
                ? 0
                : min(monitor.focusedIndices[index], windows.count - 1)
            let items = windows.enumerated().map { windowIndex, window in
                OverviewWindow(
                    title: windowLabel(for: window),
                    focused: windowIndex == focusedIndex
                )
            }
            workspaces.append(OverviewWorkspace(
                index: index,
                number: index + 1,
                active: index == monitor.active,
                occupied: !windows.isEmpty,
                focusedWindowIndex: focusedIndex,
                windows: items
            ))
        }

        let monitorLabel = ws.monitors.count > 1 ? "Monitor \(ws.focusedMonitorIndex + 1)" : nil
        return OverviewState(
            screen: monitor.screen,
            monitorLabel: monitorLabel,
            workspaceCount: count,
            activeWorkspace: monitor.active,
            workspaces: workspaces
        )
    }

    private static func windowLabel(for window: TrackedWindow) -> String {
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

private struct OverviewWorkspace {
    let index: Int
    let number: Int
    let active: Bool
    let occupied: Bool
    let focusedWindowIndex: Int
    let windows: [OverviewWindow]
}

private struct OverviewWindow {
    let title: String
    let focused: Bool
}

private final class OverviewRootView: NSView {
    private let onDismiss: () -> Void
    private weak var cardView: OverviewCardView?

    init(
        state: OverviewState,
        selection: OverviewSelection,
        onSelectWorkspace: @escaping (Int) -> Void,
        onSelectWindow: @escaping (Int, Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)

        let backdrop = OverviewBackdropView(onDismiss: onDismiss)
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let effect = OverviewDimmingView()
        effect.translatesAutoresizingMaskIntoConstraints = false

        let card = OverviewCardView(
            overviewState: state,
            selection: selection,
            onSelectWorkspace: onSelectWorkspace,
            onSelectWindow: onSelectWindow
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        cardView = card

        addSubview(backdrop)
        addSubview(effect)
        addSubview(card)

        let visible = state.screen.visibleFrame
        let cardWidth = visible.width * OverviewMetrics.screenFraction
        let cardHeight = visible.height * OverviewMetrics.screenFraction

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

private final class OverviewDimmingView: NSVisualEffectView {
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

private final class OverviewBackdropView: NSView {
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

private final class OverviewCardView: NSVisualEffectView {
    init(
        overviewState: OverviewState,
        selection: OverviewSelection,
        onSelectWorkspace: @escaping (Int) -> Void,
        onSelectWindow: @escaping (Int, Int) -> Void
    ) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        self.state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "h/l column · j/k row · return/m open · 1–9 jump · esc close")
        hint.font = .systemFont(ofSize: OverviewMetrics.hintFontSize, weight: .medium)
        hint.textColor = .tertiaryLabelColor

        let grid = OverviewTileGridView(
            workspaces: overviewState.workspaces,
            selection: selection,
            onSelectWorkspace: onSelectWorkspace,
            onSelectWindow: onSelectWindow
        )

        let padding: CGFloat = 16
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        if let monitorLabel = overviewState.monitorLabel {
            let label = NSTextField(labelWithString: monitorLabel)
            label.font = .systemFont(ofSize: OverviewMetrics.hintFontSize, weight: .semibold)
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

/// Fixed-size tile grid: every workspace cell gets the same width and height.
private final class OverviewTileGridView: NSView {
    private let columns = OverviewMetrics.gridColumns
    private let spacing: CGFloat = 10
    private var tiles: [OverviewWorkspaceCell] = []

    init(
        workspaces: [OverviewWorkspace],
        selection: OverviewSelection,
        onSelectWorkspace: @escaping (Int) -> Void,
        onSelectWindow: @escaping (Int, Int) -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        for workspace in workspaces {
            let cell = OverviewWorkspaceCell(
                workspace: workspace,
                selected: workspace.index == selection.workspace,
                selectedWindow: selection.window,
                onSelectWorkspace: { onSelectWorkspace(workspace.index) },
                onSelectWindow: { onSelectWindow(workspace.index, $0) }
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
        }
    }
}

private final class OverviewWorkspaceCell: NSView {
    private let onSelectWorkspace: () -> Void
    private let workspaceSelected: Bool
    private let selectedWindow: Int
    private let windowScrollView: NSScrollView
    private let windowList: NSStackView

    init(
        workspace: OverviewWorkspace,
        selected: Bool,
        selectedWindow: Int,
        onSelectWorkspace: @escaping () -> Void,
        onSelectWindow: @escaping (Int) -> Void
    ) {
        self.onSelectWorkspace = onSelectWorkspace
        self.workspaceSelected = selected
        self.selectedWindow = selectedWindow

        windowList = NSStackView()
        windowList.orientation = .vertical
        windowList.alignment = .leading
        windowList.distribution = .fill
        windowList.spacing = OverviewMetrics.windowRowSpacing
        windowList.translatesAutoresizingMaskIntoConstraints = false

        windowScrollView = NSScrollView()
        windowScrollView.hasVerticalScroller = true
        windowScrollView.hasHorizontalScroller = false
        windowScrollView.autohidesScrollers = true
        windowScrollView.borderType = .noBorder
        windowScrollView.drawsBackground = false
        windowScrollView.translatesAutoresizingMaskIntoConstraints = false
        windowScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        windowScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        windowScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        applyStyle(selected: selected, workspaceActive: workspace.active)

        let document = OverviewFlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(windowList)
        windowScrollView.documentView = document

        NSLayoutConstraint.activate([
            windowList.topAnchor.constraint(equalTo: document.topAnchor),
            windowList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            windowList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            windowList.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            windowList.widthAnchor.constraint(equalTo: document.widthAnchor),

            document.leadingAnchor.constraint(equalTo: windowScrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: windowScrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: windowScrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: windowScrollView.contentView.widthAnchor),
            document.bottomAnchor.constraint(equalTo: windowList.bottomAnchor),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: windowScrollView.contentView.bottomAnchor
            ),
        ])

        if workspace.windows.isEmpty {
            windowList.addArrangedSubview(OverviewTileClickStrip(action: onSelectWorkspace) {
                OverviewLabel(
                    text: "empty",
                    font: .systemFont(ofSize: OverviewMetrics.bodyFontSize, weight: .medium),
                    color: .tertiaryLabelColor
                )
            })
        } else {
            for (index, window) in workspace.windows.enumerated() {
                let rowSelected = selected && index == selectedWindow
                windowList.addArrangedSubview(OverviewWindowRow(
                    title: window.title,
                    selected: rowSelected || window.focused,
                    action: { onSelectWindow(index) }
                ))
            }
        }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = OverviewMetrics.windowRowSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(
            top: OverviewMetrics.cellPadding,
            left: OverviewMetrics.cellPadding,
            bottom: OverviewMetrics.cellPadding,
            right: OverviewMetrics.cellPadding
        )

        content.addArrangedSubview(OverviewTileClickStrip(action: onSelectWorkspace) {
            OverviewLabel(
                text: "\(workspace.number)",
                font: .systemFont(ofSize: OverviewMetrics.headerFontSize, weight: .bold),
                color: selected ? .controlAccentColor : .labelColor
            )
        })
        content.addArrangedSubview(windowScrollView)

        addSubview(content)
        let inset = OverviewMetrics.cellPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            windowScrollView.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(inset * 2)
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isWindowRow(hitTest(point)) {
            onSelectWorkspace()
            return
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        syncScrollViewContentWidth()
        guard workspaceSelected else { return }
        scrollToSelectedWindow()
    }

    private func syncScrollViewContentWidth() {
        let width = windowScrollView.bounds.width
        guard width > 0, let document = windowScrollView.documentView else { return }
        guard abs(document.frame.width - width) > 0.5 else { return }
        var frame = document.frame
        frame.size.width = width
        document.setFrameSize(frame.size)
    }

    private func isWindowRow(_ view: NSView?) -> Bool {
        var node = view
        while let current = node {
            if current is OverviewWindowRow {
                return true
            }
            node = current.superview
        }
        return false
    }

    private func scrollToSelectedWindow() {
        guard selectedWindow >= 0,
              selectedWindow < windowList.arrangedSubviews.count,
              let documentView = windowScrollView.documentView
        else { return }

        let row = windowList.arrangedSubviews[selectedWindow]
        var target = row.convert(row.bounds, to: documentView)
        target = target.insetBy(dx: 0, dy: -OverviewMetrics.windowRowSpacing)
        windowScrollView.contentView.scrollToVisible(target)
    }

    private func applyStyle(selected: Bool, workspaceActive: Bool) {
        if selected {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else if workspaceActive {
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

private final class OverviewTileClickStrip: NSView {
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

private final class OverviewWindowRow: NSView {
    private let action: () -> Void

    init(title: String, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        clipsToBounds = true
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let label = OverviewLabel(
            text: title,
            font: .systemFont(ofSize: OverviewMetrics.bodyFontSize, weight: selected ? .semibold : .regular),
            color: selected ? .controlAccentColor : .secondaryLabelColor
        )
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: OverviewMetrics.windowRowHeight),
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

private final class OverviewFlippedDocumentView: NSView {
    init() {
        super.init(frame: .zero)
    }

    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class OverviewLabel: NSTextField {
    init(text: String, font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
