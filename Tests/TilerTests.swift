import CoreGraphics
@testable import PilesCore

enum TilerTests {
    static let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let settings = LayoutSettings(masterRatio: 0.55)

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

        do {
            let frames = Tiler.calculateFrames(count: 0, screen: screen, layout: .tile, settings: settings)
            check(frames.isEmpty, "empty returns empty")
        }

        do {
            let frames = Tiler.calculateFrames(count: 1, screen: screen, layout: .tile, settings: settings)
            check(frames.count == 1, "single window count")
            check(frames[0] == screen, "single window covers screen")
        }

        do {
            let frames = Tiler.calculateFrames(count: 2, screen: screen, layout: .tile, settings: settings)
            let masterWidth = floor(1920 * settings.masterRatio)
            check(frames.count == 2, "two windows count")
            check(frames[0].width == masterWidth, "master width")
            check(frames[1].width == 1920 - masterWidth, "stack width")
            check(frames[0].height == 1080, "master height")
            check(frames[1].height == 1080, "stack height")
        }

        do {
            let frames = Tiler.calculateFrames(count: 3, screen: screen, layout: .tile, settings: settings)
            let stackHeight = floor(1080.0 / 2.0)
            check(frames.count == 3, "three windows count")
            check(frames[1].height == stackHeight, "first stack height")
            check(frames[2].height == 1080 - stackHeight, "last stack height")
        }

        for count in 4...8 {
            let frames = Tiler.calculateFrames(count: count, screen: screen, layout: .tile, settings: settings)
            let stack = frames.dropFirst().sorted { $0.origin.y < $1.origin.y }
            for i in 1..<stack.count {
                let prevBottom = stack[i - 1].origin.y + stack[i - 1].height
                let gap = abs(stack[i].origin.y - prevBottom)
                check(gap < 0.001, "contiguous y at count=\(count) i=\(i)")
            }
        }

        for count in 1...8 {
            let frames = Tiler.calculateFrames(count: count, screen: screen, layout: .tile, settings: settings)
            let totalArea = frames.reduce(0.0) { $0 + $1.width * $1.height }
            let screenArea = screen.width * screen.height
            check(abs(totalArea - screenArea) < 1.0, "area coverage at count=\(count)")
        }

        do {
            let offset = CGRect(x: 100, y: 50, width: 1920, height: 1080)
            let frames = Tiler.calculateFrames(count: 2, screen: offset, layout: .tile, settings: settings)
            check(frames[0].origin.x == 100, "offset master x")
            check(frames[0].origin.y == 50, "offset master y")
            check(frames[1].origin.x == 100 + floor(1920 * settings.masterRatio), "offset stack x")
            check(frames[1].origin.y == 50, "offset stack y")
        }

        do {
            let frames = Tiler.calculateFrames(count: 5, screen: screen, layout: .monocle, settings: settings)
            check(frames.count == 5, "monocle count")
            for f in frames {
                check(f == screen, "monocle frame == screen")
            }
        }

        do {
            let frames = Tiler.calculateFrames(
                count: 2,
                screen: screen,
                layout: .tile,
                settings: LayoutSettings(masterRatio: 0.25)
            )
            check(frames[0].width == 480, "explicit master ratio controls master width")
            check(frames[1].width == 1440, "explicit master ratio controls stack width")
        }

        do {
            let frame = CGRect(x: 200, y: 120, width: 640, height: 480)
            let restored = Monitor.framePreservingSizeInsideScreen(frame, screen: screen)
            check(restored == frame, "restore keeps visible frame unchanged")
        }

        do {
            let frame = CGRect(x: -240, y: -80, width: 640, height: 480)
            let restored = Monitor.framePreservingSizeInsideScreen(frame, screen: screen)
            check(restored.origin == .zero, "restore clamps frame above and left of screen")
            check(restored.size == frame.size, "restore preserves size when clamping top-left")
        }

        do {
            let frame = CGRect(x: 1800, y: 900, width: 640, height: 480)
            let restored = Monitor.framePreservingSizeInsideScreen(frame, screen: screen)
            check(restored.origin.x == 1280, "restore clamps frame right edge")
            check(restored.origin.y == 600, "restore clamps frame bottom edge")
            check(restored.size == frame.size, "restore preserves size when clamping bottom-right")
        }

        do {
            let frame = CGRect(x: -1920, y: 1079, width: 960, height: 540)
            let restored = Monitor.framePreservingSizeInsideScreen(frame, screen: screen)
            check(restored.origin.x == 0, "restore brings hidden workspace window back to screen x")
            check(restored.origin.y == 540, "restore brings hidden workspace window back to screen y")
            check(restored.size == frame.size, "restore keeps hidden workspace window size")
        }

        return (passed, failed)
    }
}
