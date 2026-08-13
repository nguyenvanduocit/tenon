import Foundation
import XCTest

@testable import TenonCore

/// The pure half of T-096: which gap a pointer means, which array index that gap becomes,
/// and which dragged strings are allowed to become a move at all.
final class TabReorderTests: XCTestCase {
    /// Four 100-wide chips separated by nothing, so a midpoint is at 50, 150, 250, 350.
    private func strip(_ ids: [UUID]) -> [TabChipExtent] {
        ids.enumerated().map { index, id in
            TabChipExtent(
                id: id,
                minX: Double(index) * 100,
                maxX: Double(index) * 100 + 100
            )
        }
    }

    // MARK: - Which gap the pointer means

    func testPointerBeforeTheFirstChipMeansTheLeadingGap() {
        let ids = (0 ..< 4).map { _ in UUID() }
        XCTAssertEqual(TabReorder.insertionIndex(at: -40, chips: strip(ids)), 0)
        XCTAssertEqual(TabReorder.insertionIndex(at: 0, chips: strip(ids)), 0)
        XCTAssertEqual(TabReorder.insertionIndex(at: 49, chips: strip(ids)), 0)
    }

    func testPointerPastTheLastMidpointMeansTheTrailingGap() {
        let ids = (0 ..< 4).map { _ in UUID() }
        XCTAssertEqual(TabReorder.insertionIndex(at: 351, chips: strip(ids)), 4)
        XCTAssertEqual(TabReorder.insertionIndex(at: 4_000, chips: strip(ids)), 4)
    }

