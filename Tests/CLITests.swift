import Foundation

enum CLITests {
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
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("piles-ctl")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            check(false, "CLI integration tests require piles-ctl beside piles-tests; run make test")
            return (passed, failed)
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piles-cli-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config with spaces.toml")
            try "workspace_count = 3\n".write(to: file, atomically: true, encoding: .utf8)
            let valid = try run(executable, ["config", "validate", file.path])
            check(valid.status == 0 && valid.output.contains("valid"), "CLI validates a config path containing spaces without a running daemon")

            try "workspace_count =\n".write(to: file, atomically: true, encoding: .utf8)
            let syntax = try run(executable, ["config", "validate", file.path])
            check(syntax.status == 1 && syntax.error.contains("parse error"), "CLI reports invalid syntax with exit code 1")
            try "master_ratio = 0\n".write(to: file, atomically: true, encoding: .utf8)
            let fallback = try run(executable, ["config", "validate", file.path])
            check(fallback.status == 1 && fallback.error.contains("master_ratio"), "CLI treats fallback diagnostics as validation failures")
            try "workspace_cout = 3\n".write(to: file, atomically: true, encoding: .utf8)
            let unknown = try run(executable, ["config", "validate", file.path])
            check(unknown.status == 1 && unknown.error.contains("unknown key"), "CLI rejects unknown configuration keys")
            let missing = try run(executable, ["config", "validate", directory.appendingPathComponent("missing.toml").path])
            check(missing.status == 1 && !missing.error.isEmpty, "CLI reports a missing explicit config file")
            try Data([0xFF]).write(to: file)
            check(try run(executable, ["config", "validate", file.path]).status == 1, "CLI rejects unreadable config text")
            check(try run(executable, ["config", "validate", file.path, "extra"]).status == 2, "CLI rejects extra validation arguments")
            check(try run(executable, ["--socket", "unused", "config", "validate", file.path]).status == 2,
                  "local config validation does not silently ignore a socket override")

            // The rescue launcher runs only this stub, never the actual window manager.
            let bin = directory.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let copiedCLI = bin.appendingPathComponent("piles-ctl")
            try FileManager.default.copyItem(at: executable, to: copiedCLI)
            let companion = bin.appendingPathComponent("piles")
            let argumentsFile = directory.appendingPathComponent("rescue-arguments")
            try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$PILES_TEST_ARGUMENTS\"\nprintf 'rescue stub\\n'\nexit 7\n"
                .write(to: companion, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: companion.path)
            var environment = ProcessInfo.processInfo.environment
            environment["PILES_TEST_ARGUMENTS"] = argumentsFile.path
            let rescued = try run(copiedCLI, ["rescue"], environment: environment)
            check(rescued.status == 7 && rescued.output.contains("rescue stub"), "CLI propagates the rescue companion's result and output")
            check(try String(contentsOf: argumentsFile, encoding: .utf8) == "--rescue\n", "CLI starts only the companion's one-shot rescue mode")

            let links = directory.appendingPathComponent("links")
            try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
            let symlink = links.appendingPathComponent("piles-ctl")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: copiedCLI)
            check(try run(symlink, ["rescue"], environment: environment).status == 7,
                  "symlinked CLI finds the companion beside the real executable")
            try FileManager.default.removeItem(at: argumentsFile)
            check(try run(copiedCLI, ["rescue", "extra"], environment: environment).status == 2
                  && !FileManager.default.fileExists(atPath: argumentsFile.path), "invalid rescue arguments never launch the companion")
            check(try run(copiedCLI, ["--socket", "unused", "rescue"], environment: environment).status == 2
                  && !FileManager.default.fileExists(atPath: argumentsFile.path), "rescue refuses a misleading socket override")
            try FileManager.default.removeItem(at: companion)
            let unavailable = try run(copiedCLI, ["rescue"], environment: environment)
            check(unavailable.status == 1 && !unavailable.error.isEmpty, "CLI reports a missing rescue companion")
        } catch {
            check(false, "CLI integration tests failed: \(error)")
        }
        return (passed, failed)
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
