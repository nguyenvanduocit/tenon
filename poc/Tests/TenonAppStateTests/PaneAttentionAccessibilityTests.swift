import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-093. The attention dot is the whole signal, so it cannot be only a colour.
///
/// Three surfaces draw this dot — the tab chip, the pane card, the sidebar rollup — and until
/// now every one of them said "amber" or "green" and nothing else. That excludes anyone reading
/// the window through VoiceOver, and anyone who cannot separate those hues from each other.
@MainActor
final class PaneAttentionAccessibilityTests: XCTestCase {
    private let states: [PaneActivityState] = [
        .working, .idle, .finishedUnseen, .seen, .exited,
    ]

    func testEveryStateSaysSomethingDistinct() {
        let spoken = states.map(PaneAttentionProjection.spokenState(for:))

        XCTAssertEqual(
            Set(spoken).count,
            states.count,
            "two states that say the same thing are one state to a listener: \(spoken)"
        )
        XCTAssertFalse(spoken.contains(where: \.isEmpty))
    }

    /// A finished pane and a pane whose shell died are the two the colour vocabulary puts
    /// furthest apart (green against red) and the two a shape vocabulary must not merge.
    func testTheShapeVocabularyDistinguishesEveryState() {
        let symbols = states.map(PaneAttentionProjection.symbolName(for:))

        XCTAssertEqual(
            Set(symbols).count,
            states.count,
            "Differentiate Without Color needs one glyph per state: \(symbols)"
        )
    }

    /// The colour vocabulary stays exactly as designed — this is an addition, not a
    /// replacement, and a pane that is working still reads amber.
    func testTheColourVocabularyIsUnchanged() {
        XCTAssertEqual(
            PaneAttentionProjection.dotColor(for: .working),
            TenonTheme.amberNS
        )
        XCTAssertEqual(
            PaneAttentionProjection.dotColor(for: .exited),
            .systemRed
        )
    }
}
