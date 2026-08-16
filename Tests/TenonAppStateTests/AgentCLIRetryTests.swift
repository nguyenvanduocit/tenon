import XCTest
@testable import TenonApp

/// T-131: what the host does when the API is busy rather than when the run is broken.
///
/// The Claude CLI retries a retryable API error itself, with exponential backoff, and announces
/// each attempt on stdout before going quiet for the length of the backoff. Measured
/// 2026-08-11 against a loaded endpoint, those quiet stretches reach **50.4 s and 46.2 s** —
/// past the host's 45 s silence deadline — so a reading fails on API weather and the person is
/// told "45s of silence", which is the one thing that is true about the symptom and useless
/// about the cause.
///
/// The announcement is `SDKAPIRetryMessage`, named as the wire twin of the REPL's retry banner
/// in the installed CLI's own strings (2.1.227): `"@internal Retryable-API-error frame carrying
/// the plain-data error snapshot and retry counters. REPL renders the retry banner from this.
/// Wire twin is SDKAPIRetryMessage ('api_retry')."` The classification depends only on the
/// subtype; `attempt` and the error detail are read when present and the line still classifies
/// without them, because a field name is a weaker thing to bet a deadline on than a subtype.
final class AgentCLIRetryTests: XCTestCase {
    // MARK: - Reading the announcement

    func testARetryAnnouncementIsReadAsARetryRatherThanIgnored() {
        let line = Data(
            #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":8000,"error_status":529,"error":"overloaded"}"#
                .utf8
        )

        XCTAssertEqual(
            AgentCLIStreamReader.read(line: line),
            .retrying(attempt: 2, delay: 8),
            "a run that announced a retry is working, and the host has no way to know that if it drops the line"
        )
    }

    /// The subtype is the contract; the counters are a courtesy.
    func testARetryWithoutCountersStillClassifies() {
        let line = Data(#"{"type":"system","subtype":"api_retry"}"#.utf8)

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .retrying(attempt: 1, delay: nil))
    }

    /// The init frame shares the type and must keep its own meaning.
    func testTheInitFrameIsStillTheConnectedAnnouncement() {
        let line = Data(#"{"type":"system","subtype":"init","session_id":"abc"}"#.utf8)

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .connected)
    }

    /// A `system` line this host has no use for stays framing, so a future subtype cannot
    /// silently become a retry.
    func testAnUnknownSystemSubtypeIsStillIgnored() {
        let line = Data(#"{"type":"system","subtype":"informational","level":"notice"}"#.utf8)

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .ignored)
    }

    // MARK: - What the person is told

    func testARetryInFlightSaysTheApiIsBusyRatherThanShowingNothing() {
        XCTAssertEqual(
            AgentTimelineProgress.retrying(attempt: 3).message,
            "The API is busy — retrying (attempt 3)"
        )
    }

    // MARK: - What the deadline does with it

    /// The rule the whole feature turns on.
    ///
    /// T-111 justified a silence deadline over a duration one: "a reading that is still writing
    /// is alive by observation". A run that announced a backoff is alive by observation too —
    /// it said so — and the quiet that follows is the backoff it named. So an announced retry
    /// explains the silence, and the absolute ceiling stays the only bound on a run that never
    /// speaks again.
    func testAnAnnouncedRetryExplainsTheSilenceThatFollowsIt() {
        let clock = AgentRunActivity()
        // Past startup, whose own quiet is accounted for, so what is asserted below is the
        // retry's account rather than the one every run begins with.
        clock.replyStarted()
        XCTAssertFalse(clock.silenceIsExplained, "a run mid-reply has nothing to hide behind")

        clock.explain(forSeconds: 8)

        XCTAssertTrue(
            clock.silenceIsExplained,
            "the CLI said it is waiting on a backoff, so quiet is what it promised, not a hang"
        )
    }

    /// The excuse lasts as long as the CLI said it would, and no longer.
    ///
    /// `retry_delay_ms` is on the wire — the CLI names its own backoff — so the host is not
    /// guessing when the quiet stops being accounted for. It gets the promised delay plus the
    /// ordinary silence budget to say something after the wait, and then it is a hang again.
    func testAPromisedDelayRunsOutInsteadOfExcusingSilenceForever() {
        let clock = AgentRunActivity()

        clock.explain(forSeconds: -Double(AgentCLITimelineSynthesizer.silenceSeconds) - 1)

        XCTAssertFalse(
            clock.silenceIsExplained,
            """
            A backoff the CLI said would be over still excuses the quiet. The promise is a \
            deadline, not an amnesty — a run that misses its own restart is exactly the kind \
            worth stopping.
            """
        )
    }

    /// A retry that names no delay is the one case the host genuinely cannot bound, so it falls
    /// back to the ceiling rather than to a number of its own.
    func testARetryWithNoStatedDelayIsExcusedUntilTheCeiling() {
        let clock = AgentRunActivity()

        clock.explain(forSeconds: nil)

        XCTAssertTrue(clock.silenceIsExplained)
    }

    /// Explaining the silence must not disable the ceiling, or a CLI that announces one retry
    /// and dies holds the pipe for as long as the pane lives.
    func testExplainedSilenceStillLeavesTheCeilingInCharge() {
        XCTAssertGreaterThan(
            AgentCLITimelineSynthesizer.ceilingSeconds,
            AgentCLITimelineSynthesizer.silenceSeconds,
            "the ceiling is the bound that survives an explained silence, so it has to be the longer one"
        )
    }
}
