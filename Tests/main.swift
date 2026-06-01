import Dispatch

fputs("running tiler tests...\n", stderr)
let (p1, f1) = TilerTests.runAll()

fputs("running window group tests...\n", stderr)
let (p3, f3) = WindowGroupTests.runAll()

fputs("running config tests...\n", stderr)
let (p4, f4) = ConfigTests.runAll()

fputs("running performance tests...\n", stderr)
let (p2, f2) = TilerPerformanceTests.runAll()

let passed = p1 + p2 + p3 + p4
let failed = f1 + f2 + f3 + f4

fputs("\n\(passed) passed, \(failed) failed\n", stderr)

if failed > 0 {
    exit(1)
}
