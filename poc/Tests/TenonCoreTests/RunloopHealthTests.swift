import XCTest
@testable import TenonCore

/// T-092: the stall judgement, decided from injected times only.
///
/// Every test here drives a clock by hand. Nothing sleeps, so the suite stays fast and the
/// assertions are about the rule rather than about timing luck.
final class RunloopHealthTests: XCTestCase {
    private func health(threshold: TimeInterval = 5, escalation: TimeInterval = 60) -> RunloopHealth {
        RunloopHealth(threshold: threshold, escalationInterval: escalation, startedAt: 0)
    }

    /// A working app beats constantly and must produce no records at all. Diagnostics that
    /// write during normal operation are diagnostics nobody reads.
    func testBeatingRunloopProducesNoEvents() {
        var subject = health()

        for tick in stride(from: 0.1, through: 10, by: 0.1) {
            XCTAssertNil(subject.beat(at: tick), "A completed turn is not news.")
            XCTAssertNil(subject.probe(at: tick), "A probe right after a beat is not news.")
        }

        XCTAssertFalse(subject.isStalled)
    }

    func testSilenceShorterThanThresholdIsNotAStall() {
        var subject = health(threshold: 5)

        XCTAssertNil(subject.probe(at: 4.9))
        XCTAssertFalse(subject.isStalled)
    }

    func testProbeReportsTheStallOnceItCrossesTheThreshold() {
        var subject = health(threshold: 5)

        XCTAssertEqual(subject.probe(at: 6), .stalled(duration: 6))
        XCTAssertTrue(subject.isStalled)
    }

    /// The one behaviour that decides whether this is usable: a stall lasting hours must not
    /// write a record per probe. A one-second probe over the two-hour T-091 hang would have
    /// been 7,200 records saying the same thing.
    func testAnOngoingStallIsReportedOnlyAtTheEscalationInterval() {
        var subject = health(threshold: 5, escalation: 60)

        XCTAssertEqual(subject.probe(at: 6), .stalled(duration: 6))

        for tick in stride(from: 7.0, through: 65.0, by: 1.0) {
            XCTAssertNil(subject.probe(at: tick), "Probe at \(tick)s should be silent.")
        }

        XCTAssertEqual(subject.probe(at: 66), .stillStalled(duration: 66))
    }

    func testEscalationKeepsReportingForAVeryLongStall() {
        var subject = health(threshold: 5, escalation: 60)
        _ = subject.probe(at: 6)

        var escalations = 0
        for tick in stride(from: 7.0, through: 3600.0, by: 1.0) where subject.probe(at: tick) != nil {
            escalations += 1
        }

        // An hour of silence at a 60s escalation: roughly one record a minute, not one a probe.
        XCTAssertEqual(escalations, 59, "Expected ~one record per escalation interval.")
    }

    func testRecoveryIsReportedWithHowLongTheStallLasted() {
        var subject = health(threshold: 5)
        _ = subject.probe(at: 6)

        XCTAssertEqual(subject.beat(at: 20), .recovered(stallDuration: 20))
        XCTAssertFalse(subject.isStalled)
    }

    /// The stall is measured from the last completed turn, not from the probe that noticed
    /// it — otherwise a slow watchdog would under-report every freeze.
    func testStallIsMeasuredFromTheLastBeatNotTheFirstProbe() {
        var subject = health(threshold: 5)
        _ = subject.beat(at: 10)

        _ = subject.probe(at: 100)

        XCTAssertEqual(
            subject.beat(at: 110),
            .recovered(stallDuration: 100),
            "The stall began when the runloop went quiet at 10s, not when the probe ran at 100s."
        )
    }

    func testASecondStallAfterRecoveryIsReportedAgain() {
        var subject = health(threshold: 5)
        _ = subject.probe(at: 6)
        _ = subject.beat(at: 7)

        XCTAssertEqual(subject.probe(at: 13), .stalled(duration: 6), "Each episode is its own report.")
    }
}
