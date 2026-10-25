import Dispatch

fputs("running ax client tests...\n", stderr)
let (p13, f13) = AXClientTests.runAll()

fputs("running tiler tests...\n", stderr)
let (p1, f1) = TilerTests.runAll()

fputs("running window group tests...\n", stderr)
let (p3, f3) = WindowGroupTests.runAll()

fputs("running monitor state tests...\n", stderr)
let (p7, f7) = MonitorStateTests.runAll()

fputs("running monitor tests...\n", stderr)
let (p8, f8) = MonitorTests.runAll()

fputs("running window recovery tests...\n", stderr)
let (p16, f16) = WindowRecoveryTests.runAll()

fputs("running window rescan tests...\n", stderr)
let (p18, f18) = WindowRescanTests.runAll()

fputs("running window title tests...\n", stderr)
let (p19, f19) = WindowTitleTests.runAll()

fputs("running window mode tests...\n", stderr)
let (p20, f20) = WindowModeTests.runAll()

fputs("running config tests...\n", stderr)
let (p4, f4) = ConfigTests.runAll()

fputs("running hotkey tests...\n", stderr)
let (p5, f5) = HotkeyTests.runAll()

fputs("running input scheduling tests...\n", stderr)
let (p14, f14) = InputSchedulingTests.runAll()

fputs("running window observer tests...\n", stderr)
let (p15, f15) = WindowObserverTests.runAll()

fputs("running ipc command tests...\n", stderr)
let (p6, f6) = IPCCommandTests.runAll()

fputs("running CLI integration tests...\n", stderr)
let (p17, f17) = CLITests.runAll()

fputs("running ipc server tests...\n", stderr)
let (p11, f11) = IPCServerTests.runAll()

fputs("running focus follow suppression tests...\n", stderr)
let (p9, f9) = FocusFollowSuppressionTests.runAll()

fputs("running overlay grid navigation tests...\n", stderr)
let (p10, f10) = OverlayGridNavigationTests.runAll()

fputs("running monocle bar tests...\n", stderr)
let (p12, f12) = MonocleBarTests.runAll()

fputs("running performance tests...\n", stderr)
let (p2, f2) = TilerPerformanceTests.runAll()

let passed = p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17 + p18 + p19 + p20
let failed = f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9 + f10 + f11 + f12 + f13 + f14 + f15 + f16 + f17 + f18 + f19 + f20

fputs("\n\(passed) passed, \(failed) failed\n", stderr)

if failed > 0 {
    exit(1)
}
