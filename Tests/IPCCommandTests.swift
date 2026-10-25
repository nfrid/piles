import Foundation
import ApplicationServices
@testable import PilesCore

enum IPCCommandTests {
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

        func resolves(_ line: String, to action: HotkeyAction, workspaceCount: Int = 9) {
            switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
            case .success(.action(let parsed)):
                check(parsed == action, "'\(line)' resolves to \(action)")
            case .success:
                check(false, "'\(line)' resolved to a non-action command")
            case .failure(.invalid(let error)):
                check(false, "'\(line)' failed: \(error)")
            }
        }

        func rejects(_ line: String, workspaceCount: Int = 9) {
            switch IPCCommandParser.parse(line, workspaceCount: workspaceCount) {
            case .success:
                check(false, "'\(line)' should have failed")
            case .failure:
                check(true, "'\(line)' is rejected")
            }
        }

        var workspaceCountReads = 0
        check(IPCCommandParser.parse("ping", workspaceCount: { workspaceCountReads += 1; return 9 }()) == .success(.ping), "ping parses")
        check(workspaceCountReads == 0, "ping does not read workspace configuration")
        _ = IPCCommandParser.parse("workspace 1", workspaceCount: { workspaceCountReads += 1; return 9 }())
        check(workspaceCountReads == 1, "workspace command reads configured count once")
        rejects("ping now")
        check(IPCCommandParser.parse("status", workspaceCount: 9) == .success(.status), "status parses")
        check(IPCCommandParser.parse("windows", workspaceCount: 9) == .success(.windows), "windows parses")
        rejects("status now")
        rejects("windows now")
        check(IPCCommandParser.parse("rescan", workspaceCount: 9) == .success(.rescan), "rescan parses")
        rejects("rescan now")
        rejects("rescue")

        resolves("workspace 3", to: .switchTo(2))
        resolves("\tworkspace\t3\n", to: .switchTo(2))
        resolves("workspace 3 --move", to: .moveActiveWindowTo(2))
        resolves("workspace next", to: .switchToOccupied(offset: 1, movingFocusedWindow: false))
        resolves("workspace prev --move", to: .switchToOccupied(offset: -1, movingFocusedWindow: true))
        resolves("workspace last", to: .switchToLast)
        resolves("overview", to: .toggleWorkspaceOverview)
        resolves("glance", to: .toggleWorkspaceGlance)
        resolves("focus next", to: .focusNext)
        resolves("window move prev", to: .moveFocusedWindowPrev)
        resolves("window close", to: .closeActiveWindow)
        resolves("layout toggle", to: .toggleLayout)
        resolves("master swap", to: .swapMaster)
        resolves("monitor focus next", to: .focusMonitor(1))

        rejects("workspace 0")
        rejects("workspace 10", workspaceCount: 9)
        rejects("workspace last --move")
        rejects("unknown")

        func trackedWindow(_ offset: Int32) -> TrackedWindow {
            let pid = pid_t(getpid() + offset)
            let app = AXUIElementCreateApplication(pid)
            return TrackedWindow(element: app, pid: pid, group: WindowGroupKey(pid: pid, frame: .null))
        }
        var firstState = MonitorState(count: 2, defaultLayout: .tile)
        firstState.layouts = [.tile, .monocle]
        firstState.workspaces[0] = [trackedWindow(1)]
        firstState.workspaces[1] = [trackedWindow(2), trackedWindow(3)]
        firstState.active = 1
        var secondState = MonitorState(count: 1, defaultLayout: .monocle)
        secondState.workspaces[0] = [trackedWindow(4)]
        let sources = [
            DiagnosticsMonitorSource(displayID: 10, name: "Left", state: firstState),
            DiagnosticsMonitorSource(displayID: 20, name: "Right", state: secondState),
        ]

        let status = DiagnosticsSnapshot.status(focusedMonitorIndex: 1, sources: sources)
        check(status.focused_monitor == 2 && status.monitors.map(\.index) == [1, 2]
              && status.monitors.map(\.display_id) == [10, 20], "status factory uses 1-based monitor order")
        check(status.monitors[0].active_workspace == 2
              && status.monitors[0].workspaces.map(\.layout) == ["tile", "monocle"]
              && status.monitors[0].workspaces.map(\.window_count) == [1, 2]
              && status.monitors[0].workspaces.map(\.index) == [1, 2], "status factory reports workspace order, layout, and count")

        var frameReads = 0
        let windows = DiagnosticsSnapshot.windows(
            sources: sources,
            labels: { window in ("App \(window.pid)", "example.\(window.pid)", "Window \(window.pid)") },
            frame: { window in
                frameReads += 1
                switch window.pid - pid_t(getpid()) {
                case 1: return CGRect(x: 1, y: 2, width: 3, height: 4)
                case 2: return nil
                case 3: return CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)
                default: return CGRect(x: 5, y: 6, width: 7, height: 8)
                }
            }
        ).windows
        check(windows.map(\.pid) == (1...4).map { Int32(getpid()) + Int32($0) }
              && windows.map(\.monitor) == [1, 1, 1, 2]
              && windows.map(\.workspace) == [1, 2, 2, 1], "windows factory preserves monitor/workspace/window ordering and uses 1-based indices")
        check(windows.map(\.active) == [false, true, true, true], "all windows in each active workspace are active")
        check(windows[0].frame == DiagnosticsFrame(x: 1, y: 2, width: 3, height: 4)
              && windows[1].frame == nil && windows[2].frame == nil, "nil and nonfinite frames are unavailable")
        check(frameReads == 4, "windows snapshot reads each frame once")
        check(firstState.active == 1 && firstState.workspaces.map(\.count) == [1, 2]
              && firstState.layouts == [.tile, .monocle], "snapshot factories leave monitor state unchanged")

        let empty = DiagnosticsSnapshot.status(focusedMonitorIndex: nil, sources: [])
        check(empty.focused_monitor == nil && empty.monitors.isEmpty, "status factory handles no-monitor state")
        let encoded = try? JSONEncoder().encode(DiagnosticsSnapshot.windows(
            sources: sources, labels: { _ in (nil, nil, nil) }, frame: { _ in nil }
        ))
        let decoded = encoded.flatMap { try? JSONDecoder().decode(DiagnosticsWindows.self, from: $0) }
        check(decoded?.windows.map(\.monitor) == [1, 1, 1, 2], "diagnostic windows JSON encodes factory output")

        return (passed, failed)
    }
}
