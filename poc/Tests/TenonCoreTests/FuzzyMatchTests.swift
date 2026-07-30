import XCTest
@testable import TenonCore

/// `Fuzzy.match` — subsequence matching with fzf-style scoring, the ranking primitive
/// behind the command palette. Pure, so it is asserted here without a window
/// (`docs/tdd.md` fitness test). Tests pin *properties* (relative ordering, indices),
/// not exact score constants, so scoring can be tuned without churning the suite.
final class FuzzyMatchTests: XCTestCase {
    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(Fuzzy.match("zzz", in: "abc"))
        XCTAssertNil(Fuzzy.match("abx", in: "abc")) // a,b subsequence but x is not
    }

    func testSubsequenceMatchesInOrderNotContiguous() {
        // "fzf" is a subsequence of "fuzzy finder": f-u-z-z-y- -f-i-n-d-e-r
        XCTAssertNotNil(Fuzzy.match("fzf", in: "fuzzy finder"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertNotNil(Fuzzy.match("SR", in: "split right"))
        XCTAssertNotNil(Fuzzy.match("sr", in: "Split Right"))
    }

    func testEmptyQueryIsATrivialZeroScoreMatch() {
        let m = Fuzzy.match("", in: "anything")
        XCTAssertEqual(m?.score, 0)
        XCTAssertEqual(m?.matchedIndices, [])
    }

    func testMatchedIndicesPointAtTheMatchedCharacters() {
        // "split right" indices: s0 p1 l2 i3 t4 (space)5 r6 i7 g8 h9 t10
        let m = Fuzzy.match("sr", in: "split right")
        XCTAssertEqual(m?.matchedIndices, [0, 6])
    }

    func testContiguousRunOutscoresScatteredMatch() {
        let contiguous = Fuzzy.match("abc", in: "abcxx")!.score
        let scattered = Fuzzy.match("abc", in: "axbxc")!.score
        XCTAssertGreaterThan(contiguous, scattered)
    }

    func testStartOfStringOutscoresMidStringMatch() {
        let atStart = Fuzzy.match("s", in: "split")!.score      // s at index 0
        let midWord = Fuzzy.match("s", in: "assist")!.score     // first s at index 1
        XCTAssertGreaterThan(atStart, midWord)
    }

    func testWordBoundaryOutscoresInteriorMatch() {
        let boundary = Fuzzy.match("r", in: "split right")!.score // r after a space
        let interior = Fuzzy.match("r", in: "carrot")!.score      // r inside a word
        XCTAssertGreaterThan(boundary, interior)
    }
}
