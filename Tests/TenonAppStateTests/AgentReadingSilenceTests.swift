import XCTest
@testable import TenonApp

/// T-137: which quiet is evidence of a hang, and which quiet is just the API not answering yet.
///
/// T-111 justified a silence deadline over a duration one: "a reading that is still writing is
/// alive by observation". That argument holds only after the writing starts. Measured against the
/// installed Claude CLI 2.1.228 on 2026-08-12, with the exact arguments this host builds and a
/// 97 KB / 320-fact prompt:
///
/// | phase | heartbeat | observed quiet |
/// | --- | --- | --- |
/// | spawn → `system/init` | none | 1.7 s |
/// | `init` → `status: requesting` | none | ~0 s |
/// | `requesting` → `message_start` | **none** | 1.8 s idle, unbounded under load |
/// | streaming | `system/thinking_tokens` every ~1.4 s | max **2.62 s** over 192 lines / 126.9 s |
///
/// So one number was doing two incompatible jobs: seventeen times looser than it needs to be while
/// the reply arrives, and an invented bound on the one stretch where the host observes nothing at
/// all. `AgentCLITimelineSynthesizer.silenceSeconds(for: .codex)` already states the rule this
/// applies — no signal means the ceiling is the only honest bound — and it is a property of the
/// phase, not of the provider.
final class AgentReadingSilenceTests: XCTestCase {
    // MARK: - Reading the two phase boundaries off the wire

    /// Recorded from the installed CLI 2.1.228: the frame it emits the moment it hands the request
    /// to the API, and the last thing it says before the model's first token.
    func testTheRequestAnnouncementIsReadAsWaitingRatherThanIgnored() {
        let line = Data(
            #"{"type":"system","subtype":"status","status":"requesting","uuid":"684fc91e","session_id":"2efc8666"}"#
                .utf8
        )

        XCTAssertEqual(
            AgentCLIStreamReader.read(line: line),
            .requesting,
            """
            The CLI said it is waiting on the API, and the host has no other way to know that the \
            quiet which follows is a request in flight rather than a dead process.
            """
        )
    }

    /// A `status` this host has no rule for stays framing, so a future status cannot silently
    /// become an excuse for arbitrary quiet.
    func testAnUnknownStatusIsStillIgnored() {
        let line = Data(#"{"type":"system","subtype":"status","status":"compacting"}"#.utf8)

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .ignored)
    }

