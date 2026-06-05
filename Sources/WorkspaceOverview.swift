import AppKit

private enum OverviewMetrics {
    static let headerFontSize: CGFloat = 17
    static let bodyFontSize: CGFloat = 15
    static let cellPadding: CGFloat = 8
    static let windowRowHeight: CGFloat = 28
    static let windowIconSize: CGFloat = 18
    static let windowIconGap: CGFloat = 8
    static let windowRowSpacing: CGFloat = 6
}

package final class WorkspaceOverview: OverlaySessionHost {
    package static let shared = WorkspaceOverview()
    private lazy var session: OverlaySession = OverlaySession(host: self)
    package var isVisible: Bool { session.isVisible }
    private var selectedWorkspace = 0
    private var selectedWindow = 0
    private var lastRefreshFingerprint: OverviewRefreshFingerprint?
    private var liveCard: OverviewCardView?
    private var liveRootView: OverlayRootView?

    private init() {}

    package func toggle() {
        session.toggle()
    }

    package func show() {
        session.show()
    }

    package func hide() {
        session.hide()
    }

    package func refreshIfVisible() {
        session.refreshIfVisible()
    }

    package func handleKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
        session.handleKey(keyCode: keyCode, flags: flags, config: config)
    }

    func overlayPrepareToShow() {
        WorkspaceGlance.shared.hide()
    }

    func overlayPresent(animated: Bool, refreshing: Bool) -> Bool {
        guard let state = OverviewState.capture() else { return false }
        let fingerprint = OverviewRefreshFingerprint(state: state)
        if refreshing, fingerprint == lastRefreshFingerprint {
            return true
        }
        lastRefreshFingerprint = fingerprint
        if refreshing {
            clampSelection(to: state)
        } else {
            resetSelection(from: state)
        }
        present(state: state, animated: animated)
        return true
    }

    func overlayDidHide() {
        lastRefreshFingerprint = nil
        liveCard = nil
        liveRootView = nil
    }

    func overlayToggleBinding(_ config: Config) -> (key: UInt16, shift: Bool) {
        config.bindings.workspaceOverview
    }

    func overlayHandleExtraKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
        guard keyCode == Key.o,
              !flags.contains(.maskShift),
              !flags.contains(.maskCommand),
              !config.matchesConfiguredModifier(flags)
        else { return false }

        MainThread.run {
            WorkspaceGlance.shared.show(
                workspaceIndex: self.selectedWorkspace,
                windowIndex: self.selectedWindow
            )
        }
        return true
    }

    func overlayConfirm() {
        confirmSelection()
        hide()
    }

    func overlayNavigateHorizontal(delta: Int) {
        moveWorkspaceHorizontal(delta)
    }

    func overlayNavigateVertical(delta: Int) {
        moveWorkspaceRow(delta)
    }

    func overlayNumberJump(index: Int) {
        activate(workspaceIndex: index, windowIndex: nil)
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
        guard OverlayGridSelection.moveHorizontal(
            selected: &selectedWorkspace,
            delta: delta,
            count: state.workspaces.count
        ) else { return }

        syncWindowSelection(from: state)
        applySelectionIfPossible(state: state) ?? present(state: state, animated: false)
    }

    private func moveWorkspaceRow(_ delta: Int) {
        guard let state = OverviewState.capture() else { return }
        guard OverlayGridSelection.moveRow(
            selected: &selectedWorkspace,
            delta: delta,
            count: state.workspaces.count
        ) else { return }

        syncWindowSelection(from: state)
        applySelectionIfPossible(state: state) ?? present(state: state, animated: false)
    }

    @discardableResult
    private func applySelectionIfPossible(state: OverviewState) -> Void? {
        guard let card = liveCard else { return nil }
        guard OverviewRefreshFingerprint(state: state) == lastRefreshFingerprint else { return nil }
        let selection = OverviewSelection(workspace: selectedWorkspace, window: selectedWindow)
        card.applySelection(selection, appearance: state.appearance)
        return ()
    }

    private func confirmSelection() {
        WorkspaceManager.shared.switchTo(selectedWorkspace)
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
        let selection = OverviewSelection(workspace: selectedWorkspace, window: selectedWindow)
        let card = OverviewCardView(
            overviewState: state,
            selection: selection,
            onSelectWorkspace: { [weak self] index in
                self?.activate(workspaceIndex: index, windowIndex: nil)
                self?.hide()
            },
            onSelectWindow: { [weak self] workspaceIndex, windowIndex in
                self?.activate(workspaceIndex: workspaceIndex, windowIndex: windowIndex)
                self?.hide()
            }
        )
        let rootView = OverlayRootView(
            screen: state.screen,
            card: card,
            onDismiss: { [weak self] in self?.hide() }
        )
        liveCard = card
        liveRootView = rootView
        session.present(contentView: rootView, on: state.screen, animated: animated)
    }
}

