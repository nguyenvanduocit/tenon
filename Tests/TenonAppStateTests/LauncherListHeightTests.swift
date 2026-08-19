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

    // MARK: - The room the popover actually has

    /// A screen 1000 pt tall, an anchor 40 pt tall sitting 100 pt off its bottom edge, and
    /// 120 pt of popover chrome. Downward there are 100 pt of screen below the anchor, so the
    /// ceiling is the 140-pt floor; upward there are 1000 − 140 = 860, less chrome.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 1000)

    func testAListOpeningUpwardIsSizedForTheRoomAboveItsAnchor() {
        let anchor = CGRect(x: 200, y: 100, width: 300, height: 40)

        XCTAssertEqual(
            LauncherListHeight.ceiling(
                anchor: anchor,
                opening: .above,
                visibleFrame: screen,
                chrome: 120
            ),
            740,
            "1000 − 140 (the anchor's top) − 120 of chrome"
        )
    }

    func testAListOpeningDownwardIsSizedForTheRoomBelowItsAnchor() {
        let anchor = CGRect(x: 200, y: 800, width: 300, height: 40)

        XCTAssertEqual(
            LauncherListHeight.ceiling(
                anchor: anchor,
                opening: .below,
                visibleFrame: screen,
                chrome: 120
            ),
            680,
            "800 (the anchor's bottom) − 0 (the screen's bottom) − 120 of chrome"
        )
    }

    /// The defect the direction parameter exists to prevent: an anchor near the bottom of
    /// the screen has almost nothing below it, and a rule that measured from the window's
    /// top edge instead would hand the list a whole screen it cannot use.
    func testAnAnchorNearTheScreenFootClaimsNoRoomBelowItThatDoesNotExist() {
        let anchor = CGRect(x: 200, y: 30, width: 300, height: 34)

        XCTAssertEqual(
            LauncherListHeight.ceiling(
                anchor: anchor,
                opening: .below,
                visibleFrame: screen,
                chrome: 120
            ),
            140,
            "30 pt of screen below the anchor is less than the floor, so the floor stands"
        )
    }

    /// A screen whose origin is not zero — a second display, or the menu bar's inset. The
    /// room is measured against the visible frame's own edges, never against zero.
    func testTheRoomIsMeasuredAgainstTheVisibleFrameNotTheOrigin() {
        let secondary = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        let anchor = CGRect(x: -1700, y: 200, width: 300, height: 40)

        XCTAssertEqual(
            LauncherListHeight.ceiling(
                anchor: anchor,
                opening: .below,
                visibleFrame: secondary,
                chrome: 100
            ),
            500,
            "200 − (−400) − 100"
        )
        XCTAssertEqual(
            LauncherListHeight.ceiling(
                anchor: anchor,
                opening: .above,
                visibleFrame: secondary,
                chrome: 100
            ),
            340,
            "680 (the frame's top) − 240 (the anchor's top) − 100"
        )
    }

    // MARK: - Which side an anchor with no fixed position should open toward

    /// The bug a live screenshot reported: a right-click low on a tall canvas still opened
    /// the popover as if it had room below, because the caller always said `.below` — this is
    /// the room check that should have decided it instead.
    func testAnAnchorLowOnTheScreenOpensUpwardWhereTheRoomActuallyIs() {
        let anchor = CGRect(x: 200, y: 30, width: 1, height: 1)

        XCTAssertEqual(
            LauncherListHeight.opening(for: anchor, in: screen),
            .above,
            "30 pt below the anchor vs. 969 pt above it"
        )
    }

    func testAnAnchorHighOnTheScreenOpensDownwardWhereTheRoomActuallyIs() {
        let anchor = CGRect(x: 200, y: 900, width: 1, height: 1)

        XCTAssertEqual(
            LauncherListHeight.opening(for: anchor, in: screen),
            .below,
            "900 pt below the anchor vs. 99 pt above it"
        )
    }

    /// Exactly centered: the tie goes to `.below`, `ceiling`'s own default direction.
    func testATiedAnchorOpensDownward() {
        let anchor = CGRect(x: 200, y: 500, width: 1, height: 1)

        XCTAssertEqual(LauncherListHeight.opening(for: anchor, in: screen), .below)
    }
}
