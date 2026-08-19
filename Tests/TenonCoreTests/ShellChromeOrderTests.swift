import XCTest

@testable import TenonCore

/// The shell's chrome order as a pure value: which strip each row holds, and what a
/// preferences document written before the choice existed opens as.
///
/// It is asserted here, in `TenonCoreTests`, precisely because it needs no window — the
/// repository's own fitness test for whether a rule is in the right layer.
final class ShellChromeOrderTests: XCTestCase {
    // MARK: - The swap

    func testEachOrderGivesEachStripExactlyOneRowAndNeverTheSameRow() {
        for order in ShellChromeOrder.allCases {
            XCTAssertNotEqual(
                order.titleBarStrip,
                order.footStrip,
                "\(order) draws one strip in both rows, which leaves the other nowhere"
            )
            XCTAssertEqual(
                Set([order.titleBarStrip, order.footStrip]),
                Set(ShellChromeStrip.allCases),
                "\(order) drops a strip: every strip is drawn in exactly one row"
            )
        }
    }

    func testTheDefaultOrderIsWhatTenonHasAlwaysDrawn() {
        XCTAssertEqual(ShellChromeOrder.tabsOnTop.titleBarStrip, .tabs)
        XCTAssertEqual(ShellChromeOrder.tabsOnTop.footStrip, .status)
    }

    func testChoosingTabsOnBottomSendsTheStatusItemsUpInExchange() {
        XCTAssertEqual(ShellChromeOrder.tabsOnBottom.footStrip, .tabs)
        XCTAssertEqual(ShellChromeOrder.tabsOnBottom.titleBarStrip, .status)
    }

    // MARK: - The edge the strip reads

    func testTheTabStripEdgeIsTheRowTheTabStripSitsIn() {
        XCTAssertEqual(ShellChromeOrder.tabsOnTop.tabStripEdge, .top)
        XCTAssertEqual(ShellChromeOrder.tabsOnBottom.tabStripEdge, .bottom)
    }

    func testTheEdgeIsDerivedFromThePlacementSoTheTwoCannotDisagree() {
        for order in ShellChromeOrder.allCases {
            let edgeSaysTabsAreOnTop = order.tabStripEdge == .top
            XCTAssertEqual(
                edgeSaysTabsAreOnTop,
                order.titleBarStrip == .tabs,
                "\(order) reports an edge the placement contradicts"
            )
        }
    }

    // MARK: - The Settings picker

    func testEveryOrderHasALabelForTheSettingsPicker() {
        let labels = ShellChromeOrder.allCases.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count, "two orders offer the same label")
        XCTAssertFalse(labels.contains(where: \.isEmpty))
        XCTAssertEqual(ShellChromeOrder.tabsOnTop.label, "Top")
        XCTAssertEqual(ShellChromeOrder.tabsOnBottom.label, "Bottom")
    }

    // MARK: - Persistence

    func testAPreferencesBlobWrittenBeforeTheOrderExistedOpensWithTabsOnTop() throws {
        // Exactly the document an older Tenon wrote: every key it knew, and no chrome order.
        let older = Data(#"{"sidebarWidth":232,"sidebarVisibleOnLaunch":true}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: older)

        XCTAssertEqual(
            decoded.chromeOrder,
            .tabsOnTop,
            "a document with no chrome order must keep the layout its author was looking at"
        )
    }

    func testAnOrderThisBuildCannotNameCostsThatKeyOnly() throws {
        let future = Data(#"{"chromeOrder":"tabsOnTheLeft","sidebarWidth":180}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: future)

        XCTAssertEqual(decoded.chromeOrder, .tabsOnTop, "an unreadable order falls back")
        XCTAssertEqual(
            decoded.sidebarWidth,
            180,
            "one unreadable word must not take the rest of the document down with it"
        )
    }

    func testChoosingTheOtherOrderSurvivesTheRelaunchRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.chromeOrder = .tabsOnBottom

        let reopened = try JSONDecoder().decode(
            AppPreferences.self,
            from: try JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(reopened.chromeOrder, .tabsOnBottom)
        XCTAssertEqual(reopened, preferences)
    }
}
