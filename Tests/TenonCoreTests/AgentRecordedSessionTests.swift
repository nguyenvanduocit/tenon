import Foundation
@testable import TenonCore
import XCTest

/// T-126 — a pane holding a session that has already happened.
///
/// Every rule here is a workspace-value rule, so all of it is asserted without a window: what a
/// reference is allowed to be, which pane the next recorded session lands in, what the pane
/// publishes about itself, and what comes back after a restart when the transcript it named is
/// no longer there.
final class AgentRecordedSessionTests: XCTestCase {
    private let anyDirectory: (String) -> Bool = { _ in true }
    private let anyFile: (String) -> Bool = { _ in true }
    private let anyPluginView: (String, String) -> Bool = { _, _ in true }

    private func ref(
        provider: AgentSessionProvider = .claude,
        sessionID: String = "0c86fb73-1111-2222-3333-444455556666",
        path: String = "/Users/x/.claude/projects/proj/0c86fb73.jsonl",
        title: String? = nil
    ) -> AgentSessionRef {
        AgentSessionRef(
            provider: provider,
            sessionID: sessionID,
            transcriptPath: path,
            title: title
        )!
    }

    // MARK: - The reference is bounded at the door

    /// The first caller is a plugin: the Agent Sessions list hands the host a path and an id it
    /// chose. A reference that cannot be trusted must fail to EXIST, rather than become a pane
    /// that draws something broken.
    func testAReferenceRefusesEveryShapeItCannotVouchFor() {
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            ),
            "a session with no id names nothing"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "   ",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            ),
            "whitespace is not an id"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: String(repeating: "a", count: AgentSessionRef.sessionIDLimit + 1),
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            )
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "../../etc",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            ),
            "an id lands in a bus value and a pane title; it is not a path"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "s",
                transcriptPath: ".claude/projects/p/s.jsonl"
            ),
            "a relative transcript path is refused on shape alone"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "s",
                transcriptPath: "/Users/x/.claude/projects/p/s.txt"
            ),
            "a transcript is a .jsonl"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "s\nwrapped",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            ),
            "a newline in an id would forge a second row wherever it is written"
        )
    }

    /// A transcript's file shape is a property of its provider: Codex and Claude Code write
    /// `.jsonl`, opencode writes one `.db` for every session. A shape that does not belong to
    /// the named provider is refused on shape alone, before any containment question.
    func testAReferenceRequiresTheProvidersOwnTranscriptShape() {
        XCTAssertNotNil(
            AgentSessionRef(
                provider: .opencode,
                sessionID: "ses_abc",
                transcriptPath: "/Users/x/.local/share/opencode/opencode.db"
            ),
            "an opencode session is a .db"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .opencode,
                sessionID: "ses_abc",
                transcriptPath: "/Users/x/.local/share/opencode/opencode.jsonl"
            ),
            "an opencode session is not a .jsonl"
        )
        XCTAssertNil(
            AgentSessionRef(
                provider: .claude,
                sessionID: "s",
                transcriptPath: "/Users/x/.local/share/opencode/opencode.db"
            ),
            "a Claude session is not a .db"
        )
    }

    func testATitleIsTrimmedBoundedAndOptional() {
        XCTAssertNil(ref(title: "   ").title, "an empty title is no title")
        XCTAssertEqual(ref(title: "  Fix the tab drag  ").title, "Fix the tab drag")
        XCTAssertEqual(
            ref(title: String(repeating: "t", count: AgentSessionRef.titleLimit + 99))
                .title?.count,
            AgentSessionRef.titleLimit
        )
        XCTAssertEqual(ref(title: nil).displayName, "claude 0c86fb73")
        XCTAssertEqual(ref(title: "Fix the tab drag").displayName, "Fix the tab drag")
    }

    // MARK: - Where the next recorded session lands

    /// Browsing a session list is the same motion as browsing a file tree, and the same rule
    /// applies: opening five sessions in a row leaves one pane, not five.
    func testARecordedPaneTakesTheNextRecordedSession() {
        let first = SlotContent.agentSession(ref(sessionID: "first-session"))
        let second = SlotContent.agentSession(ref(sessionID: "second-session"))

        XCTAssertTrue(first.yieldsPane(to: second))
        XCTAssertTrue(SlotContent.empty.yieldsPane(to: second))
    }

    /// It is a different KIND of pane, so it neither steals another pane nor gives its own away.
    /// A live terminal in particular must never be replaced by a recording of one.
    func testARecordedPaneNeitherTakesNorYieldsToAnyOtherKind() {
        let recorded = SlotContent.agentSession(ref())

        XCTAssertFalse(recorded.yieldsPane(to: .terminal))
        XCTAssertFalse(recorded.yieldsPane(to: .changes))
        XCTAssertFalse(recorded.yieldsPane(to: .file(path: "/tmp/a.txt")))
        XCTAssertFalse(SlotContent.terminal.yieldsPane(to: recorded))
        XCTAssertFalse(SlotContent.changes.yieldsPane(to: recorded))
        XCTAssertFalse(SlotContent.file(path: "/tmp/a.txt").yieldsPane(to: recorded))
    }

    /// The bus value names the session and deliberately not its path: it is read by plugins and
    /// written into diagnostics, and a home directory is not part of a pane's identity.
    func testTheBusValueCarriesProviderAndSessionAndNotTheTranscriptPath() {
        let value = SlotContent.agentSession(ref(
            provider: .codex,
            sessionID: "rollout-2026-08-11",
            path: "/Users/secretname/.codex/sessions/2026/rollout.jsonl"
        )).busValue

        XCTAssertEqual(value, "agent-session:codex:rollout-2026-08-11")
        XCTAssertFalse(value.contains("secretname"))
    }

    // MARK: - What comes back after a restart

    func testARecordedPaneSurvivesCaptureAndRestore() throws {
        let recorded = ref(title: "Fix the tab drag")
        let catalog = try makeCatalog(content: .agentSession(recorded))

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: encoded
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(
            restored.catalog.activeTab?.activeSlot?.content,
            .agentSession(recorded),
            "provider, session id, transcript, and title all survive the round trip"
        )
    }

    /// A transcript that is gone is the whole content — there is nothing the pane could
    /// honestly draw — so it comes back as the blank pane holding its place in the layout.
    func testARecordedPaneWhoseTranscriptIsGoneComesBackEmpty() throws {
        let catalog = try makeCatalog(content: .agentSession(ref()))
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: { _ in false },
            isKnownPluginView: anyPluginView
        ))

        XCTAssertEqual(restored.catalog.activeTab?.activeSlot?.content, .empty)
        XCTAssertEqual(
            restored.catalog.activeTab?.slots.count,
            1,
            "the pane keeps its place in the layout; only its content is gone"
        )
    }

    /// A provider this build does not know is not a pane either. The catalog is a file on disk
    /// that an older or newer build may have written.
    func testARecordedPaneNamingAnUnknownProviderComesBackEmpty() throws {
        let record = WorkspaceCatalogSnapshot.ContentRecord(
            type: "agentSession",
            agentSession: WorkspaceCatalogSnapshot.AgentSessionRecord(
                provider: "gemini",
                sessionID: "s",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl",
                title: nil
            )
        )

        XCTAssertEqual(
            restoredContent(of: record),
            .empty,
            "an unrecognised provider is refused rather than guessed at"
        )
    }

    /// The bounds hold on the way back IN, too: a catalog is a file, and a file can be edited.
    func testARecordedPaneWhoseStoredReferenceIsMalformedComesBackEmpty() throws {
        let record = WorkspaceCatalogSnapshot.ContentRecord(
            type: "agentSession",
            agentSession: WorkspaceCatalogSnapshot.AgentSessionRecord(
                provider: "claude",
                sessionID: "",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl",
                title: nil
            )
        )

        XCTAssertEqual(restoredContent(of: record), .empty)
    }

    // MARK: - Helpers

    private func makeCatalog(content: SlotContent) throws -> WorkspaceCatalog {
        let slot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: content
        )
        let tab = Tab(slots: [slot], activeSlotID: slot.id)
        let workspace = Workspace(
            name: "Alpha",
            path: URL(fileURLWithPath: "/tmp/tenon-recorded"),
            tabs: [tab],
            activeTabID: tab.id
        )
        return WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
    }

    private func restoredContent(
        of record: WorkspaceCatalogSnapshot.ContentRecord
    ) -> SlotContent? {
        guard let catalog = try? makeCatalog(content: .terminal) else { return nil }
        var document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        document.workspaces[0].tabs[0].slots[0].content = record
        return WorkspaceCatalogSnapshot.restore(
            document,
            isDirectory: anyDirectory,
            isFileReadable: anyFile,
            isKnownPluginView: anyPluginView
        )?.catalog.activeTab?.activeSlot?.content
    }
}
