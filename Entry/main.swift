import AppKit
import ApplicationServices
import PilesCore

private var signalSources: [DispatchSourceSignal] = []

private func installSignalHandler(
    _ signalNumber: Int32,
    queue: DispatchQueue,
    handler: @escaping () -> Void
) {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
    source.setEventHandler(handler: handler)
    source.resume()
    signalSources.append(source)
}

func checkAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private var screenObserver: NSObjectProtocol?

func setupCrashSafety() {
    let terminate = {
        PilesTeardown.shutdown()
        NSApplication.shared.terminate(nil)
    }
    installSignalHandler(SIGTERM, queue: .main, handler: terminate)
    installSignalHandler(SIGINT, queue: .main, handler: terminate)

    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
    ) { _ in
        PilesTeardown.shutdown()
    }

    atexit {
        PilesTeardown.shutdown()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard checkAccessibility() else {
    let alert = NSAlert()
    alert.messageText = "piles requires Accessibility permission"
    alert.informativeText = "grant access in System Settings -> Privacy & Security -> Accessibility, then relaunch piles."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "open System Settings")
    alert.addButton(withTitle: "quit")
    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    exit(1)
}

Config.load()
setupCrashSafety()

let statusBar = StatusBar.shared
let workspace = WorkspaceManager.shared
workspace.bootstrap()

let hotkeys = Hotkeys.shared
hotkeys.start()

IPCServer.shared.start()

let observer = WindowObserver.shared
observer.start()

screenObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { _ in
    WorkspaceManager.shared.handleScreenChange()
}

fputs("piles: running\n", stderr)
app.run()
