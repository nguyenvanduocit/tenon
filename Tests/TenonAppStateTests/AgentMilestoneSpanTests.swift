import Foundation
@testable import TenonApp
import XCTest

/// T-127. The time range on a milestone row is formatted by one formatter, not by one per read.
///
/// `DateFormatter` construction dominates its own use: measured here at roughly 60× the cost of
/// the `string(from:)` call it exists to make, plus ICU and locale locks. `metadata` reads
/// `span` twice — once to draw and once for the accessibility label — inside a
/// `ViewThatFits(in: .horizontal)`, which evaluates its candidates. Every milestone row
/// therefore built several formatters per body pass to produce a string like `09:24–09:31`.
@MainActor
final class AgentMilestoneSpanTests: XCTestCase {
    /// The rule: one formatter for the whole app, not one per row per pass.
    func testTheSpanFormatterIsBuiltOnce() {
        let first = AgentMilestoneSpan.formatter
        let second = AgentMilestoneSpan.formatter

        XCTAssertTrue(
            first === second,
            "each read built its own DateFormatter, which is the cost this type exists to remove"
        )
    }

    /// A milestone that started and ended inside the same minute says one time, not the same
    /// time twice with a dash between.
    func testAMilestoneInsideOneMinuteSaysOneTime() {
        let start = Date(timeIntervalSince1970: 1_754_900_000)
        let end = start.addingTimeInterval(20)

        let text = AgentMilestoneSpan.text(from: start, to: end)

        XCTAssertFalse(text.contains("–"), "one minute is one time: \(text)")
        XCTAssertEqual(text, AgentMilestoneSpan.formatter.string(from: start))
    }

    func testAMilestoneSpanningMinutesSaysBothEnds() {
        let start = Date(timeIntervalSince1970: 1_754_900_000)
        let end = start.addingTimeInterval(7 * 60)

        let text = AgentMilestoneSpan.text(from: start, to: end)

        XCTAssertEqual(
            text,
            "\(AgentMilestoneSpan.formatter.string(from: start))–"
                + "\(AgentMilestoneSpan.formatter.string(from: end))"
        )
    }
}
