import Foundation
@testable import TenonCore
import XCTest

/// T-094. Search matches the alphabet the person is typing in.
///
/// `lowercased()` folds by the invariant rules, which are not how anyone reads their own
/// language: a Vietnamese supervisor typing `dong` was matching nothing named `Đồng`, and the
/// highlight ranges have to survive the folding that fixes it.
final class LocaleAwareSearchTests: XCTestCase {
    func testTypingWithoutDiacriticsFindsTheNameThatHasThem() {
        XCTAssertNotNil(
            Fuzzy.match("dong", in: "Đồng bộ workspace"),
            "a query without diacritics must reach the name that carries them"
        )
        XCTAssertNotNil(Fuzzy.match("cafe", in: "Café settings"))
    }

    func testMatchedIndicesStillPointAtTheOriginalCharacters() {
        let candidate = "Café"
        let match = Fuzzy.match("caf", in: candidate)

        let characters = Array(candidate)
        let matched = try? XCTUnwrap(match).matchedIndices.map { characters[$0] }
        XCTAssertEqual(
            matched,
            ["C", "a", "f"],
            "folding must not shift the ranges the highlight draws"
        )
    }

    /// The fold is the same everywhere on purpose. Turkish casing maps `İ` to `ı`, so folding
    /// by the reader's locale would change which names one keystroke reaches from machine to
    /// machine — a search box has to answer the same way for the same list.
    func testTheFoldIsTheSameInEveryLocale() {
        XCTAssertEqual(String(Fuzzy.folded("İstanbul")), "istanbul")
        XCTAssertEqual(String(Fuzzy.folded("Đồng bộ")), "dong bo")
    }

    /// Plain ASCII behaviour is unchanged — the ranking these scores feed is unaffected.
    func testAsciiMatchingIsUnchanged() {
        XCTAssertNil(
            Fuzzy.match("tg", in: "git open"),
            "a fuzzy match still requires the characters in order"
        )
        XCTAssertNotNil(Fuzzy.match("gto", in: "git open"))
    }
}
