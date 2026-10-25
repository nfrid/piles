import AppKit
import ApplicationServices
@testable import PilesCore

enum WindowModeTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
            if condition { passed += 1 }
            else {
                fputs("fail \(file):\(line): \(message)\n", stderr)
                failed += 1
            }
        }

        check(!WorkspaceManager.shared.setFocusedFloating(true), "empty manager rejects floating mode safely")
        check(!WorkspaceManager.shared.toggleFocusedFloating(), "empty manager rejects floating toggle safely")

        let first = testWindow(pid: 9301)
        let second = testWindow(pid: 9302)
        var state = MonitorState(count: 3, defaultLayout: .tile)
        state.insertWindow(first)
        state.insertWindow(second)
        state.setFloating(true, for: first)
        check(state.workspaces[0] == [second, first], "floating metadata does not change workspace order")
        check(state.isFloating(first) && !state.isFloating(second), "floating state is scoped to window identity")
        check(state.moveActiveWindow(matching: first, to: 2) == first, "floating window moves with its workspace")
        check(state.isFloating(first), "floating state survives workspace moves")
        state.setFloating(false, for: first)
        check(!state.isFloating(first), "floating can be disabled")

        state.setFloating(true, for: first)
        let replacement = TrackedWindow(
            element: first.element,
            pid: first.pid,
            members: [AXUIElementCreateApplication(9399)],
            group: first.group
        )
        state.replaceWindow(first, with: replacement)
        check(state.workspaces[2].first == replacement && state.isFloating(replacement),
              "replacement transfers floating metadata and keeps workspace position")

        guard let screen = NSScreen.screens.first else {
            fputs("skip WindowModeTests geometry cases: no screens available\n", stderr)
            return (passed, failed)
        }

        let trackable = attributes()
        let tiled = testWindow(pid: 9401)
        let floating = testWindow(pid: 9402)
        let layoutMonitor = Monitor(displayID: 0, screen: screen)
        layoutMonitor.state.workspaces[0] = [tiled, floating]
        layoutMonitor.state.setFloating(true, for: floating)
        layoutMonitor.windowAttributes = { _ in trackable }
        layoutMonitor.isEligibleForGeometry = { _ in true }
        var frames: [pid_t: CGRect] = [
            tiled.pid: CGRect(x: 5, y: 5, width: 100, height: 100),
            floating.pid: CGRect(x: 20, y: 30, width: 420, height: 310),
        ]
        var frameWrites: [pid_t] = []
        layoutMonitor.readFrame = { frames[$0.pid] }
        layoutMonitor.writeFrame = { window, frame in
            frameWrites.append(window.pid)
            frames[window.pid] = frame
            return true
        }
        _ = layoutMonitor.retile()
        check(frameWrites == [tiled.pid], "retile writes only tiled windows, not floating windows")
        check(frames[floating.pid] == CGRect(x: 20, y: 30, width: 420, height: 310),
              "floating frame remains unchanged during retile")
        check(!layoutMonitor.canResizeMasterRatio(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY)),
              "one tiled plus one floating window does not expose master ratio resize")

        let parkedMonitor = Monitor(displayID: 0, screen: screen)
        let foreground = testWindow(pid: 9501)
        let background = testWindow(pid: 9502)
        let foregroundFrame = CGRect(x: 90, y: 100, width: 500, height: 400)
        let backgroundFrame = CGRect(x: 160, y: 140, width: 620, height: 450)
        var parkedFrames = [foreground.pid: parkedFrame(foregroundFrame, screen), background.pid: backgroundFrame]
        var positionWrites: [(pid: pid_t, point: CGPoint)] = []
        var restoreWrites: [pid_t] = []
        parkedMonitor.paused = true
        parkedMonitor.isEligibleForGeometry = { _ in true }
        parkedMonitor.readFrame = { parkedFrames[$0.pid] }
        parkedMonitor.moveWindow = { window, point in
            positionWrites.append((window.pid, point))
            if let frame = parkedFrames[window.pid] {
                parkedFrames[window.pid] = CGRect(origin: point, size: frame.size)
            }
            return true
        }
        parkedMonitor.writeFrame = { window, frame in
            restoreWrites.append(window.pid)
            parkedFrames[window.pid] = frame
            return true
        }
        parkedMonitor.state.workspaces[0] = [background]
        parkedMonitor.state.workspaces[1] = [foreground]
        parkedMonitor.state.saveParkedFrame(foregroundFrame, for: foreground)
        parkedMonitor.state.active = 1
        parkedMonitor.revealActiveWorkspace(hiding: 0)
        check(parkedFrames[foreground.pid] == foregroundFrame, "paused workspace reveal restores its manual frame")
        check(parkedMonitor.state.parkedFrame(for: background) == backgroundFrame,
              "paused workspace switch saves the background manual frame")
        check(positionWrites.map(\.pid) == [background.pid], "parking uses position-only writes")
        check(restoreWrites == [foreground.pid], "reveal restores only the active parked window")
        check(parkedFrames[background.pid]?.size == backgroundFrame.size,
              "parking preserves the background window size")

        let retryMonitor = Monitor(displayID: 0, screen: screen)
        let retryWindow = testWindow(pid: 900_201)
        retryMonitor.state.insertWindow(retryWindow, floating: true)
        retryMonitor.isEligibleForGeometry = { _ in true }
        var retryFrame: CGRect? = backgroundFrame
        var writesAllowed = false
        var retryMoves = 0
        retryMonitor.readFrame = { _ in retryFrame }
        retryMonitor.moveWindow = { _, point in
            retryMoves += 1
            guard writesAllowed, let current = retryFrame else { return false }
            retryFrame = CGRect(origin: point, size: current.size)
            return true
        }
        retryMonitor.writeFrame = { _, frame in
            guard writesAllowed else { return false }
            retryFrame = frame
            return true
        }
        retryMonitor.park(retryWindow)
        check(retryMonitor.state.parkedFrame(for: retryWindow) == backgroundFrame,
              "failed park retains the original geometry for partially successful grouped writes")
        let adjusted = CGRect(x: 180, y: 170, width: 600, height: 440)
        retryFrame = adjusted
        retryMonitor.park(retryWindow)
        check(retryMonitor.state.parkedFrame(for: retryWindow) == adjusted,
              "park retry captures a newer manual frame rather than stale failed-write geometry")
        writesAllowed = true
        retryMonitor.park(retryWindow)
        retryMonitor.park(retryWindow)
        check(retryMoves == 3 && retryMonitor.state.parkedFrame(for: retryWindow) == adjusted,
              "repeated successful park never overwrites the saved frame with parked coordinates")
        writesAllowed = false
        retryMonitor.reveal(retryWindow)
        check(retryMonitor.state.parkedFrame(for: retryWindow) == adjusted,
              "failed reveal retains geometry for retry")
        writesAllowed = true
        retryMonitor.reveal(retryWindow)
        check(retryFrame == adjusted && retryMonitor.state.parkedFrame(for: retryWindow) == nil,
              "successful reveal retry restores and clears saved geometry")
        retryFrame = nil
        retryMonitor.park(retryWindow)
        check(retryMoves == 3 && retryMonitor.state.parkedFrame(for: retryWindow) == nil,
              "failed frame reads do not issue writes or invent saved geometry")

        let pendingMonitor = Monitor(displayID: 0, screen: screen)
        pendingMonitor.windowAttributes = { _ in trackable }
        pendingMonitor.readFrame = { _ in nil }
        var pendingWrites = 0
        pendingMonitor.writeFrame = { _, _ in pendingWrites += 1; return true }
        _ = pendingMonitor.addWindow(testWindow(pid: 900_202))
        pendingMonitor.paused = true
        var flushed = false
        DispatchQueue.main.async { flushed = true }
        let flushDeadline = Date().addingTimeInterval(1)
        while !flushed && Date() < flushDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(flushed && pendingWrites == 0, "queued automatic retile rechecks pause before any writes")
        pendingMonitor.cancelPendingWork()

        let overflowMonitor = Monitor(displayID: 0, screen: screen)
        let overflow = testWindow(pid: 9601)
        var overflowFrame = parkedFrame(backgroundFrame, screen)
        overflowMonitor.paused = true
        overflowMonitor.isEligibleForGeometry = { _ in true }
        overflowMonitor.readFrame = { _ in overflowFrame }
        overflowMonitor.writeFrame = { _, frame in overflowFrame = frame; return true }
        overflowMonitor.state.workspaces[1] = [overflow]
        overflowMonitor.state.saveParkedFrame(backgroundFrame, for: overflow)
        overflowMonitor.resizeWorkspaces(to: 1)
        check(overflowMonitor.state.workspaces[0] == [overflow] && overflowFrame == backgroundFrame,
              "workspace shrink reveals a parked window moved into the active workspace")

        let eligibleMonitor = Monitor(displayID: 0, screen: screen)
        let eligible = testWindow(pid: 9701)
        let minimized = testWindow(pid: 9702)
        let fullscreen = testWindow(pid: 9703)
        let unknown = testWindow(pid: 9704)
        let minimizedAttributes = attributes(minimized: true)
        let fullscreenAttributes = attributes(fullscreen: true)
        let unknownAttributes = attributes(minimizedKnown: false)
        let attributeMap: [pid_t: WindowAttributes] = [
            eligible.pid: trackable,
            minimized.pid: minimizedAttributes,
            fullscreen.pid: fullscreenAttributes,
            unknown.pid: unknownAttributes,
        ]
        eligibleMonitor.windowAttributes = { attributeMap[$0.pid] }
        eligibleMonitor.isEligibleForGeometry = { eligibleMonitor.windowAttributes($0)?.isTileable == true }
        var eligibleWrites: [pid_t] = []
        var eligibleMoves: [pid_t] = []
        eligibleMonitor.readFrame = { _ in CGRect(x: 50, y: 60, width: 300, height: 200) }
        eligibleMonitor.writeFrame = { window, _ in eligibleWrites.append(window.pid); return true }
        eligibleMonitor.moveWindow = { window, _ in eligibleMoves.append(window.pid); return true }
        for window in [eligible, minimized, fullscreen, unknown] {
            eligibleMonitor.state.saveParkedFrame(CGRect(x: 10, y: 20, width: 300, height: 200), for: window)
            eligibleMonitor.park(window)
            eligibleMonitor.reveal(window)
        }
        eligibleMonitor.state.workspaces[0] = [eligible, minimized, fullscreen, unknown]
        eligibleMonitor.restoreAllWindows()
        check(eligibleMoves == [eligible.pid], "parking skips minimized, fullscreen, and unknown windows")
        check(eligibleWrites == [eligible.pid, eligible.pid], "reveal and restore skip ineligible windows")

        let source = Monitor(displayID: 1, screen: screen)
        let target = Monitor(displayID: 2, screen: screen)
        let transferred = testWindow(pid: 9801)
        let sourceFrame = CGRect(x: screen.frame.maxX - 20, y: screen.frame.minY - 30, width: 300, height: 200)
        source.state.insertWindow(transferred, floating: true)
        source.state.saveParkedFrame(sourceFrame, for: transferred)
        target.paused = true
        target.isEligibleForGeometry = { _ in true }
        var transferredFrame: CGRect?
        target.writeFrame = { _, frame in transferredFrame = frame; return true }
        target.transferGeometry(of: transferred, from: source.geometryForTransfer(transferred)!)
        let expectedTransfer = WorkspaceWindows.framePreservingSizeInsideScreen(
            sourceFrame,
            screen: WindowManager.screenFrame(for: screen)
        )
        check(transferredFrame == expectedTransfer, "cross-monitor transfer clamps geometry and preserves size while paused")
        check(transferredFrame?.size == sourceFrame.size, "cross-monitor transfer does not resize")

        let cachedSource = Monitor(displayID: 1, screen: screen)
        let cachedTarget = Monitor(displayID: 2, screen: screen)
        let cachedWindow = testWindow(pid: 9802)
        cachedSource.state.insertWindow(cachedWindow, floating: true)
        let outsideFrame = CGRect(x: screen.frame.maxX + 40, y: screen.frame.minY - 20,
                                  width: 250, height: 180)
        cachedSource.state.saveParkedFrame(outsideFrame, for: cachedWindow)
        cachedTarget.copyState(from: cachedSource)
        let clampedCachedFrame = WorkspaceWindows.framePreservingSizeInsideScreen(
            outsideFrame,
            screen: WindowManager.screenFrame(for: screen)
        )
        check(cachedTarget.state.parkedFrame(for: cachedWindow) == clampedCachedFrame,
              "screen rebuild clamps cached restore frames to the new display bounds")

        let resizeMonitor = Monitor(displayID: 0, screen: screen)
        let active = testWindow(pid: 9901)
        let inactive = testWindow(pid: 9902)
        var visibilityFrames = [active.pid: parkedFrame(foregroundFrame, screen), inactive.pid: CGRect(x: 80, y: 80, width: 100, height: 90)]
        var visibilityMoves: [pid_t] = []
        resizeMonitor.paused = true
        resizeMonitor.isEligibleForGeometry = { _ in true }
        resizeMonitor.readFrame = { visibilityFrames[$0.pid] }
        resizeMonitor.moveWindow = { window, point in
            visibilityMoves.append(window.pid)
            if let frame = visibilityFrames[window.pid] { visibilityFrames[window.pid] = CGRect(origin: point, size: frame.size) }
            return true
        }
        resizeMonitor.writeFrame = { window, frame in visibilityFrames[window.pid] = frame; return true }
        resizeMonitor.state.workspaces[0] = [active]
        resizeMonitor.state.workspaces[1] = [inactive]
        resizeMonitor.state.saveParkedFrame(foregroundFrame, for: active)
        resizeMonitor.reconcileVisibility()
        check(visibilityFrames[active.pid] == foregroundFrame, "visibility reconciliation reveals parked active windows")
        check(resizeMonitor.state.parkedFrame(for: inactive) != nil && visibilityMoves == [inactive.pid],
              "visibility reconciliation keeps inactive windows parked")

        let cleanupMonitor = Monitor(displayID: 0, screen: screen)
        cleanupMonitor.state.workspaces[0] = [minimized]
        cleanupMonitor.state.setFloating(true, for: minimized)
        cleanupMonitor.state.saveParkedFrame(foregroundFrame, for: minimized)
        _ = cleanupMonitor.cleanActiveWorkspace(attributesFor: { _ in minimizedAttributes })
        check(!cleanupMonitor.state.isFloating(minimized) && cleanupMonitor.state.parkedFrame(for: minimized) == nil,
              "cleanup prunes metadata for windows removed from the workspace")

        return (passed, failed)
    }

    private static func attributes(
        minimized: Bool = false,
        fullscreen: Bool = false,
        minimizedKnown: Bool = true
    ) -> WindowAttributes {
        WindowAttributes(
            role: kAXWindowRole,
            subrole: kAXStandardWindowSubrole,
            minimized: minimized,
            fullscreen: fullscreen,
            minimizedKnown: minimizedKnown
        )
    }

    private static func parkedFrame(_ frame: CGRect, _ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.origin.x + 1 - screen.frame.width,
               y: screen.frame.maxY - 1,
               width: frame.width,
               height: frame.height)
    }

    private static func testWindow(pid: pid_t) -> TrackedWindow {
        TrackedWindow(
            element: AXUIElementCreateApplication(pid),
            pid: pid,
            group: WindowGroupKey(pid: pid, frame: .null)
        )
    }
}
