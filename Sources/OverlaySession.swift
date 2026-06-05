import AppKit

protocol OverlaySessionHost: AnyObject {
    func overlayPrepareToShow()
    func overlayPresent(animated: Bool, refreshing: Bool) -> Bool
    func overlayDidHide()
    func overlayToggleBinding(_ config: Config) -> (key: UInt16, shift: Bool)
    func overlayHandleExtraKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool
    func overlayConfirm()
    func overlayNavigateHorizontal(delta: Int)
    func overlayNavigateVertical(delta: Int)
    func overlayNumberJump(index: Int)
}

enum OverlayGridSelection {
    @discardableResult
    static func moveHorizontal(selected: inout Int, delta: Int, count: Int) -> Bool {
        guard let next = OverlayGridNavigation.moveHorizontal(
            selected: selected,
            delta: delta,
            count: count,
            columns: OverlayMetrics.gridColumns
        ) else { return false }
        selected = next
        return true
    }

    @discardableResult
    static func moveRow(selected: inout Int, delta: Int, count: Int) -> Bool {
        guard let next = OverlayGridNavigation.moveRow(
            selected: selected,
            delta: delta,
            count: count,
            columns: OverlayMetrics.gridColumns
        ) else { return false }
        selected = next
        return true
    }
}

final class OverlaySession {
    private let panelController = OverlayPanelController()
    private weak var host: OverlaySessionHost?

    private(set) var isVisible = false

    init(host: OverlaySessionHost) {
        self.host = host
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let host else { return }
        host.overlayPrepareToShow()
        guard host.overlayPresent(animated: true, refreshing: false) else { return }
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        host?.overlayDidHide()
        panelController.dismiss { [weak self] in
            !(self?.isVisible ?? false)
        }
    }

    func refreshIfVisible() {
        guard isVisible, let host else { return }
        guard host.overlayPresent(animated: false, refreshing: true) else {
            hide()
            return
        }
    }

    func handleKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
        guard isVisible, let host else { return false }

        if host.overlayHandleExtraKey(keyCode: keyCode, flags: flags, config: config) {
            return true
        }

        switch OverlayKeyInput.resolve(
            keyCode: keyCode,
            flags: flags,
            config: config,
            toggleBinding: host.overlayToggleBinding(config)
        ) {
        case .passThrough:
            return false
        case .dismiss:
            MainThread.run { self.hide() }
            return true
        case .navigateHorizontal(let delta):
            MainThread.run { host.overlayNavigateHorizontal(delta: delta) }
            return true
        case .navigateVertical(let delta):
            MainThread.run { host.overlayNavigateVertical(delta: delta) }
            return true
        case .confirm:
            MainThread.run { host.overlayConfirm() }
            return true
        case .numberJump(let index):
            MainThread.run {
                host.overlayNumberJump(index: index)
                self.hide()
            }
            return true
        case .unrecognized:
            return true
        }
    }

    func present(contentView: NSView, on screen: NSScreen, animated: Bool) {
        panelController.present(contentView: contentView, on: screen, animated: animated)
    }

    func updateContent(_ contentView: NSView) {
        panelController.updateContent(contentView)
    }
}
