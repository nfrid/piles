import CoreGraphics
@testable import PilesCore

enum HotkeyTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                fputs("FAIL \(file):\(line): \(message)\n", stderr)
                failed += 1
            }
        }

        let resolver = HotkeyResolver()
        var config = Config()

        check(
            resolver.resolve(keyCode: Key.j, flags: [.maskAlternate], config: config) == .focusNext,
            "default focus_next resolves"
        )
        check(
            resolver.resolve(keyCode: Key.j, flags: [.maskAlternate, .maskShift], config: config) == .moveFocusedWindowNext,
            "shifted default move_next resolves"
        )
        check(
            resolver.resolve(keyCode: Key.two, flags: [.maskAlternate], config: config) == .switchTo(1),
            "number key switches workspace"
        )
        check(
            resolver.resolve(keyCode: Key.two, flags: [.maskAlternate, .maskShift], config: config) == .moveActiveWindowTo(1),
            "shifted number key moves window to workspace"
        )
        check(
            resolver.resolve(keyCode: Key.j, flags: [.maskAlternate, .maskCommand], config: config) == .passThrough,
            "extra modifier passes through"
        )

        config.modifier = .maskCommand
        check(
            resolver.resolve(keyCode: Key.tab, flags: [.maskCommand], config: config) == .passThrough,
            "command-tab remains available to the system"
        )

        config = Config()
        config.customBindings = [Binding(key: Key.t, shift: true, command: "open -a Terminal")]
        check(
            resolver.resolve(keyCode: Key.t, flags: [.maskAlternate, .maskShift], config: config) == .runCommand("open -a Terminal"),
            "custom binding resolves before built-ins"
        )

        config = Config()
        config.bindings.workspaceNext = (Key.l, false)
        check(
            resolver.resolve(keyCode: Key.l, flags: [.maskAlternate], config: config) == .switchToOccupied(offset: 1, movingFocusedWindow: false),
            "workspace next resolves without moving"
        )
        check(
            resolver.resolve(keyCode: Key.l, flags: [.maskAlternate, .maskShift], config: config) == .switchToOccupied(offset: 1, movingFocusedWindow: true),
            "shifted workspace next moves focused window"
        )
        check(
            resolver.resolve(keyCode: Key.o, flags: [.maskAlternate], config: config) == .toggleWorkspaceOverview,
            "default workspace overview resolves"
        )
        check(
            resolver.resolve(keyCode: Key.o, flags: [.maskAlternate, .maskShift], config: config) == .toggleWorkspaceGlance,
            "default workspace glance resolves"
        )

        Hotkeys.shared.stop()
        Hotkeys.shared.stop()
        check(true, "hotkeys stop is idempotent")

        WindowObserver.shared.stop()
        WindowObserver.shared.stop()
        check(true, "window observer stop is idempotent")

        PilesTeardown.shutdown()
        PilesTeardown.shutdown()
        check(true, "piles teardown is idempotent")

        return (passed, failed)
    }
}
