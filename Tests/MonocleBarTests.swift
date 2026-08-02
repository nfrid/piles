import AppKit
import Darwin
@testable import PilesCore

enum MonocleBarTests {
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

        guard let screen = NSScreen.screens.first else {
            fputs("skip MonocleBarTests: no screens available\n", stderr)
            return (passed, failed)
        }

        let appearance = AppearanceSnapshot(
            accent: AccentPalette(colorHex: nil),
            workspaces: []
        )
        let items = [MonocleBarItem(identity: 1, title: "Window")]
        func state(activeWorkspace: Int) -> MonocleBarState {
            MonocleBarState(
                displayID: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0,
                screen: screen,
                items: items,
                focusedIndex: 0,
                contentWidth: 100,
                appearance: appearance,
                activeWorkspace: activeWorkspace
            )
        }

        check(state(activeWorkspace: 0) == state(activeWorkspace: 0), "equal monocle states compare equal")
        check(
            state(activeWorkspace: 0) != state(activeWorkspace: 1),
            "active workspace participates in monocle state equality"
        )

        return (passed, failed)
    }
}
