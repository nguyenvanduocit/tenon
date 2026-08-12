import XCTest
@testable import TenonCore

final class IdleDetectorTests: XCTestCase {
    func testFiresAfterStableSamples() {
        var detector = IdleDetector(stableSamples: 3)
        XCTAssertFalse(detector.record(1))
        XCTAssertFalse(detector.record(1))
        XCTAssertTrue(detector.record(1))
    }

    func testChangeResetsStreak() {
        var detector = IdleDetector(stableSamples: 2)
        XCTAssertFalse(detector.record(1))
        XCTAssertFalse(detector.record(2))
        XCTAssertTrue(detector.record(2))
    }

    func testStableSamplesClampedToAtLeastOne() {
        var detector = IdleDetector(stableSamples: 0)
        XCTAssertTrue(detector.record(9))
    }
}
