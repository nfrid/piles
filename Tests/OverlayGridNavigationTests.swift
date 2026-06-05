import Darwin
@testable import PilesCore

enum OverlayGridNavigationTests {
    private static let columns = OverlayMetrics.gridColumns

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

        check(
            OverlayGridNavigation.moveHorizontal(selected: 0, delta: 1, count: 0, columns: columns) == nil,
            "horizontal move with empty count returns nil"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 0, delta: 1, count: 0, columns: columns) == nil,
            "row move with empty count returns nil"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 4, delta: 1, count: 4, columns: columns) == nil,
            "horizontal move rejects out-of-range selection"
        )
        check(
            OverlayGridNavigation.moveRow(selected: -1, delta: 1, count: 4, columns: columns) == nil,
            "row move rejects negative selection"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 0, delta: 1, count: 4, columns: 0) == nil,
            "horizontal move rejects zero columns"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 0, delta: 1, count: 4, columns: 0) == nil,
            "row move rejects zero columns"
        )

        var selected = 2
        check(
            !OverlayGridSelection.moveHorizontal(selected: &selected, delta: 1, count: 0),
            "selection wrapper horizontal rejects empty count"
        )
        check(selected == 2, "selection wrapper horizontal leaves index unchanged on empty count")
        check(
            !OverlayGridSelection.moveRow(selected: &selected, delta: 1, count: 0),
            "selection wrapper row rejects empty count"
        )
        check(selected == 2, "selection wrapper row leaves index unchanged on empty count")

        check(
            OverlayGridNavigation.moveHorizontal(selected: 0, delta: 1, count: 6, columns: columns) == 1,
            "horizontal move advances within full row"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 1, delta: -1, count: 6, columns: columns) == 0,
            "horizontal move retreats within full row"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 2, delta: 1, count: 6, columns: columns) == 0,
            "horizontal move wraps within full row"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 0, delta: -1, count: 6, columns: columns) == 2,
            "horizontal move wraps backward within full row"
        )

        check(
            OverlayGridNavigation.moveHorizontal(selected: 3, delta: 1, count: 4, columns: columns) == 3,
            "single-slot last row wraps to itself moving right"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 3, delta: -1, count: 4, columns: columns) == 3,
            "single-slot last row wraps to itself moving left"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 3, delta: 1, count: 5, columns: columns) == 4,
            "partial last row moves right within row"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 4, delta: -1, count: 5, columns: columns) == 3,
            "partial last row moves left within row"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 4, delta: 1, count: 5, columns: columns) == 3,
            "partial last row wraps right at row end"
        )
        check(
            OverlayGridNavigation.moveHorizontal(selected: 6, delta: 1, count: 7, columns: columns) == 6,
            "one-item final row stays put moving right"
        )

        check(
            OverlayGridNavigation.moveRow(selected: 0, delta: 1, count: 6, columns: columns) == 3,
            "row move down advances by one row"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 3, delta: -1, count: 6, columns: columns) == 0,
            "row move up retreats by one row"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 4, delta: 1, count: 6, columns: columns) == 1,
            "row move wraps from last partial row to top"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 0, delta: -1, count: 4, columns: columns) == 1,
            "row move wraps from first row using flat index step"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 2, delta: 1, count: 7, columns: columns) == 5,
            "row move from middle of first row lands in second row"
        )
        check(
            OverlayGridNavigation.moveRow(selected: 1, delta: -3, count: 7, columns: columns) == 6,
            "row move normalizes large negative deltas"
        )

        selected = 1
        check(
            OverlayGridSelection.moveHorizontal(selected: &selected, delta: 1, count: 6),
            "selection wrapper horizontal reports success"
        )
        check(selected == 2, "selection wrapper horizontal updates selected index")
        check(
            OverlayGridSelection.moveRow(selected: &selected, delta: 1, count: 6),
            "selection wrapper row reports success"
        )
        check(selected == 5, "selection wrapper row updates selected index")

        return (passed, failed)
    }
}
