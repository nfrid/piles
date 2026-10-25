import Foundation

package struct DiagnosticsFrame: Codable, Equatable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double
}

package struct DiagnosticsWindow: Codable, Equatable {
    package let pid: Int32
    package let app: String?
    package let bundle_id: String?
    package let title: String?
    package let monitor: Int
    package let workspace: Int
    package let active: Bool
    package let floating: Bool
    package let frame: DiagnosticsFrame?
}

package struct DiagnosticsWorkspace: Codable, Equatable {
    package let index: Int
    package let layout: String
    package let window_count: Int
}

package struct DiagnosticsMonitor: Codable, Equatable {
    package let index: Int
    package let display_id: UInt32
    package let name: String
    package let active_workspace: Int
    package let workspaces: [DiagnosticsWorkspace]
}

package struct DiagnosticsStatus: Codable, Equatable {
    package let paused: Bool
    package let focused_monitor: Int?
    package let monitors: [DiagnosticsMonitor]
}

package struct DiagnosticsWindows: Codable, Equatable {
    package let windows: [DiagnosticsWindow]
}

package struct DiagnosticsMonitorSource {
    package let displayID: UInt32
    package let name: String
    package let state: MonitorState
}

package enum DiagnosticsSnapshot {
    package static func status(from workspace: WorkspaceManager) -> DiagnosticsStatus {
        status(
            focusedMonitorIndex: workspace.monitors.isEmpty ? nil : workspace.focusedMonitorIndex,
            sources: sources(from: workspace),
            paused: workspace.isPaused
        )
    }

    package static func status(
        focusedMonitorIndex: Int?,
        sources: [DiagnosticsMonitorSource],
        paused: Bool = false
    ) -> DiagnosticsStatus {
        DiagnosticsStatus(
            paused: paused,
            focused_monitor: focusedMonitorIndex.map { $0 + 1 },
            monitors: sources.enumerated().map { monitorIndex, source in
                DiagnosticsMonitor(
                    index: monitorIndex + 1,
                    display_id: source.displayID,
                    name: source.name,
                    active_workspace: source.state.active + 1,
                    workspaces: source.state.workspaces.indices.map { workspaceIndex in
                        DiagnosticsWorkspace(
                            index: workspaceIndex + 1,
                            layout: source.state.layouts[workspaceIndex] == .tile ? "tile" : "monocle",
                            window_count: source.state.workspaces[workspaceIndex].count
                        )
                    }
                )
            }
        )
    }

    package static func windows(from workspace: WorkspaceManager) -> DiagnosticsWindows {
        windows(
            sources: sources(from: workspace),
            labels: { window in
                (window.appName(), window.bundleID(), window.title())
            },
            frame: { $0.getFrame() }
        )
    }

    static func windows(
        sources: [DiagnosticsMonitorSource],
        labels: (TrackedWindow) -> (app: String?, bundleID: String?, title: String?),
        frame: (TrackedWindow) -> CGRect?
    ) -> DiagnosticsWindows {
        DiagnosticsWindows(windows: sources.enumerated().flatMap { monitorIndex, source in
            source.state.workspaces.enumerated().flatMap { workspaceIndex, windows in
                windows.map { window in
                    let windowLabels = labels(window)
                    return DiagnosticsWindow(
                        pid: window.pid,
                        app: windowLabels.app,
                        bundle_id: windowLabels.bundleID,
                        title: windowLabels.title,
                        monitor: monitorIndex + 1,
                        workspace: workspaceIndex + 1,
                        active: workspaceIndex == source.state.active,
                        floating: source.state.isFloating(window),
                        frame: frameSnapshot(frame(window))
                    )
                }
            }
        })
    }

    private static func sources(from workspace: WorkspaceManager) -> [DiagnosticsMonitorSource] {
        workspace.monitors.map {
            DiagnosticsMonitorSource(displayID: $0.displayID, name: $0.screen.localizedName, state: $0.state)
        }
    }

    private static func frameSnapshot(_ frame: CGRect?) -> DiagnosticsFrame? {
        guard let frame,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return nil }
        return DiagnosticsFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }
}
