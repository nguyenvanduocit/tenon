import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-145 / `WS-FR-027` — which live panes are agent panes at quit, and what a restart is
/// allowed to claim about them.
///
/// All of it without a window: the eligibility rule is a pure function over the reading the
/// pane was already showing, and the capture walk takes its two facts as closures, so the
/// terminal pool and the discovery actor stay out of the assertion.
final class AgentPaneSessionCaptureTests: XCTestCase {
    private let transcript = URL(
        fileURLWithPath: "/tmp/tenon-capture/9f1c4d10.jsonl"
    )

    private func resolution(
        provider: AgentProvider = .claude,
        sessionID: String? = "9f1c4d10-0000-4000-8000-000000000001",
        transcriptURL: URL? = URL(fileURLWithPath: "/tmp/tenon-capture/9f1c4d10.jsonl"),
        confidence: AgentResolutionConfidence = .exact
    ) -> AgentLensResolution {
        AgentLensResolution(
            provider: provider,
            sessionID: sessionID,
            foregroundPID: 4242,
            transcriptURL: transcriptURL,
            confidence: confidence,
            detail: "fixture"
        )
    }

    private func identity(
        slotID: UUID,
        title: String = "claude — tenon"
    ) -> AgentTerminalIdentity {
        AgentTerminalIdentity(
            slotID: slotID,
            surfaceToken: UUID(),
            foregroundPID: 4242,
            cwd: URL(fileURLWithPath: "/tmp/tenon-capture", isDirectory: true),
            title: title
        )
    }

    // MARK: - What may become a reference

    func testAnExactReadingBecomesTheReferenceARestoredPaneReads() throws {
        let ref = try XCTUnwrap(AgentPaneSessionCapture.reference(
            for: resolution(),
            title: "claude — tenon"
        ))

        XCTAssertEqual(ref.provider, .claude)
        XCTAssertEqual(ref.sessionID, "9f1c4d10-0000-4000-8000-000000000001")
        XCTAssertEqual(ref.transcriptPath, transcript.path)
        XCTAssertEqual(
            ref.title,
            "claude — tenon",
            "the pane keeps the name it had on the tab, so nothing is renamed by a restart"
        )
    }

    func testACodexReadingCrossesToTheWorkspacesOwnNameForThatProvider() throws {
        let ref = try XCTUnwrap(AgentPaneSessionCapture.reference(
            for: resolution(provider: .codex),
            title: nil
        ))

        XCTAssertEqual(ref.provider, .codex)
    }

    func testAnInferredReadingIsRefusedBecauseAGuessMustNotSurviveARestart() {
        XCTAssertNil(AgentPaneSessionCapture.reference(
            for: resolution(confidence: .inferred),
            title: nil
        ))
    }

    func testAProcessOnlyReadingIsRefusedBecauseThereIsNoTranscriptToShow() {
        XCTAssertNil(AgentPaneSessionCapture.reference(
            for: resolution(transcriptURL: nil, confidence: .processOnly),
            title: nil
        ))
    }

    func testAnExactReadingWithNoSessionIDNamesNothingToResume() {
        XCTAssertNil(
            AgentPaneSessionCapture.reference(for: resolution(sessionID: nil), title: nil),
            "the open-descriptor branch proves the file and not the session, and a pane that "
                + "cannot be resumed must not be offered as one"
        )
    }

    func testAPathThatIsNotATranscriptIsRefusedByTheValueTypeItself() {
        XCTAssertNil(AgentPaneSessionCapture.reference(
            for: resolution(transcriptURL: URL(fileURLWithPath: "/tmp/tenon-capture/notes.txt")),
            title: nil
        ))
    }

    func testAnEmptyTerminalTitleLeavesTheSessionToNameItself() throws {
        let ref = try XCTUnwrap(AgentPaneSessionCapture.reference(
            for: resolution(),
            title: "   "
        ))

        XCTAssertNil(ref.title)
        XCTAssertEqual(ref.displayName, "claude 9f1c4d10")
    }

    // MARK: - Which panes are asked at all

    func testOnlyPanesHoldingATerminalAreAsked() throws {
        let terminal = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 6, height: 12),
            content: .terminal
        )
        let recorded = WorkspaceSlot(
            rect: GridRect(x: 6, y: 0, width: 6, height: 12),
            content: .agentSession(try XCTUnwrap(AgentSessionRef(
                provider: .claude,
                sessionID: "already-recorded",
                transcriptPath: transcript.path,
                title: nil
            )))
        )
        let tab = Tab(slots: [terminal, recorded], activeSlotID: terminal.id)
        let workspace = Workspace(
            name: "Alpha",
            path: URL(fileURLWithPath: "/tmp/tenon-capture", isDirectory: true),
            tabs: [tab],
            activeTabID: tab.id
        )
        let catalog = WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )

        XCTAssertEqual(AgentPaneSessionCapture.terminalSlotIDs(in: catalog), [terminal.id])
    }

    @MainActor
    func testTheCaptureKeepsTheAgentPanesAndSkipsTheShells() async {
        let agentPane = UUID()
        let shellPane = UUID()
        let exitedPane = UUID()

        let sessions = await AgentPaneSessionCapture.sessions(
            terminalSlotIDs: [agentPane, shellPane, exitedPane],
            identity: { slotID in
                // A pane whose surface has gone has no identity to offer, which is how a
                // closed shell contributes nothing rather than a stale reading.
                slotID == exitedPane ? nil : self.identity(slotID: slotID)
            },
            resolve: { identity in
                // The shell is not an agent, so discovery answers nothing about it.
                identity.slotID == shellPane ? nil : self.resolution()
            }
        )

        XCTAssertEqual(Set(sessions.keys), [agentPane])
        XCTAssertEqual(sessions[agentPane]?.sessionID, "9f1c4d10-0000-4000-8000-000000000001")
    }
}
