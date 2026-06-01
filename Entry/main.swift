import AppKit
import ApplicationServices
import PilesCore

private var signalSources: [DispatchSourceSignal] = []

func checkAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func setupCrashSafety() {
    let restore = {
        WorkspaceManager.shared.restoreAllWindows()
    }

    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler {
        restore()
        NSApplication.shared.terminate(nil)
    }
    termSource.resume()
    signalSources.append(termSource)

    signal(SIGINT, SIG_IGN)
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler {
        restore()
        NSApplication.shared.terminate(nil)
    }
    intSource.resume()
    signalSources.append(intSource)

    atexit {
        WorkspaceManager.shared.restoreAllWindows()
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

let observer = WindowObserver.shared
observer.start()

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { _ in
    WorkspaceManager.shared.handleScreenChange()
}

fputs("piles: running\n", stderr)
app.run()
