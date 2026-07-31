import XCTest
@testable import TenonApp

/// The launcher popover ends at its last row. These pin the list-height rule with
/// independent arithmetic (never derived from the constants the view draws with, per
/// T-043's tautology lesson): compact rows are 28 pt, a section separator is a 1-pt
/// rule with 4 pt above and below, the list pads 5 pt top and bottom.
final class LauncherListHeightTests: XCTestCase {
    /// Ten rows in three sections under a tall ceiling: 10·28 + 2·(1+8) + 10 = 308 —
    /// not the ceiling. This is the user-reported defect: a ten-row menu floating in a
    /// near-screen-tall popover.
    func testTheListAsksForExactlyItsRowsSeparatorsAndPadding() {
        XCTAssertEqual(
            LauncherListHeight.height(rows: 10, sections: 3, ceiling: 900),
            308
        )
    }

    /// A single section draws no separator: 4·28 + 10 = 122.
    func testASingleSectionContributesNoSeparators() {
        XCTAssertEqual(
            LauncherListHeight.height(rows: 4, sections: 1, ceiling: 900),
            122
        )
    }

    /// More rows than the screen leaves room for: the ceiling wins, scrolling begins.
    func testContentTallerThanTheCeilingClampsToTheCeiling() {
        XCTAssertEqual(
            LauncherListHeight.height(rows: 100, sections: 1, ceiling: 320),
            320
        )
    }
}
