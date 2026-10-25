import ApplicationServices
import CoreGraphics
@testable import PilesCore

enum WindowRecoveryTests {
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
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 100, y: 100, width: 800, height: 600)
        let parked = CGRect(x: -1919, y: 1079, width: 1920, height: 1080)
        check(WindowRecovery.recoveryFrame(for: visible, screens: [screen]) == nil,
              "recovery leaves onscreen windows unchanged")
        check(WindowRecovery.recoveryFrame(for: parked, screens: [screen]) == screen,
              "recovery restores a window parked with a one-pixel sliver visible")
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let spanning = CGRect(x: -100, y: 100, width: 800, height: 500)
        check(WindowRecovery.recoveryFrame(for: spanning, screens: [left, screen])
              == CGRect(x: 0, y: 100, width: 800, height: 500),
              "recovery prefers the display with the largest overlap")
        let farLeft = CGRect(x: -3000, y: 110, width: 600, height: 500)
        check(WindowRecovery.recoveryFrame(for: farLeft, screens: [screen, left])
              == CGRect(x: -1440, y: 110, width: 600, height: 500),
              "fully offscreen windows go to the nearest display, including negative coordinates")
        let below = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        check(WindowRecovery.recoveryFrame(for: CGRect(x: 100, y: 2300, width: 600, height: 400), screens: [screen, below])
              == CGRect(x: 100, y: 1760, width: 600, height: 400),
              "recovery supports vertically arranged displays")
        let oversized = CGRect(x: -500, y: -300, width: 3000, height: 1800)
        check(WindowRecovery.recoveryFrame(for: oversized, screens: [screen])
              == CGRect(x: 0, y: 0, width: 3000, height: 1800),
              "recovery preserves oversized window dimensions and restores its top-left corner")
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let other = CGRect(x: 200, y: 0, width: 100, height: 100)
        check(WindowRecovery.recoveryFrame(for: CGRect(x: 140, y: 20, width: 20, height: 20), screens: [small, other])
              == CGRect(x: 80, y: 20, width: 20, height: 20),
              "equidistant displays retain their original order")
        check(WindowRecovery.recoveryFrame(for: parked, screens: []) == nil, "no screens produce no geometry target")
        check(WindowRecovery.recoveryFrame(for: .zero, screens: [screen]) == nil, "invalid window dimensions produce no geometry target")
        check(WindowRecovery.recoveryFrame(for: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), screens: [screen]) == nil,
              "non-finite geometry is rejected")
        check(WindowRecovery.recoveryFrame(for: parked, screens: [.zero, screen]) == screen,
              "unusable displays do not affect recovery")
        for invalid in [
            CGRect(x: 0, y: 0, width: -100, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100),
        ] {
            check(WindowRecovery.recoveryFrame(for: invalid, screens: [screen]) == nil,
                  "invalid raw dimensions or overflowing coordinates are rejected")
            check(WindowRecovery.recoveryFrame(for: parked, screens: [invalid]) == nil,
                  "invalid display dimensions are rejected")
        }

        let unreadable = AXUIElementCreateApplication(900_101)
        let anotherUnreadable = AXUIElementCreateApplication(900_102)
        let rawInventory = WindowManager.recoveryWindows(pid: 900_000,
                                                        elements: [unreadable, unreadable, anotherUnreadable])
        check(rawInventory.count == 2, "recovery inventory retains unreadable windows and deduplicates references")
        let unreadableResult = WindowRecovery.rescue(windows: rawInventory, screens: [screen], attributesFor: { _ in nil })
        if case .success(let report) = unreadableResult {
            check(report.failed == 2 && report.hasFailures, "unreadable recovery inventory reports failure instead of false success")
        } else {
            check(false, "unreadable inventory still produces a recovery report when displays exist")
        }

        let windows: [TrackedWindow] = (1...8).map { index in
            let pid = pid_t(90_000 + index)
            return TrackedWindow(element: AXUIElementCreateApplication(pid), pid: pid,
                                 group: WindowGroupKey(pid: pid, frame: parked))
        }
        let standard = WindowAttributes(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                                        minimized: false, fullscreen: false)
        var moves: [(pid_t, CGPoint)] = []
        let result = WindowRecovery.rescue(
            windows: windows,
            screens: [screen],
            unavailableApplications: 2,
            attributesFor: { window in
                switch window.pid {
                case 90_003:
                    return WindowAttributes(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                                            minimized: false, fullscreen: true)
                case 90_004:
                    return WindowAttributes(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                                            minimized: true, fullscreen: false)
                case 90_005: return nil
                case 90_006:
                    return WindowAttributes(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                                            minimized: false, fullscreen: false, fullscreenKnown: false)
                default: return standard
                }
            },
            frameFor: { window in
                if window.pid == 90_007 { return nil }
                return window.pid == 90_001 ? visible : parked
            },
            move: { window, position in
                moves.append((window.pid, position))
                return window.pid != 90_008
            }
        )
        if case .success(let report) = result {
            check(report.restored == 1 && report.skipped == 3 && report.failed == 4,
                  "recovery reports successful, skipped, and uncertain or failed windows separately")
            check(report.unavailableApplications == 2 && report.hasFailures,
                  "partial application scan failures remain visible in the report")
        } else {
            check(false, "recovery runs with a usable display")
        }
        check(moves.map { $0.0 } == [90_002, 90_008],
              "recovery never writes geometry for visible, fullscreen, minimized, or unknown windows")
        check(moves.allSatisfy { $0.1 == .zero }, "recovery writes only the planned position in discovery order")

        var readWithoutScreens = false
        let noScreens = WindowRecovery.rescue(windows: windows, screens: [], attributesFor: { _ in
            readWithoutScreens = true
            return standard
        })
        if case .failure(.noScreens) = noScreens {
            check(!readWithoutScreens, "recovery fails before any AX work when no screens are available")
        } else {
            check(false, "recovery refuses to run without screens")
        }
        if case .success(let empty) = WindowRecovery.rescue(windows: [], screens: [screen]) {
            check(empty.restored == 0 && empty.skipped == 0 && !empty.hasFailures,
                  "an empty scan is a successful no-op")
        } else {
            check(false, "empty recovery succeeds")
        }
        return (passed, failed)
    }
}
