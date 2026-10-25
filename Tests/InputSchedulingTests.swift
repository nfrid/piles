import AppKit
@testable import PilesCore

enum InputSchedulingTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 }
            else {
                failed += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        let host = TestOverlayHost()
        let session = OverlaySession(host: host)
        let config = Config()
        session.show()
        check(session.handleKey(keyCode: Key.j, flags: [], config: config), "overlay consumes navigation")
        check(host.verticalMoves == 0, "overlay action does not execute inside input callback")
        drainMainQueue()
        check(host.verticalMoves == 1, "overlay executes navigation on the main queue")

        _ = session.handleKey(keyCode: Key.j, flags: [], config: config)
        session.hide()
        session.show()
        drainMainQueue()
        check(host.verticalMoves == 1, "reopening an overlay discards input queued for its previous session")
        _ = session.handleKey(keyCode: Key.j, flags: [], config: config)
        session.hide()
        drainMainQueue()
        check(host.verticalMoves == 1, "hidden overlays do not execute pending input")

        var positions: [CGPoint] = []
        let drag = MasterRatioDragHandler { positions.append($0) }
        drag.updateResizeRegion(CGRect(x: 45, y: 0, width: 16, height: 100))
        func event(_ type: CGEventType, x: CGFloat) -> CGEvent {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: x, y: 50), mouseButton: .left)!
        }
        func consumed(_ disposition: MasterRatioDragHandler.Disposition) -> Bool {
            if case .consume = disposition { return true }
            return false
        }
        check(consumed(drag.handle(type: .leftMouseDown, event: event(.leftMouseDown, x: 50),
                                   flags: [.maskAlternate], config: config)), "divider hit uses cached region")
        _ = drag.handle(type: .leftMouseDragged, event: event(.leftMouseDragged, x: 70),
                        flags: [.maskAlternate], config: config)
        _ = drag.handle(type: .leftMouseDragged, event: event(.leftMouseDragged, x: 80),
                        flags: [.maskAlternate], config: config)
        _ = drag.handle(type: .leftMouseUp, event: event(.leftMouseUp, x: 90),
                        flags: [], config: config)
        check(positions.isEmpty, "divider geometry is not written inside the event tap")
        waitUntil { !positions.isEmpty }
        check(positions == [CGPoint(x: 90, y: 50)], "drag updates coalesce and retain the final release position")

        _ = drag.handle(type: .leftMouseDown, event: event(.leftMouseDown, x: 50),
                        flags: [.maskAlternate], config: config)
        _ = drag.handle(type: .leftMouseDragged, event: event(.leftMouseDragged, x: 60),
                        flags: [.maskAlternate], config: config)
        drag.reset()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        check(positions.count == 1, "stopping input cancels queued resize work")
        drag.updateResizeRegion(nil)
        check(!consumed(drag.handle(type: .leftMouseDown, event: event(.leftMouseDown, x: 50),
                                    flags: [.maskAlternate], config: config)), "unavailable divider does not intercept mouse input")
        return (passed, failed)
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private static func drainMainQueue() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        waitUntil { drained }
    }
}

private final class TestOverlayHost: OverlaySessionHost {
    var verticalMoves = 0
    func overlayPrepareToShow() {}
    func overlayPresent(animated: Bool, refreshing: Bool) -> Bool { true }
    func overlayDidHide() {}
    func overlayToggleBinding(_ config: Config) -> (key: UInt16, shift: Bool) { config.bindings.workspaceOverview }
    func overlayHandleExtraKey(keyCode: UInt16, flags: CGEventFlags, config: Config) -> Bool { false }
    func overlayConfirm() {}
    func overlayNavigateHorizontal(delta: Int) {}
    func overlayNavigateVertical(delta: Int) { verticalMoves += delta }
    func overlayNumberJump(index: Int) {}
}
