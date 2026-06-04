import AppKit

private enum GlanceMetrics {
    static let headerFontSize: CGFloat = 17
    static let bodyFontSize: CGFloat = 13

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

package final class WorkspaceGlance: OverlaySessionHost {
    package static let shared = WorkspaceGlance()
    private lazy var session: OverlaySession = OverlaySession(host: self)
    package var isVisible: Bool { session.isVisible }
    private var selectedWindow = 0
    private var viewedWorkspaceIndex: Int?
    private var pendingWindowIndex: Int?
    private var lastRefreshFingerprint: GlanceRefreshFingerprint?

    private init() {}

    package func toggle() {
        session.toggle()
    }

    package func show() {
        viewedWorkspaceIndex = nil
        pendingWindowIndex = nil
        session.show()
    }

    package func show(workspaceIndex: Int, windowIndex: Int? = nil) {
        viewedWorkspaceIndex = workspaceIndex
        pendingWindowIndex = windowIndex
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
        WorkspaceOverview.shared.hide()
    }

    func overlayPresent(animated: Bool, refreshing: Bool) -> Bool {
        guard let state = captureState() else { return false }
        let fingerprint = GlanceRefreshFingerprint(state: state)
        if refreshing, fingerprint == lastRefreshFingerprint {
            return true
        }
        lastRefreshFingerprint = fingerprint
        if refreshing {
            clampSelection(to: state)
        } else if let pendingWindowIndex {
            selectedWindow = pendingWindowIndex
            self.pendingWindowIndex = nil
            clampSelection(to: state)
        } else {
            resetSelection(from: state)
        }
        present(state: state, animated: animated)
        return true
    }

    func overlayDidHide() {
        viewedWorkspaceIndex = nil
        pendingWindowIndex = nil
        lastRefreshFingerprint = nil
    }

    func overlayToggleBinding(_ config: Config) -> (key: UInt16, shift: Bool) {
        config.bindings.workspaceGlance
    }

    func overlayHandleExtraKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
        false
    }

    func overlayConfirm() {
        confirmSelection()
        hide()
    }

    func overlayNavigateHorizontal(delta: Int) {
        moveWindowHorizontal(delta)
    }

    func overlayNavigateVertical(delta: Int) {
        moveWindowRow(delta)
    }

    func overlayNumberJump(index: Int) {
        activate(windowIndex: index)
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
        guard OverlayGridSelection.moveHorizontal(
            selected: &selectedWindow,
            delta: delta,
            count: state.windows.count
        ) else { return }

        present(state: state, animated: false)
    }

    private func moveWindowRow(_ delta: Int) {
        guard let state = captureState() else { return }
        guard OverlayGridSelection.moveRow(
            selected: &selectedWindow,
            delta: delta,
            count: state.windows.count
        ) else { return }

        present(state: state, animated: false)
    }

    private func confirmSelection() {
        activate(windowIndex: selectedWindow)
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
        let contentView = OverlayRootView(
            screen: state.screen,
            card: GlanceCardView(
                state: state,
                selectedWindow: selectedWindow,
                onSelectWindow: { [weak self] index in
                    self?.activate(windowIndex: index)
                    self?.hide()
                }
            ),
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        session.present(contentView: contentView, on: state.screen, animated: animated)
    }

    private func captureState() -> GlanceState? {
        GlanceState.capture(workspaceIndex: viewedWorkspaceIndex)
    }
}

private struct GlanceRefreshFingerprint: Equatable {
    let workspaceIndex: Int
    let windowTokens: [Int]
    let focusedWindowIndex: Int
    let monitorLabel: String?
    let visibleFrame: CGRect
    let appearance: AppearanceSnapshot

    init(state: GlanceState) {
        workspaceIndex = state.workspaceIndex
        windowTokens = state.windows.map(\.identityToken)
        focusedWindowIndex = state.focusedWindowIndex
        monitorLabel = state.monitorLabel
        visibleFrame = state.screen.visibleFrame
        appearance = state.appearance
    }
}

private struct GlanceState {
    let screen: NSScreen
    let monitorLabel: String?
    let workspaceIndex: Int
    let appearance: AppearanceSnapshot
    let windows: [GlanceWindow]
    let focusedWindowIndex: Int