private struct OverviewSelection {
    let workspace: Int
    let window: Int
}

private struct OverviewRefreshFingerprint: Equatable {
    let activeWorkspace: Int
    let workspaceCount: Int
    let workspaces: [[Int]]
    let focusedIndices: [Int]
    let monitorLabel: String?
    let visibleFrame: CGRect
    let appearance: AppearanceSnapshot

    init(state: OverviewState) {
        activeWorkspace = state.activeWorkspace
        workspaceCount = state.workspaceCount
        workspaces = state.workspaces.map { $0.windows.map(\.identityToken) }
        focusedIndices = state.workspaces.map(\.focusedWindowIndex)
        monitorLabel = state.monitorLabel
        visibleFrame = state.screen.visibleFrame
        appearance = state.appearance
    }
}

private struct OverviewState {
    let screen: NSScreen
    let monitorLabel: String?
    let workspaceCount: Int
    let activeWorkspace: Int
    let appearance: AppearanceSnapshot
    let workspaces: [OverviewWorkspace]

    static func capture() -> OverviewState? {
        let ws = WorkspaceManager.shared
        guard !ws.monitors.isEmpty else { return nil }

        let monitor = ws.focusedMonitor
        let appearance = Config.shared.appearanceSnapshot
        let count = Config.shared.workspaceCount
        var workspaces: [OverviewWorkspace] = []
        workspaces.reserveCapacity(count)

        for index in 0..<count {
            let windows = monitor.workspaces[index]
            let focusedIndex = monitor.clampedFocus(in: index)
            let items = windows.enumerated().map { windowIndex, window in
                OverviewWindow(
                    identityToken: window.overlayIdentityToken,
                    title: window.displayTitle(),
                    icon: window.appIcon(),
                    focused: windowIndex == focusedIndex
                )
            }
            workspaces.append(OverviewWorkspace(
                index: index,
                style: appearance.uiStyle(forWorkspace: index),
                active: index == monitor.active,
                occupied: !windows.isEmpty,
                focusedWindowIndex: focusedIndex,
                windows: items
            ))
        }

        let monitorLabel = ws.focusedMonitorLabel
        return OverviewState(
            screen: monitor.screen,
            monitorLabel: monitorLabel,
            workspaceCount: count,
            activeWorkspace: monitor.active,
            appearance: appearance,
            workspaces: workspaces
        )
    }
}

private struct OverviewWorkspace {
    let index: Int
    let style: WorkspaceUIStyle
    let active: Bool
    let occupied: Bool
    let focusedWindowIndex: Int
    let windows: [OverviewWindow]
}

private struct OverviewWindow {
    let identityToken: Int
    let title: String
    let icon: NSImage
    let focused: Bool
}

private final class OverviewCardView: NSVisualEffectView {
    private var workspaceCells: [(index: Int, cell: OverviewWorkspaceCell)] = []