    /// Every point on the strip belongs to exactly one gap. A rule that measured the space
    /// *between* chips instead would leave the caret undefined while the pointer is over a
    /// chip, which is most of the strip.
    func testEveryPointOnTheStripBelongsToExactlyOneGap() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        for x in stride(from: -50.0, through: 450.0, by: 1) {
            let index = TabReorder.insertionIndex(at: x, chips: chips)
            XCTAssertGreaterThanOrEqual(index, 0, "gap at x=\(x)")
            XCTAssertLessThanOrEqual(index, chips.count, "gap at x=\(x)")
        }
        // Monotone: sweeping right never walks the caret backwards.
        var previous = 0
        for x in stride(from: -50.0, through: 450.0, by: 1) {
            let index = TabReorder.insertionIndex(at: x, chips: chips)
            XCTAssertGreaterThanOrEqual(index, previous, "caret went backwards at x=\(x)")
            previous = index
        }
    }

    func testAnEmptyStripHasOneGap() {
        XCTAssertEqual(TabReorder.insertionIndex(at: 120, chips: []), 0)
    }

    // MARK: - Which array index that gap becomes

    func testMovingForwardLandsOneLeftOfTheBoundary() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        // First tab dropped in the last gap becomes the last tab, not index 4.
        XCTAssertEqual(
            TabReorder.destination(forTab: ids[0], insertingAt: 4, chips: chips),
            3
        )
        XCTAssertEqual(
            TabReorder.destination(forTab: ids[0], insertingAt: 2, chips: chips),
            1
        )
    }

    func testMovingBackwardLandsOnTheBoundaryItself() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        XCTAssertEqual(
            TabReorder.destination(forTab: ids[3], insertingAt: 0, chips: chips),
            0
        )
        XCTAssertEqual(
            TabReorder.destination(forTab: ids[3], insertingAt: 2, chips: chips),
            2
        )
    }

    /// Both gaps either side of a tab are the position it is already in.
    func testDroppingOnEitherSideOfItselfIsANoOp() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        XCTAssertNil(TabReorder.destination(forTab: ids[2], insertingAt: 2, chips: chips))
        XCTAssertNil(TabReorder.destination(forTab: ids[2], insertingAt: 3, chips: chips))
    }

    func testABoundaryOutsideTheStripIsRefused() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        XCTAssertNil(TabReorder.destination(forTab: ids[1], insertingAt: -1, chips: chips))
        XCTAssertNil(TabReorder.destination(forTab: ids[1], insertingAt: 5, chips: chips))
    }

    func testATabThisStripIsNotShowingIsRefused() {
        let ids = (0 ..< 4).map { _ in UUID() }
        XCTAssertNil(
            TabReorder.destination(forTab: UUID(), insertingAt: 2, chips: strip(ids))
        )
    }

    /// Sweeping one tab across every gap in a four-tab strip and applying the answer must
    /// reproduce exactly the orders a person can reach, and no others.
    func testEveryGapProducesTheOrderAPersonSees() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        var reached: [[UUID]] = []
        for insertion in 0 ... 4 {
            guard let destination = TabReorder.destination(
                forTab: ids[1],
                insertingAt: insertion,
                chips: chips
            ) else { continue }
            var order = ids
            order.remove(at: 1)
            // Assert the bound rather than trapping on it. `Workspace.moveTab` refuses an
            // out-of-range destination, so a rule that produced one would fail there — but
            // an unguarded `insert` here would crash the whole shared test run instead of
            // reporting which rule broke.
            guard destination >= 0, destination <= order.count else {
                XCTFail("destination \(destination) is outside \(order.count + 1) positions")
                continue
            }
            order.insert(ids[1], at: destination)
            reached.append(order)
        }
        XCTAssertEqual(
            reached,
            [
                [ids[1], ids[0], ids[2], ids[3]],
                [ids[0], ids[2], ids[1], ids[3]],
                [ids[0], ids[2], ids[3], ids[1]],
            ]
        )
    }

    // MARK: - What VoiceOver says

    func testTheAnnouncementCountsFromOne() {
        XCTAssertEqual(
            TabReorder.announcement(title: "build", movedTo: 0, of: 4),
            "Moved build to tab 1 of 4"
        )
        XCTAssertEqual(
            TabReorder.announcement(title: "build", movedTo: 3, of: 4),
            "Moved build to tab 4 of 4"
        )
    }

    func testTheSpokenPositionCarriesSelectionWithoutReplacingIt() {
        XCTAssertEqual(TabReorder.spokenPosition(1, of: 3, isActive: false), "tab 2 of 3")
        XCTAssertEqual(
            TabReorder.spokenPosition(1, of: 3, isActive: true),
            "tab 2 of 3, active"
        )
    }

    // MARK: - Which tab the press picked up

    func testAPressOnAChipPicksUpThatTab() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        XCTAssertEqual(TabReorder.tab(at: 0, chips: chips), ids[0])
        XCTAssertEqual(TabReorder.tab(at: 130, chips: chips), ids[1])
        XCTAssertEqual(TabReorder.tab(at: 399, chips: chips), ids[3])
    }

    /// The `+` button and the empty stretch past the last chip live in the same row. A
    /// press there is not a tab being picked up, so the strip must not invent one.
    func testAPressOnNoChipPicksUpNothing() {
        let ids = (0 ..< 4).map { _ in UUID() }
        XCTAssertNil(TabReorder.tab(at: -20, chips: strip(ids)))
        XCTAssertNil(TabReorder.tab(at: 620, chips: strip(ids)))
        XCTAssertNil(TabReorder.tab(at: 10, chips: []))
    }

    // MARK: - Which releases are aimed at the strip at all

    func testAReleaseInsideTheStripBandIsADrop() {
        XCTAssertTrue(TabReorder.admitsDrop(pointerY: 0, stripHeight: 26))
        XCTAssertTrue(TabReorder.admitsDrop(pointerY: 13, stripHeight: 26))
        XCTAssertTrue(TabReorder.admitsDrop(pointerY: 26, stripHeight: 26))
    }

    /// Vertical distance is the one cancel a pointer drag can express: a tab pulled down
    /// into the canvas is a person changing their mind.
    func testAReleaseWellOutsideTheStripIsNotADrop() {
        XCTAssertFalse(
            TabReorder.admitsDrop(pointerY: 26 + TabReorder.dropSlack + 1, stripHeight: 26)
        )
        XCTAssertFalse(
            TabReorder.admitsDrop(pointerY: -TabReorder.dropSlack - 1, stripHeight: 26)
        )
        XCTAssertFalse(TabReorder.admitsDrop(pointerY: 600, stripHeight: 26))
    }

    // MARK: - What a click on the strip means (T-101)

    /// The strip owns its whole primary-button stream, because a press it leaves to the
    /// window server moves the window instead of the tab. That makes the click a rule too.
    func testAPressOnAChipBodySelectsThatTab() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        let closes = [ids[1]: 176.0 ... 200.0]

        XCTAssertEqual(
            TabReorder.press(at: 120, chips: chips, closeControls: closes),
            .select(ids[1])
        )
        XCTAssertEqual(
            TabReorder.press(at: 175, chips: chips, closeControls: closes),
            .select(ids[1]),
            "one point short of the close control is still the tab"
        )
    }

    func testAPressOnTheCloseControlClosesThatTab() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let chips = strip(ids)
        let closes = [ids[1]: 176.0 ... 200.0, ids[2]: 276.0 ... 300.0]

        XCTAssertEqual(
            TabReorder.press(at: 176, chips: chips, closeControls: closes),
            .close(ids[1])
        )
        XCTAssertEqual(
            TabReorder.press(at: 288, chips: chips, closeControls: closes),
            .close(ids[2])
        )
    }

    /// A chip that draws no ✕ — the last tab in the strip — reports no close control, and
    /// the same press must select it rather than reaching for a neighbour's rectangle.
    func testAChipWithNoCloseControlIsAlwaysSelected() {
        let ids = (0 ..< 2).map { _ in UUID() }
        let chips = strip(ids)

        XCTAssertEqual(
            TabReorder.press(at: 195, chips: chips, closeControls: [:]),
            .select(ids[1])
        )
    }

    func testAPressPastTheLastChipMeansNoTab() {
        let ids = (0 ..< 2).map { _ in UUID() }
        let chips = strip(ids)

        XCTAssertNil(TabReorder.press(at: 260, chips: chips, closeControls: [:]))
        XCTAssertNil(TabReorder.press(at: -3, chips: chips, closeControls: [:]))
        XCTAssertNil(TabReorder.press(at: 40, chips: [], closeControls: [:]))
    }

    // MARK: - The loop a live reorder closes

    /// A live reorder applies these two rules on every pointer move, against chips that were
    /// just laid out again — so the rule's own output changes the geometry its next input is
    /// measured against. That feedback loop is the one thing a preview drawn *beside* the
    /// chips never had, and it is where a plausible rule fails: swapping on overlap rather
    /// than on midpoints makes two chips of different widths trade places forever under a
    /// pointer that has stopped moving.
    ///
    /// This sweeps a pointer across deliberately uneven chips, re-laying the row after every
    /// move exactly as the strip does, and asks for the property that makes the loop settle:
    /// the tab travels only the way the pointer is travelling, and it ends where the pointer
    /// ended.
    func testASweepAcrossUnevenChipsMovesTheTabOnlyTheWayThePointerIsGoing() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let widths = [ids[0]: 60.0, ids[1]: 220.0, ids[2]: 90.0, ids[3]: 150.0]

        func laidOut(_ order: [UUID]) -> [TabChipExtent] {
            var x = 0.0
            return order.map { id in
                let extent = TabChipExtent(id: id, minX: x, maxX: x + widths[id]!)
                x = extent.maxX + 3
                return extent
            }
        }

        var order = ids
        var reached = 0
        for pointerX in stride(from: 0.0, through: 600.0, by: 1) {
            let chips = laidOut(order)
            guard let destination = TabReorder.destination(
                forTab: ids[0],
                insertingAt: TabReorder.insertionIndex(at: pointerX, chips: chips),
                chips: chips
            ) else { continue }

            XCTAssertGreaterThan(
                destination,
                reached,
                "a rightward pointer walked the dragged tab back to \(destination) at x=\(pointerX)"
            )
            order.remove(at: order.firstIndex(of: ids[0])!)
            order.insert(ids[0], at: destination)
            reached = destination
        }

        XCTAssertEqual(
            order,
            [ids[1], ids[2], ids[3], ids[0]],
            "a sweep to the end of the strip leaves the dragged tab last"
        )
    }
}
