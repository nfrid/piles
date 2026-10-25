import Darwin
@testable import PilesCore

enum WindowTitleTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else {
                fputs("fail WindowTitleTests: \(message)\n", stderr)
                failed += 1
            }
        }

        check(TrackedWindow.normalizedDisplayTitle("\u{180E}Firefox") == "Firefox", "strips leading MVS")
        check(TrackedWindow.normalizedDisplayTitle("\u{180E}\u{200D}Firefox") == "Firefox", "strips adjacent MVS and ZWJ")
        check(TrackedWindow.normalizedDisplayTitle("\u{180E}\u{200D}\u{180E}Firefox") == "Firefox", "strips only adjacent prefix marker scalars")
        check(TrackedWindow.normalizedDisplayTitle("\u{180E}\u{200D}\u{200D}Firefox") == "Firefox", "strips adjacent scalars even when joiners form one grapheme")
        check(TrackedWindow.normalizedDisplayTitle("\u{180E}").isEmpty, "marker only becomes empty for fallback")
        check(TrackedWindow.normalizedDisplayTitle("  \u{180E}  Firefox  ") == "Firefox", "trims whitespace around marker title")
        check(TrackedWindow.normalizedDisplayTitle("  ").isEmpty, "whitespace title becomes empty for fallback")
        check(TrackedWindow.normalizedDisplayTitle("日本語のタイトル") == "日本語のタイトル", "preserves multilingual title")
        check(TrackedWindow.normalizedDisplayTitle("👩‍💻 😊") == "👩‍💻 😊", "preserves emoji sequences")
        check(TrackedWindow.normalizedDisplayTitle("A\u{180E}B\u{200D}C") == "A\u{180E}B\u{200D}C", "preserves interior markers")
        check(TrackedWindow.normalizedDisplayTitle("\u{200D}Title") == "\u{200D}Title", "preserves leading ZWJ without marker")
        return (passed, failed)
    }
}