    func applySelection(_ selection: OverviewSelection, appearance: AppearanceSnapshot) {
        for (wsIndex, cell) in workspaceCells {
            cell.applySelection(
                workspaceSelected: wsIndex == selection.workspace,
                selectedWindow: selection.window,
                accent: appearance.uiStyle(forWorkspace: wsIndex).accent
            )
        }
    }

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
        layer?.cornerRadius = OverlayMetrics.cardCornerRadius
        layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "h/l column · j/k row · return/m open · o glance · 1–9 jump · esc close")
        hint.font = .systemFont(ofSize: OverlayMetrics.hintFontSize, weight: .medium)
        hint.textColor = .tertiaryLabelColor

        let cells = overviewState.workspaces.map { workspace in
            OverviewWorkspaceCell(
                workspace: workspace,
                selected: workspace.index == selection.workspace,
                selectedWindow: selection.window,
                onSelectWorkspace: { onSelectWorkspace(workspace.index) },
                onSelectWindow: { onSelectWindow(workspace.index, $0) }
            )
        }
        workspaceCells = zip(overviewState.workspaces.map(\.index), cells).map { ($0, $1) }
        let grid = OverlayGridView(cells: cells)

        let padding = OverlayMetrics.cardPadding
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        if let monitorLabel = overviewState.monitorLabel {
            let label = NSTextField(labelWithString: monitorLabel)
            label.font = .systemFont(ofSize: OverlayMetrics.hintFontSize, weight: .semibold)
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

private final class OverviewWorkspaceCell: NSView {
    private let onSelectWorkspace: () -> Void
    private var workspaceSelected: Bool
    private var selectedWindow: Int
    private let windowScrollView: NSScrollView
    private let windowList: NSStackView
    private let workspace: OverviewWorkspace

    func applySelection(workspaceSelected: Bool, selectedWindow: Int, accent: NSColor) {
        let changed = self.workspaceSelected != workspaceSelected || self.selectedWindow != selectedWindow
        self.workspaceSelected = workspaceSelected
        self.selectedWindow = selectedWindow
        guard changed else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            SelectionCellStyle.apply(to: layer, selected: workspaceSelected, focused: workspace.active, accent: accent)
        }

        for (i, row) in windowList.arrangedSubviews.compactMap({ $0 as? OverviewWindowRow }).enumerated() {
            let rowSelected = workspaceSelected && i == selectedWindow
            row.applySelected(rowSelected || workspace.windows.indices.contains(i) && workspace.windows[i].focused, accentColor: accent)
        }

        if workspaceSelected {
            setNeedsDisplay(bounds)
            layoutSubtreeIfNeeded()
            scrollToSelectedWindow()
        }
    }

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
        self.workspace = workspace

        windowList = NSStackView()
        windowList.orientation = .vertical
        windowList.alignment = .leading
        windowList.distribution = .gravityAreas
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
        layer?.cornerRadius = OverlayMetrics.cellCornerRadius
        layer?.masksToBounds = true
        SelectionCellStyle.apply(
            to: layer,
            selected: selected,
            focused: workspace.active,
            accent: workspace.style.accent
        )

        let document = OverlayFlippedDocumentView()
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
            windowList.addArrangedSubview(OverlayClickStrip(action: onSelectWorkspace) {
                OverlayLabel(
                    text: "empty",
                    font: .systemFont(ofSize: OverviewMetrics.bodyFontSize, weight: .medium),
                    color: .tertiaryLabelColor
                )
            })
        } else {
            for (index, window) in workspace.windows.enumerated() {
                let rowSelected = selected && index == selectedWindow
                let row = OverviewWindowRow(
                    title: window.title,
                    icon: window.icon,
                    selected: rowSelected || window.focused,
                    accentColor: workspace.style.accent,
                    action: { onSelectWindow(index) }
                )
                windowList.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: windowList.widthAnchor).isActive = true
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

        content.addArrangedSubview(OverlayClickStrip(action: onSelectWorkspace) {
            OverlayLabel(
                text: workspace.style.displayName,
                font: .systemFont(ofSize: OverviewMetrics.headerFontSize, weight: .bold),
                color: workspace.style.accent
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
}

private final class OverviewWindowRow: NSView {
    private let action: () -> Void
    private let label: OverlayLabel
    private var selected: Bool
    private var accentColor: NSColor

    func applySelected(_ newSelected: Bool, accentColor: NSColor) {
        guard selected != newSelected || self.accentColor != accentColor else { return }
        selected = newSelected
        self.accentColor = accentColor
        label.textColor = newSelected ? accentColor : .secondaryLabelColor
        label.font = .systemFont(
            ofSize: OverviewMetrics.bodyFontSize,
            weight: newSelected ? .semibold : .regular
        )
    }

    init(
        title: String,
        icon: NSImage,
        selected: Bool,
        accentColor: NSColor,
        action: @escaping () -> Void
    ) {
        self.action = action
        self.selected = selected
        self.accentColor = accentColor
        self.label = OverlayLabel(
            text: title,
            font: .systemFont(ofSize: OverviewMetrics.bodyFontSize, weight: selected ? .semibold : .regular),
            color: selected ? accentColor : .secondaryLabelColor
        )
        super.init(frame: .zero)
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let iconView = OverlayIconView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let content = NSStackView(views: [iconView, label])
        content.orientation = .horizontal
        content.spacing = OverviewMetrics.windowIconGap
        content.alignment = .centerY
        content.distribution = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let iconSize = OverviewMetrics.windowIconSize
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: OverviewMetrics.windowRowHeight),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
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
