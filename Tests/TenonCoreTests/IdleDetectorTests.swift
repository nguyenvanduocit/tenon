import XCTest
@testable import TenonCore

final class IdleDetectorTests: XCTestCase {
    func testFiresAfterStableSamples() {
        var detector = IdleDetector(stableSamples: 3)
        XCTAssertFalse(detector.record("a"))
        XCTAssertFalse(detector.record("a"))
        XCTAssertTrue(detector.record("a"))
    }

    func testChangeResetsStreak() {
        var detector = IdleDetector(stableSamples: 2)
        XCTAssertFalse(detector.record("a"))
        XCTAssertFalse(detector.record("b"))
        XCTAssertTrue(detector.record("b"))
    }

    func testStableSamplesClampedToAtLeastOne() {
        var detector = IdleDetector(stableSamples: 0)
        XCTAssertTrue(detector.record("x"))
    }
}
