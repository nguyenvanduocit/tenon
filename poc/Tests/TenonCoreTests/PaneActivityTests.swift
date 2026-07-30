import XCTest
@testable import TenonCore

/// `PaneActivity` is the pure machine behind every "which pane needs a human"
/// surface. Its inputs are terminal observations, explicit viewed-ness, and an
/// injected clock — nothing ambient — so every transition, and every forbidden
/// one, is asserted here without a window and without a single sleep.
///
/// The boundary these tests pin: an idle prompt with nothing to report never
/// asks for attention; a finish (`commandFinishedCount` increment) nobody was
/// viewing bolds the pane until a human actually views it; an exit nobody was
/// viewing does the same, because a crashed process still needs a human.
final class PaneActivityTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func observation(
        _ text: String,
        exited: Bool = false,
        finishes: Int = 0
    ) -> PaneActivity.Observation {
        PaneActivity.Observation(
            text: text,
            processExited: exited,
            commandFinishedCount: finishes
        )
    }

    /// A pane already settled at an idle prompt: two identical samples against
    /// a 2-sample idle rule, so the next observation decides the transition.
    private func settled(
        viewed: Bool = false,
        text: String = "$ ",
        finishes: Int = 0
    ) -> PaneActivity {
        var pane = PaneActivity(stableSamples: 2, viewed: viewed, at: at(0))
        _ = pane.observe(observation(text, finishes: finishes), at: at(1))
        _ = pane.observe(observation(text, finishes: finishes), at: at(2))
        return pane
    }

    // MARK: - Working and idle

    func testANewPaneStartsWorkingAndUnbolded() {
        let pane = PaneActivity(stableSamples: 3, viewed: false, at: at(0))
        XCTAssertEqual(pane.state, .working)
        XCTAssertFalse(pane.isUnseen)
        XCTAssertEqual(pane.stateSince, at(0))
    }

    func testAScreenBecomesIdleOnlyAfterTheConfiguredStableStreak() {
        var pane = PaneActivity(stableSamples: 3, viewed: false, at: at(0))
        XCTAssertEqual(pane.observe(observation("$ "), at: at(1)), [])
        XCTAssertEqual(pane.state, .working)
        XCTAssertEqual(pane.observe(observation("$ "), at: at(2)), [])
        XCTAssertEqual(pane.state, .working)
        XCTAssertEqual(
            pane.observe(observation("$ "), at: at(3)),
            [.stateChanged(from: .working, to: .idle)]
        )
        XCTAssertEqual(pane.state, .idle)
    }

    func testNewOutputWakesAnIdlePaneBackToWorking() {
        var pane = settled()
        XCTAssertEqual(
            pane.observe(observation("$ make\ncompiling…"), at: at(3)),
            [.stateChanged(from: .idle, to: .working)]
        )
        XCTAssertFalse(pane.isUnseen)
    }

    func testAnIdlePromptWithNothingToReportNeverAsksForAttention() {
        var pane = settled()
        for tick in 3..<30 {
            XCTAssertEqual(
                pane.observe(observation("$ "), at: at(TimeInterval(tick))),
                []
            )
        }
        XCTAssertEqual(pane.state, .idle)
        XCTAssertFalse(pane.isUnseen)
    }

    // MARK: - The finished-unseen boundary

    func testAFinishNobodyWasViewingBecomesFinishedUnseen() {
        var pane = settled()
        XCTAssertEqual(
            pane.observe(observation("$ ", finishes: 1), at: at(3)),
            [.stateChanged(from: .idle, to: .finishedUnseen), .becameUnseen]
        )
        XCTAssertTrue(pane.isUnseen)
    }

    func testAFinishTheHumanIsWatchingIsSeenImmediatelyAndNeverBolds() {
        var pane = settled(viewed: true)
        let events = pane.observe(observation("$ ", finishes: 1), at: at(3))
        XCTAssertEqual(events, [.stateChanged(from: .idle, to: .seen)])
        XCTAssertEqual(pane.state, .seen)
        XCTAssertFalse(pane.isUnseen)
    }

    func testAFinishBoldsImmediatelyEvenBeforeTheScreenSettles() {
        var pane = settled()
        let events = pane.observe(
            observation("$ make\nok\n$ ", finishes: 1),
            at: at(3)
        )
        XCTAssertEqual(
            events,
            [.stateChanged(from: .idle, to: .working), .becameUnseen]
        )
        XCTAssertEqual(pane.state, .working)
        XCTAssertTrue(pane.isUnseen)
    }

    func testTheFirstObservationBaselinesTheFinishCountWithoutBolding() {
        var pane = PaneActivity(stableSamples: 2, viewed: false, at: at(0))
        _ = pane.observe(observation("$ ", finishes: 7), at: at(1))
        XCTAssertEqual(
            pane.observe(observation("$ ", finishes: 7), at: at(2)),
            [.stateChanged(from: .working, to: .idle)]
        )
        XCTAssertFalse(pane.isUnseen)
    }

    func testACounterResetRebaselinesWithoutInventingAttention() {
        var pane = settled(finishes: 5)
        XCTAssertEqual(pane.observe(observation("$ ", finishes: 0), at: at(3)), [])
        XCTAssertEqual(pane.state, .idle)
        XCTAssertFalse(pane.isUnseen)
        XCTAssertEqual(
            pane.observe(observation("$ ", finishes: 1), at: at(4)),
            [.stateChanged(from: .idle, to: .finishedUnseen), .becameUnseen]
        )
    }

    // MARK: - What viewing means, and what it does not

    func testViewingAFinishedPaneMakesItSeenAndClearsTheBold() {
        var pane = settled()
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        XCTAssertEqual(
            pane.setViewed(true, at: at(4)),
            [.stateChanged(from: .finishedUnseen, to: .seen), .unseenCleared]
        )
        XCTAssertEqual(pane.state, .seen)
        XCTAssertFalse(pane.isUnseen)
    }

    func testAPaneTheHumanNeverViewedNeverSilentlyClears() {
        var pane = settled()
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        var events: [PaneActivityEvent] = []
        for tick in 4..<40 {
            events += pane.observe(
                observation("$ ", finishes: 1),
                at: at(TimeInterval(tick))
            )
        }
        events += pane.setViewed(false, at: at(50))
        XCTAssertEqual(events, [])
        XCTAssertEqual(pane.state, .finishedUnseen)
        XCTAssertTrue(pane.isUnseen)
    }

    func testViewingClearsTheBoldEvenWhileThePaneIsStillWorking() {
        var pane = settled()
        _ = pane.observe(observation("new output", finishes: 1), at: at(3))
        XCTAssertEqual(pane.setViewed(true, at: at(4)), [.unseenCleared])
        XCTAssertEqual(pane.state, .working)
        XCTAssertFalse(pane.isUnseen)
        XCTAssertEqual(
            pane.observe(observation("new output", finishes: 1), at: at(5)),
            [.stateChanged(from: .working, to: .seen)]
        )
    }

    func testViewingAnUneventfulPaneChangesNothing() {
        var pane = settled()
        XCTAssertEqual(pane.setViewed(true, at: at(3)), [])
        XCTAssertEqual(pane.state, .idle)
        XCTAssertEqual(pane.setViewed(false, at: at(4)), [])
        XCTAssertEqual(pane.state, .idle)
    }

    func testNewActivityDoesNotLaunderAnUnseenFinish() {
        var pane = settled()
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        XCTAssertEqual(
            pane.observe(observation("$ tail -f log\n…", finishes: 1), at: at(4)),
            [.stateChanged(from: .finishedUnseen, to: .working)]
        )
        XCTAssertTrue(pane.isUnseen)
        XCTAssertEqual(
            pane.observe(observation("$ tail -f log\n…", finishes: 1), at: at(5)),
            [.stateChanged(from: .working, to: .finishedUnseen)]
        )
        XCTAssertTrue(pane.isUnseen)
    }

    // MARK: - Seen

    func testSeenPersistsAcrossQuietObservations() {
        var pane = settled(viewed: true)
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        for tick in 4..<12 {
            XCTAssertEqual(
                pane.observe(observation("$ ", finishes: 1), at: at(TimeInterval(tick))),
                []
            )
        }
        XCTAssertEqual(pane.state, .seen)
    }

    func testSeenReturnsToWorkingOnNewOutput() {
        var pane = settled(viewed: true)
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        XCTAssertEqual(
            pane.observe(observation("$ build\nrunning…", finishes: 1), at: at(4)),
            [.stateChanged(from: .seen, to: .working)]
        )
    }

    func testASecondFinishAfterUnviewBoldsAgain() {
        var pane = settled(viewed: true)
        _ = pane.observe(observation("$ ", finishes: 1), at: at(3))
        XCTAssertEqual(pane.setViewed(false, at: at(4)), [])
        XCTAssertEqual(
            pane.observe(observation("$ ", finishes: 2), at: at(5)),
            [.stateChanged(from: .seen, to: .finishedUnseen), .becameUnseen]
        )
    }

    // MARK: - Exited

    func testExitWithoutAViewerIsExitedAndStillNeedsAHuman() {
        var pane = settled()
        XCTAssertEqual(
            pane.observe(observation("make: error", exited: true), at: at(3)),
            [.stateChanged(from: .idle, to: .exited), .becameUnseen]
        )
        XCTAssertEqual(pane.state, .exited)
        XCTAssertTrue(pane.isUnseen)
    }

    func testExitUnderTheHumansEyesNeedsNoAttention() {
        var pane = settled(viewed: true)
        XCTAssertEqual(
            pane.observe(observation("$ exit", exited: true), at: at(3)),
            [.stateChanged(from: .idle, to: .exited)]
        )
        XCTAssertFalse(pane.isUnseen)
    }

    func testViewingAnExitedPaneClearsTheBoldButTheStateStaysExited() {
        var pane = settled()
        _ = pane.observe(observation("crash", exited: true), at: at(3))
        XCTAssertEqual(pane.setViewed(true, at: at(4)), [.unseenCleared])
        XCTAssertEqual(pane.state, .exited)
        XCTAssertFalse(pane.isUnseen)
    }

    func testAnExitArrivingWithItsFinalFinishStillBoldsOnce() {
        var pane = settled()
        XCTAssertEqual(
            pane.observe(observation("done\n", exited: true, finishes: 1), at: at(3)),
            [.stateChanged(from: .idle, to: .exited), .becameUnseen]
        )
        XCTAssertEqual(pane.setViewed(true, at: at(4)), [.unseenCleared])
    }

    func testExitedIsTerminalEvenIfObservationsKeepArriving() {
        var pane = settled()
        _ = pane.observe(observation("boom", exited: true), at: at(3))
        XCTAssertEqual(
            pane.observe(observation("fresh text", exited: false, finishes: 9), at: at(4)),
            []
        )
        XCTAssertEqual(pane.state, .exited)
        XCTAssertEqual(pane.stateSince, at(3))
    }

    // MARK: - The injected clock

    func testStateSinceMovesOnlyWhenTheStateDoes() {
        var pane = PaneActivity(stableSamples: 2, viewed: false, at: at(0))
        XCTAssertEqual(pane.stateSince, at(0))
        _ = pane.observe(observation("$ "), at: at(1))
        XCTAssertEqual(pane.stateSince, at(0))
        _ = pane.observe(observation("$ "), at: at(2))
        XCTAssertEqual(pane.stateSince, at(2))
        _ = pane.observe(observation("$ "), at: at(3))
        XCTAssertEqual(pane.stateSince, at(2))
        _ = pane.observe(observation("run…"), at: at(4))
        XCTAssertEqual(pane.stateSince, at(4))
    }

    func testAFinishIsStampedWithTheInjectedClock() {
        var pane = settled()
        XCTAssertNil(pane.lastFinishedAt)
        _ = pane.observe(observation("$ ", finishes: 1), at: at(9))
        XCTAssertEqual(pane.lastFinishedAt, at(9))
        _ = pane.observe(observation("$ ", finishes: 1), at: at(11))
        XCTAssertEqual(pane.lastFinishedAt, at(9))
        _ = pane.observe(observation("$ ", finishes: 2), at: at(13))
        XCTAssertEqual(pane.lastFinishedAt, at(13))
    }
}
