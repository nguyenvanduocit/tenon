import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-093. What VoiceOver says about a pane must be about the pane, not about the test suite.
///
/// The spoken value used to be `slot=<uuid>;rect=0,1,2,1` — a UUID read out character by
/// character, followed by four numbers with no unit. The machine contract still exists; it
/// moved to the accessibility identifier, which is never spoken.
@MainActor
final class SlotAccessibilityValueTests: XCTestCase {
    func testTheSpokenValueDescribesWhereThePaneIs() {
        let value = SpatialSlotCardView.spokenPosition(
            of: GridRect(x: 1, y: 0, width: 1, height: 1)
        )

        XCTAssertEqual(value, "Column 2, row 1")
    }

    func testASpanningPaneSaysHowMuchOfTheGridItCovers() {
        let value = SpatialSlotCardView.spokenPosition(
            of: GridRect(x: 0, y: 2, width: 2, height: 3)
        )

        XCTAssertEqual(value, "Column 1, row 3, 2 by 3 cells")
    }

    /// The regression this guards: no identifier, no raw geometry, nothing a person would have
    /// to decode. If any of these appear in the spoken string again, VoiceOver is back to
    /// reading a UUID aloud.
    func testTheSpokenValueCarriesNoMachineMetadata() {
        let value = SpatialSlotCardView.spokenPosition(
            of: GridRect(x: 3, y: 4, width: 2, height: 2)
        )

        for token in ["slot=", "rect=", "-", ";"] {
            XCTAssertFalse(
                value.contains(token),
                "spoken value must not contain \(token): \(value)"
            )
        }
    }

    /// T-127. Saying the same thing again costs the same as saying it the first time.
    ///
    /// `applyFrames` calls this for every displayed card — from `layout()`, from every
    /// `configure`, from `drag(to:)` on every `.leftMouseDragged`, and up to three times from
    /// `synchronizeWithStore` at the end of a gesture. Unlike the `card.frame` assignment
    /// beside it, which AppKit short-circuits when the rect is unchanged, this path does real
    /// work every time: a UUID interpolation plus one or two `String(localized:)` lookups.
    /// Six panes during a resize drag is a few hundred microseconds of localization-table
    /// lookups per pointer event, for a value that changed for at most the card that moved.
    func testAnUnchangedSlotRectSkipsTheAccessibilityRewrite() {
        let slotID = UUID()
        let card = SpatialSlotCardView(slotID: slotID)
        let slot = SpatialSlot(id: slotID, rect: GridRect(x: 0, y: 0, width: 1, height: 1))

        XCTAssertTrue(
            card.updateAccessibilityValue(for: slot),
            "the first call has nothing to compare against and must write"
        )
        XCTAssertFalse(
            card.updateAccessibilityValue(for: slot),
            "an unchanged rect must not rebuild the identifier and the spoken position"
        )
    }

    /// The guard must be exact, not merely cheap: both strings are pure functions of the rect,
    /// so a moved pane has to say where it moved to.
    func testAMovedPaneRewritesWhatItSays() {
        let id = UUID()
        let card = SpatialSlotCardView(slotID: id)
        let start = SpatialSlot(id: id, rect: GridRect(x: 0, y: 0, width: 1, height: 1))
        let moved = SpatialSlot(id: id, rect: GridRect(x: 3, y: 2, width: 2, height: 1))

        _ = card.updateAccessibilityValue(for: start)

        XCTAssertTrue(card.updateAccessibilityValue(for: moved))
        XCTAssertEqual(card.accessibilityValue() as? String, "Column 4, row 3, 2 by 1 cells")
    }
}