    /// `message_start` is where the heartbeat begins: from here the CLI emits
    /// `system/thinking_tokens` every ~1.4 s, so silence carries information again.
    func testTheReplyStartingIsReadAsTheReplyStarting() {
        let line = Data(
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_01","role":"assistant"}}}"#
                .utf8
        )

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .replying)
    }

    /// The heartbeat itself carries nothing the host needs to read — its whole value is that bytes
    /// arrived — so it stays framing and must not be mistaken for content.
    func testTheThinkingHeartbeatIsFramingRatherThanContent() {
        let line = Data(#"{"type":"system","subtype":"thinking_tokens","tokens":420}"#.utf8)

        XCTAssertEqual(AgentCLIStreamReader.read(line: line), .ignored)
    }

    // MARK: - What the deadline does with them

    /// The rule this task turns on.
    ///
    /// A request in flight names no duration — nothing on the wire says how long the API will take
    /// to start — so bounding it with a number of the host's own invention is exactly the guess
    /// `silenceSeconds(for: .codex)` already refuses to make. The ceiling stays in charge.
    func testARequestInFlightAccountsForTheQuietUntilTheReplyArrives() {
        let clock = AgentRunActivity()

        XCTAssertFalse(clock.silenceIsExplained, "nothing has explained anything yet")

        clock.awaitsReply()

        XCTAssertTrue(
            clock.silenceIsExplained,
            "the CLI said the request is in flight, so quiet is the API taking its time, not a hang"
        )
    }

    /// And the excuse ends the moment the heartbeat exists to replace it — otherwise a run that
    /// dies mid-reply would hold the pipe until the ceiling.
    func testTheReplyArrivingPutsTheDeadlineBackInCharge() {
        let clock = AgentRunActivity()
        clock.awaitsReply()

        clock.replyStarted()

        XCTAssertFalse(
            clock.silenceIsExplained,
            """
            Once the reply is arriving the CLI heartbeats every ~1.4 s, so unexplained quiet is \
            evidence again and the 45 s bound is the tight one it was measured to be.
            """
        )
    }

    /// A retry announced *after* the reply started still explains its own backoff: the two
    /// mechanisms compose rather than one clearing the other.
    func testAnAnnouncedRetryStillExplainsItselfAfterTheReplyStarted() {
        let clock = AgentRunActivity()
        clock.replyStarted()

        clock.explain(forSeconds: 30)

        XCTAssertTrue(clock.silenceIsExplained)
    }

    /// A second request — the CLI re-issuing after a retry — goes quiet again for the same reason
    /// the first one did, so the excuse has to be re-armable rather than one-shot.
    func testASecondRequestIsExcusedTheSameWayTheFirstWas() {
        let clock = AgentRunActivity()
        clock.awaitsReply()
        clock.replyStarted()

        clock.awaitsReply()

        XCTAssertTrue(clock.silenceIsExplained)
    }

    // MARK: - The watchdog rule itself

    /// A budget of zero makes every one of these decidable without a clock: any elapsed silence
    /// is already at the bound, so what the run has *said* is the only thing left deciding.
    func testAnUnexplainedRunAtItsBudgetIsStopped() {
        let clock = AgentRunActivity()
        clock.replyStarted()

        XCTAssertEqual(clock.expiry(silenceBudget: 0, ceilingSeconds: 600), .silence)
    }

    /// The one this task exists for: the same quiet, in the phase the CLI publishes nothing in,
    /// is not a reason to kill anything.
    func testARunWaitingOnTheApiIsNotStoppedAtTheSameBudget() {
        let clock = AgentRunActivity()
        clock.awaitsReply()

        XCTAssertNil(
            clock.expiry(silenceBudget: 0, ceilingSeconds: 600),
            "the request is in flight and the CLI emits no frame while it is — silence is not evidence here"
        )
    }

    /// A provider that streams nothing gets the same answer for the whole run. `codex` is the
    /// standing case, and this is the rule `silenceSeconds(for:)` states.
    func testAProviderWithNoHeartbeatIsNeverStoppedForSilence() {
        let clock = AgentRunActivity()
        clock.replyStarted()

        XCTAssertNil(clock.expiry(silenceBudget: nil, ceilingSeconds: 600))
    }

    /// The ceiling outranks every account, or a CLI that announces one wait and dies holds the
    /// pipe for as long as the pane lives.
    func testTheCeilingOutranksAnyAccountOfTheQuiet() {
        let clock = AgentRunActivity()
        clock.awaitsReply()

        XCTAssertEqual(clock.expiry(silenceBudget: nil, ceilingSeconds: 0), .ceiling)
    }

    /// And the ceiling is reported as itself, so the person is told the run ran long rather than
    /// that it went quiet.
    func testAnExpiredCeilingIsReportedAsTheCeilingRatherThanAsSilence() {
        let clock = AgentRunActivity()
        clock.replyStarted()

        XCTAssertEqual(clock.expiry(silenceBudget: 0, ceilingSeconds: 0), .ceiling)
    }

    // MARK: - What the person is told

    /// The pane cannot show "Reading the session" while nothing is being read. A run waiting on a
    /// busy API and a run that already has the digest in hand are different states, and the one
    /// the person is most likely to see for minutes is the one that must name itself.
    func testWaitingOnTheApiSaysSoRatherThanClaimingToBeReading() {
        XCTAssertEqual(
            AgentTimelineProgress.waiting.message,
            "Waiting for the model to start"
        )
        XCTAssertNotEqual(
            AgentTimelineProgress.waiting.message,
            AgentTimelineProgress.connected.message
        )
    }
}
