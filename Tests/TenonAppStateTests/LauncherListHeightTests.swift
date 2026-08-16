import XCTest
@testable import TenonApp

/// The launcher popover ends at its last row. These pin the list-height rule with
/// independent arithmetic (never derived from the constants the view draws with, per
/// T-043's tautology lesson): compact rows are 28 pt, a section separator is a 1-pt
/// rule with 4 pt above and below, the list pads 5 pt top and bottom.
final class LauncherListHeightTests: XCTestCase {
    /// One rule at three inputs, so the arithmetic is stated once and each row says what it
    /// is worth. Every expected value is worked out here rather than derived from the
    /// constants the view draws with, per T-043's tautology lesson.
    func testTheListAsksForExactlyItsRowsSeparatorsAndPaddingUpToTheCeiling() {
        let cases: [(rows: Int, sections: Int, ceiling: CGFloat, expected: CGFloat, why: String)] = [
            (
                10, 3, 900, 308,
                "10·28 + 2·(1+8) + 10 — the user-reported defect: a ten-row menu floating in a near-screen-tall popover"
            ),
            (4, 1, 900, 122, "a single section draws no separator: 4·28 + 10"),
            (100, 1, 320, 320, "more rows than the screen leaves room for: the ceiling wins, scrolling begins"),
        ]
        for (rows, sections, ceiling, expected, why) in cases {
            XCTAssertEqual(
                LauncherListHeight.height(
                    rows: rows,
                    sections: sections,
                    ceiling: ceiling
                ),
                expected,
                why
            )
        }
    }
}
