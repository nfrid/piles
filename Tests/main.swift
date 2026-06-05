import Dispatch

fputs("running tiler tests...\n", stderr)
let (p1, f1) = TilerTests.runAll()

fputs("running window group tests...\n", stderr)
let (p3, f3) = WindowGroupTests.runAll()

fputs("running monitor state tests...\n", stderr)
let (p7, f7) = MonitorStateTests.runAll()

fputs("running monitor tests...\n", stderr)
let (p8, f8) = MonitorTests.runAll()

fputs("running config tests...\n", stderr)
let (p4, f4) = ConfigTests.runAll()

fputs("running hotkey tests...\n", stderr)
let (p5, f5) = HotkeyTests.runAll()

fputs("running ipc command tests...\n", stderr)
let (p6, f6) = IPCCommandTests.runAll()

fputs("running focus follow suppression tests...\n", stderr)
let (p9, f9) = FocusFollowSuppressionTests.runAll()

fputs("running performance tests...\n", stderr)
let (p2, f2) = TilerPerformanceTests.runAll()

let passed = p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
let failed = f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9

fputs("\n\(passed) passed, \(failed) failed\n", stderr)

if failed > 0 {
    exit(1)
}
