import XCTest
@testable import TenonCore

/// `CommandIndex.rank` — the pure ranker the palette shell projects. It blends fuzzy
/// title match, keyword fallback, frecency, and `when`-visibility. All headless.
final class CommandIndexTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func cmd(_ id: String, _ title: String,
                     keywords: [String] = [], when: String? = nil) -> Command {
        Command(id: id, title: title, keywords: keywords, when: when)
    }

    func testEmptyQueryReturnsEverythingSortedByFrecencyThenTitle() {
        let index = CommandIndex([cmd("a", "Alpha"), cmd("b", "Bravo"), cmd("c", "Charlie")])
        var frecency = Frecency()
        frecency.record("c", at: now) // c is the hottest → should lead
        let ranked = index.rank(query: "", frecency: frecency, now: now)
        XCTAssertEqual(ranked.map(\.command.id).first, "c")
        // The two cold commands fall back to title order.
        XCTAssertEqual(ranked.map(\.command.id), ["c", "a", "b"])
        XCTAssertTrue(ranked.allSatisfy { $0.titleMatch.isEmpty })
    }

    func testTypedQueryKeepsFuzzyMatchesAndDropsTheRest() {
        let index = CommandIndex([cmd("sr", "Split Right"), cmd("nt", "New Tab")])
        let ranked = index.rank(query: "split", frecency: Frecency(), now: now)
        XCTAssertEqual(ranked.map(\.command.id), ["sr"])
    }

    func testTitleMatchesCarryHighlightIndices() {
        let index = CommandIndex([cmd("sr", "Split Right")])
        let ranked = index.rank(query: "sr", frecency: Frecency(), now: now)
        XCTAssertEqual(ranked.first?.titleMatch, [0, 6])
    }

    func testKeywordFallbackIncludesCommandWithNoTitleMatch() {
        let index = CommandIndex([cmd("set", "Settings", keywords: ["preferences", "prefs"])])
        let ranked = index.rank(query: "prefs", frecency: Frecency(), now: now)
        XCTAssertEqual(ranked.map(\.command.id), ["set"])
        // Matched via keyword, so there is no title highlight.
        XCTAssertEqual(ranked.first?.titleMatch, [])
    }

    func testFrecencyBreaksTiesBetweenEqualTextMatches() {
        // "sp" scores identically against "Split" and "Split Right" (same S,p prefix).
        let index = CommandIndex([cmd("a", "Split"), cmd("b", "Split Right")])
        var frecency = Frecency()
        frecency.record("b", at: now)
        let ranked = index.rank(query: "sp", frecency: frecency, now: now)
        XCTAssertEqual(ranked.map(\.command.id), ["b", "a"])
    }

    func testWhenClauseHidesCommandUntilContextIsActive() {
        let index = CommandIndex([cmd("clr", "Clear Terminal", when: "terminalFocus")])
        XCTAssertEqual(index.rank(query: "", frecency: Frecency(), now: now).count, 0)
        let visible = index.rank(query: "", frecency: Frecency(), now: now, context: ["terminalFocus"])
        XCTAssertEqual(visible.map(\.command.id), ["clr"])
    }

    func testWhenClauseSupportsNegation() {
        let index = CommandIndex([cmd("x", "Only Without Focus", when: "!terminalFocus")])
        XCTAssertEqual(index.rank(query: "", frecency: Frecency(), now: now).map(\.command.id), ["x"])
        XCTAssertEqual(index.rank(query: "", frecency: Frecency(), now: now, context: ["terminalFocus"]).count, 0)
    }
}
