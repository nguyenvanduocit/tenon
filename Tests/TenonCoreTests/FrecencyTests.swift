import XCTest
@testable import TenonCore

/// `Frecency` — one number blending how *often* and how *recently* a command was run
/// (Firefox frecency lineage). The clock is injected (`now`), so decay is asserted
/// deterministically without a window or a real wall clock.
final class FrecencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testUnseenIdScoresZero() {
        let f = Frecency()
        XCTAssertEqual(f.score("never", now: t0), 0)
    }

    func testRecordingOnceGivesAPositiveScore() {
        var f = Frecency()
        f.record("a", at: t0)
        XCTAssertGreaterThan(f.score("a", now: t0), 0)
    }

    func testRecentUseOutscoresOldUseAtEqualFrequency() {
        var f = Frecency()
        f.record("old", at: t0)
        let later = t0.addingTimeInterval(Frecency.halfLife) // one half-life on
        f.record("new", at: later)
        XCTAssertGreaterThan(f.score("new", now: later), f.score("old", now: later))
    }

    func testFrequentUseOutscoresRareUseAtEqualRecency() {
        var f = Frecency()
        f.record("hot", at: t0)
        f.record("hot", at: t0)
        f.record("hot", at: t0)
        f.record("cold", at: t0)
        XCTAssertGreaterThan(f.score("hot", now: t0), f.score("cold", now: t0))
    }

    func testScoreDecaysByHalfOverOneHalfLife() {
        var f = Frecency()
        f.record("a", at: t0)
        let fresh = f.score("a", now: t0)
        let aged = f.score("a", now: t0.addingTimeInterval(Frecency.halfLife))
        XCTAssertEqual(aged, fresh / 2, accuracy: 1e-9)
    }

    func testCodableRoundTripPreservesScores() throws {
        var f = Frecency()
        f.record("a", at: t0)
        f.record("a", at: t0)
        f.record("b", at: t0)
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(Frecency.self, from: data)
        XCTAssertEqual(back.score("a", now: t0), f.score("a", now: t0), accuracy: 1e-9)
        XCTAssertEqual(back.score("b", now: t0), f.score("b", now: t0), accuracy: 1e-9)
    }
}