    var workspaceStyle: WorkspaceUIStyle {
        appearance.uiStyle(forWorkspace: workspaceIndex)
    }

    static func capture(workspaceIndex: Int? = nil) -> GlanceState? {
        let ws = WorkspaceManager.shared
        guard !ws.monitors.isEmpty else { return nil }

        let monitor = ws.focusedMonitor
        let workspaceIndex = workspaceIndex ?? monitor.active
        guard monitor.workspaces.indices.contains(workspaceIndex) else { return nil }
        let tracked = monitor.workspaces[workspaceIndex]
        let focusedIndex = monitor.clampedFocus(in: workspaceIndex)
        let windows = tracked.enumerated().map { windowIndex, window in
            let labels = window.displayLabels()
            return GlanceWindow(
                identityToken: window.overlayIdentityToken,
                appName: labels.appName,
                windowTitle: labels.windowTitle,
                icon: window.appIcon(),
                focused: windowIndex == focusedIndex
            )
        }

        let appearance = Config.shared.appearanceSnapshot
        let monitorLabel = ws.focusedMonitorLabel
        return GlanceState(
            screen: monitor.screen,
            monitorLabel: monitorLabel,
            workspaceIndex: workspaceIndex,
            appearance: appearance,
            windows: windows,
            focusedWindowIndex: focusedIndex
        )
    }
}

private struct GlanceWindow {
    let identityToken: Int
    let appName: String
    let windowTitle: String
    let icon: NSImage
    let focused: Bool
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
        layer?.cornerRadius = OverlayMetrics.cardCornerRadius
        layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "h/l column · j/k row · return/m focus · 1–9 jump · esc close")
        hint.font = .systemFont(ofSize: OverlayMetrics.hintFontSize, weight: .medium)
        hint.textColor = .tertiaryLabelColor

        let style = state.workspaceStyle

        let grid: NSView
        if state.windows.isEmpty {
            grid = GlanceEmptyView()
        } else {
            let tiles = state.windows.enumerated().map { index, window in
                GlanceWindowCell(
                    window: window,
                    selected: index == selectedWindow,
                    accentColor: style.accent,
                    onSelect: { onSelectWindow(index) }
                )
            }
            let gridView = OverlayGridView(cells: tiles)
            gridView.onCellLayout = { index, cellHeight in
                tiles[index].updateTypography(forCellHeight: cellHeight)
            }
            grid = gridView
        }

        let padding = OverlayMetrics.cardPadding
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: style.displayName)
        title.font = .systemFont(ofSize: GlanceMetrics.headerFontSize, weight: .bold)
        title.textColor = style.accent
        header.addArrangedSubview(title)

        if let monitorLabel = state.monitorLabel {
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
    private let appLabel: OverlayLabel
    private let titleLabel: OverlayLabel
    private let iconView: OverlayIconView
    private let iconWidthConstraint: NSLayoutConstraint
    private let iconHeightConstraint: NSLayoutConstraint
    private let caption: NSStackView
    private let content: NSStackView
    private var lastCellHeight: CGFloat = 0

    init(
        window: GlanceWindow,
        selected: Bool,
        accentColor: NSColor,
        onSelect: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.selected = selected
        appLabel = OverlayLabel(
            text: window.appName,
            font: .systemFont(ofSize: GlanceMetrics.bodyFontSize, weight: .semibold),
            color: selected ? accentColor : .labelColor,
            maximumNumberOfLines: 1,
            alignment: .center
        )
        titleLabel = OverlayLabel(
            text: window.windowTitle,
            font: .systemFont(ofSize: OverlayMetrics.hintFontSize, weight: selected ? .medium : .regular),
            color: selected ? accentColor : .secondaryLabelColor,
            maximumNumberOfLines: 2,
            alignment: .center,
            wraps: true
        )
        iconView = OverlayIconView()
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 44)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 44)
        caption = NSStackView(views: [appLabel, titleLabel])
        content = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OverlayMetrics.cellCornerRadius
        SelectionCellStyle.apply(
            to: layer,
            selected: selected,
            focused: window.focused,
            accent: accentColor
        )

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

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
