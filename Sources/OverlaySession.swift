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
    private var generation = 0

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
        generation += 1
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        generation += 1
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
            enqueue { _ in self.hide() }
            return true
        case .navigateHorizontal(let delta):
            enqueue { $0.overlayNavigateHorizontal(delta: delta) }
            return true
        case .navigateVertical(let delta):
            enqueue { $0.overlayNavigateVertical(delta: delta) }
            return true
        case .confirm:
            enqueue { $0.overlayConfirm() }
            return true
        case .numberJump(let index):
            enqueue {
                $0.overlayNumberJump(index: index)
                self.hide()
            }
            return true
        case .unrecognized:
            return true
        }
    }

    func enqueue(_ work: @escaping (OverlaySessionHost) -> Void) {
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.generation == generation, let host = self.host else { return }
            work(host)
        }
    }

    func present(contentView: NSView, on screen: NSScreen, animated: Bool) {
        panelController.present(contentView: contentView, on: screen, animated: animated)
    }

}
