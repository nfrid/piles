import AppKit

package final class StatusBar: NSObject {
    package static let shared = StatusBar()

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let stackView: NSStackView
    private var lastState: StatusState?

    private override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        stackView = NSStackView()
        super.init()

        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        installStackView()

        update()
    }

    @objc private func reloadConfig() {
        WorkspaceManager.shared.reloadConfig()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func statusBarRightClicked(_ sender: Any?) {
        showContextMenu(from: statusItem.button)
    }

    fileprivate func showContextMenu(from view: NSView?) {
        guard let view else { return }
        let point = NSPoint(x: 0, y: view.bounds.height)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func update() {
        defer {
            MonocleBar.shared.update()
        }

        let ws = WorkspaceManager.shared
        let state = StatusState.capture(ws)
        guard state != lastState else { return }
        lastState = state

        var views: [NSView] = []
        let font = NSFont.menuBarFont(ofSize: 0)
        let fontSize = font.pointSize

        guard !ws.monitors.isEmpty else {
            views.append(BadgeView(
                workspaceIndex: 0,
                fontSize: fontSize,
                active: true,
                accentColor: state.appearance.uiStyle(forWorkspace: 0).accent
            ))
            applyViews(views)
            return
        }

        let monitor = ws.focusedMonitor

        if ws.monitors.count > 1 {
            let monitorNumber = ws.focusedMonitorIndex + 1
            views.append(LayoutIndicatorView(
                text: "\(monitorNumber):",
                fontSize: fontSize,
                accentColor: state.appearance.accent.primary
            ))
        }

        for i in 0..<Config.shared.workspaceCount {
            let isActive = i == monitor.active
            let hasWindows = !monitor.workspaces[i].isEmpty

            guard isActive || hasWindows else { continue }

            views.append(BadgeView(
                workspaceIndex: i,
                fontSize: fontSize,
                active: isActive,
                accentColor: state.appearance.uiStyle(forWorkspace: i).accent
            ))
        }

        if views.isEmpty {
            views.append(BadgeView(
                workspaceIndex: 0,
                fontSize: fontSize,
                active: true,
                accentColor: state.appearance.uiStyle(forWorkspace: 0).accent
            ))
        }

        applyViews(views)
    }

    private func installStackView() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.sendAction(on: [.rightMouseUp])
        button.target = self
        button.action = #selector(statusBarRightClicked)
        button.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            stackView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
    }

    private func applyViews(_ views: [NSView]) {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            stackView.addArrangedSubview(view)
        }

        stackView.invalidateIntrinsicContentSize()
        stackView.needsLayout = true
        stackView.layoutSubtreeIfNeeded()
        statusItem.length = ceil(stackView.fittingSize.width)
    }
}

private func drawCenteredText(_ text: String, in bounds: NSRect, fontSize: CGFloat, color: NSColor, ctx: CGContext) {
    let font = NSFont.systemFont(ofSize: fontSize - 1)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(str)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let textX = bounds.midX - lineBounds.width / 2 - lineBounds.origin.x
    let textY = bounds.midY - font.capHeight / 2
    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, ctx)
}

private final class BadgeView: NSView {
    private let workspaceIndex: Int
    private let label: String
    private let accentColor: NSColor
    private let fontSize: CGFloat
    private let active: Bool

    init(workspaceIndex: Int, fontSize: CGFloat, active: Bool, accentColor: NSColor) {
        self.workspaceIndex = workspaceIndex
        self.label = "\(workspaceIndex + 1)"
        self.accentColor = accentColor
        self.fontSize = fontSize
        self.active = active
        super.init(frame: .zero)
        let size = fontSize + 6
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        if event.buttonNumber != 0 {
            StatusBar.shared.showContextMenu(from: self)
            return
        }
        if event.modifierFlags.contains(.shift) {
            WorkspaceManager.shared.moveActiveWindowTo(workspaceIndex)
        } else {
            WorkspaceManager.shared.switchTo(workspaceIndex)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let fillColor = accentColor

        ctx.addPath(path)
        let textColor: NSColor
        if active {
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
            ctx.setBlendMode(.destinationOut)
            textColor = fillColor.contrastingTextColor
        } else {
            ctx.setStrokeColor(fillColor.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            textColor = fillColor
        }
        drawCenteredText(label, in: bounds, fontSize: fontSize, color: textColor, ctx: ctx)
    }
}

private struct StatusState: Equatable {
    let monitorCount: Int
    let focusedMonitorIndex: Int
    let activeWorkspace: Int
    let occupiedWorkspaces: [Bool]
    let appearance: AppearanceSnapshot

    static func capture(_ ws: WorkspaceManager) -> StatusState {
        let appearance = Config.shared.appearanceSnapshot
        guard !ws.monitors.isEmpty else {
            return StatusState(
                monitorCount: 0, focusedMonitorIndex: 0, activeWorkspace: 0,
                occupiedWorkspaces: [], appearance: appearance
            )
        }
        let monitor = ws.focusedMonitor
        let occupied = (0..<Config.shared.workspaceCount).map { !monitor.workspaces[$0].isEmpty }
        return StatusState(
            monitorCount: ws.monitors.count,
            focusedMonitorIndex: ws.focusedMonitorIndex,
            activeWorkspace: monitor.active,
            occupiedWorkspaces: occupied,
            appearance: appearance
        )
    }
}

private final class LayoutIndicatorView: NSView {
    private let text: String
    private let fontSize: CGFloat

    private let accentColor: NSColor

    init(text: String, fontSize: CGFloat, accentColor: NSColor) {
        self.text = text
        self.fontSize = fontSize
        self.accentColor = accentColor
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: fontSize - 1)
        let str = NSAttributedString(string: text, attributes: [.font: font])
        let textWidth = str.size().width
        widthAnchor.constraint(equalToConstant: textWidth + 6).isActive = true
        heightAnchor.constraint(equalToConstant: fontSize + 6).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCenteredText(text, in: bounds, fontSize: fontSize, color: accentColor, ctx: ctx)
    }
}
