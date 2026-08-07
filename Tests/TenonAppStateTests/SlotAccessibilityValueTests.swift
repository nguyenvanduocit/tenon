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
}
