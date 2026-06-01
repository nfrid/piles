import AppKit
import Foundation

enum DebugLog {
    private static let environment = ProcessInfo.processInfo.environment
    private static let fileHandle: FileHandle? = {
        guard let path = environment["PILES_DEBUG_LOG"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }()

    static var enabled: Bool {
        fileHandle != nil || environment["PILES_DEBUG"] == "1"
    }

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "piles-debug \(timestamp()) \(message())\n"
        fputs(line, stderr)
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    static func describe(_ window: TrackedWindow) -> String {
        let frame = window.getFrame().map(describe) ?? "nil"
        let title = window.title()
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            ?? ""
        return "pid=\(window.pid) tileable=\(window.isTileable()) fullscreen=\(window.isFullscreen()) frame=\(frame) title=\"\(title)\""
    }

    static func describe(_ windows: [TrackedWindow]) -> String {
        guard !windows.isEmpty else { return "[]" }
        return windows.enumerated()
            .map { index, window in "#\(index){\(describe(window))}" }
            .joined(separator: ", ")
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    private static func timestamp() -> String {
        String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }
}
