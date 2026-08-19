import Foundation
import TenonCore
import XCTest
@testable import TenonApp

/// T-178 (`WS-FR-036`): the roster that lets a sidebar row answer "is an agent in this pane"
/// synchronously, for a workspace nobody is looking at. Every rule here is about what the
/// roster refuses — an inherited agent, a subagent counted twice, unbounded growth — because
/// what it admits is one line and what it refuses is the whole reason it exists.
@MainActor
final class AgentPaneRosterTests: XCTestCase {
    private func hook(
        pane: UUID,
        surfaceToken: UUID,
        agentID: String? = nil,
        event: String = "PreToolUse"
    ) -> AgentHookEvent {
        AgentHookEvent(
            paneID: pane,
            surfaceToken: surfaceToken,
            provider: .claude,
            sessionID: "session-1",
            transcriptPath: nil,
            hookEventName: event,
            agentID: agentID
        )
    }

    // MARK: - What puts a pane on the roster

    func testALaunchNamesThePaneBeforeAnyHookHasFired() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let token = UUID()

        roster.note(slotID: pane, surfaceToken: token)

        XCTAssertEqual(roster.panes(matching: [pane: token]), [pane])
    }

    func testARootHookNamesThePaneItCameFrom() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let token = UUID()

        roster.ingest(hook(pane: pane, surfaceToken: token))

        XCTAssertEqual(roster.panes(matching: [pane: token]), [pane])
    }

    func testASubagentsHookNamesNoPaneBecauseItsWorkIsAlreadyItsParentsPane() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let token = UUID()

        roster.ingest(hook(pane: pane, surfaceToken: token, agentID: "sub-7"))

        XCTAssertTrue(roster.panes(matching: [pane: token]).isEmpty)
        XCTAssertTrue(roster.bindings.isEmpty)
    }

    // MARK: - What the roster refuses to keep

    func testAPaneRebuiltUnderTheSameSlotDoesNotInheritTheOldAgent() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let firstIncarnation = UUID()

        roster.note(slotID: pane, surfaceToken: firstIncarnation)

        // The pane was torn down and materialised again: same slot, new surface, new shell.
        let secondIncarnation = UUID()
        XCTAssertTrue(roster.panes(matching: [pane: secondIncarnation]).isEmpty)
    }

    func testAPaneWhoseSurfaceIsGoneIsNotNamed() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let token = UUID()

        roster.note(slotID: pane, surfaceToken: token)

        XCTAssertTrue(roster.panes(matching: [:]).isEmpty)
    }

    /// The gap this type knowingly leaves, pinned so it stays a decision rather than becoming
    /// a surprise: an agent that exits leaving its shell alive keeps the pane and the token it
    /// was bound with, and no installed hook reports the ending, so the pane keeps its place.
    /// Change this test the day the process-group check lands.
    func testAnAgentThatExitsLeavingItsShellAliveIsStillNamed() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let token = UUID()
        roster.ingest(hook(pane: pane, surfaceToken: token, event: "Stop"))

        // `Stop` is a turn boundary, not a session ending — the shell and its surface are
        // exactly as they were.
        XCTAssertEqual(roster.panes(matching: [pane: token]), [pane])
    }

    // MARK: - What keeps it bounded

    func testTheOldestBindingIsEvictedSoAWeekLongSessionCannotGrowItWithoutLimit() {
        let roster = AgentPaneRoster()
        let panes = (0...AgentPaneRoster.capacity).map { _ in UUID() }
        let tokens = Dictionary(uniqueKeysWithValues: panes.map { ($0, UUID()) })

        for pane in panes {
            roster.note(slotID: pane, surfaceToken: tokens[pane]!)
        }

        XCTAssertEqual(roster.bindings.count, AgentPaneRoster.capacity)
        let live = roster.panes(matching: tokens)
        XCTAssertFalse(live.contains(panes[0]), "the oldest binding outlived the cap")
        XCTAssertTrue(live.contains(panes[panes.count - 1]))
    }

    func testANoisyPaneIsNotEvictedByItsOwnRepeatedHooks() {
        let roster = AgentPaneRoster()
        let steady = UUID()
        let steadyToken = UUID()
        var tokens = [steady: steadyToken]
        roster.note(slotID: steady, surfaceToken: steadyToken)

        // The same pane reports over and over, as a working agent does, while a handful of
        // other panes come and go. Re-noting must refresh its place rather than fill the cap.
        for _ in 0..<(AgentPaneRoster.capacity * 2) {
            roster.ingest(hook(pane: steady, surfaceToken: steadyToken))
        }
        for _ in 0..<(AgentPaneRoster.capacity - 1) {
            let other = UUID()
            let token = UUID()
            tokens[other] = token
            roster.note(slotID: other, surfaceToken: token)
        }

        XCTAssertTrue(
            roster.panes(matching: tokens).contains(steady),
            "the pane that kept reporting is the one that got evicted"
        )
    }

    func testTheNewestIncarnationOfASlotReplacesTheOlderOne() {
        let roster = AgentPaneRoster()
        let pane = UUID()
        let old = UUID()
        let new = UUID()

        roster.note(slotID: pane, surfaceToken: old)
        roster.note(slotID: pane, surfaceToken: new)

        XCTAssertEqual(roster.bindings.count, 1)
        XCTAssertEqual(roster.panes(matching: [pane: new]), [pane])
        XCTAssertTrue(roster.panes(matching: [pane: old]).isEmpty)
    }

    // MARK: - AgentHookLensBus's third sink: what counts as the pane's own turn finishing

    /// OSC 133 never fires between an interactive agent's turns — `claude`, `codex`,
    /// `opencode` all stay the shell's one foreground command for the whole session — so
    /// `Stop` is the only signal that a turn actually finished. `isRootTurnBoundary` is what
    /// decides whether one `Stop` reaches `SurfacePool.noteAgentTurnFinished`.
    func testARootSessionsStopIsATurnBoundary() {
        XCTAssertTrue(
            AgentHookLensBus.isRootTurnBoundary(hook(pane: UUID(), surfaceToken: UUID(), event: "Stop"))
        )
    }

    func testASubagentsStopIsNotThePanesTurnBoundary() {
        XCTAssertFalse(
            AgentHookLensBus.isRootTurnBoundary(
                hook(pane: UUID(), surfaceToken: UUID(), agentID: "sub-7", event: "Stop")
            )
        )
    }

    func testAMidTurnHookIsNotATurnBoundary() {
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification"] {
            XCTAssertFalse(
                AgentHookLensBus.isRootTurnBoundary(hook(pane: UUID(), surfaceToken: UUID(), event: event)),
                "\(event) is mid-turn, not the finish"
            )
        }
    }
}
