import Foundation
@testable import TenonApp
import TenonCore
import TenonIntentCore
import XCTest

/// T-126 — what a pane reading a finished session may do, and how it is picked up again.
///
/// All of it is asserted without a window: the attachment is a value, the resume offer is a
/// pure composition, and the refusal that keeps a plugin from naming an arbitrary file is a
/// pure parse. The one rule that needs a real filesystem — containment after symlinks — gets
/// a real symlink.
final class AgentSessionResumeTests: XCTestCase {
    private func ref(
        provider: AgentSessionProvider = .claude,
        sessionID: String = "0c86fb73-1111-2222-3333-444455556666",
        path: String = "/Users/x/.claude/projects/proj/0c86fb73.jsonl"
    ) -> AgentSessionRef {
        AgentSessionRef(provider: provider, sessionID: sessionID, transcriptPath: path)!
    }

    private func suggestion(
        _ agent: AgentCLI,
        arguments: [String] = []
    ) -> AgentLaunchSuggestion {
        AgentLaunchSuggestion(
            agent: agent,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/\(agent.rawValue)"),
            arguments: arguments
        )
    }

    // MARK: - What the attachment permits

    /// Every capability a live pane has follows from there being a process. A recorded pane
    /// has none, and states that once rather than leaving each view to re-derive it.
    func testARecordedAttachmentPermitsNoneOfWhatALiveOneDoes() {
        let recorded = AgentLensAttachment.recorded(ref())

        XCTAssertFalse(recorded.startsDiscovery, "there is no process to find")
        XCTAssertFalse(recorded.allowsSending, "there is nothing to type into")
        XCTAssertFalse(recorded.holdsTerminalSurface, "a PTY would start a shell nobody asked for")
        XCTAssertTrue(recorded.offersResume)

        XCTAssertTrue(AgentLensAttachment.live.startsDiscovery)
        XCTAssertTrue(AgentLensAttachment.live.allowsSending)
        XCTAssertTrue(AgentLensAttachment.live.holdsTerminalSurface)
        XCTAssertFalse(AgentLensAttachment.live.offersResume)
        XCTAssertNil(AgentLensAttachment.live.resolution)
    }

    /// The transcript was named by the session list and proven to resolve under a provider
    /// root before the reference existed, which is a stronger claim than a cwd match.
    func testARecordedAttachmentResolvesExactlyToItsOwnTranscript() throws {
        let resolution = try XCTUnwrap(
            AgentLensAttachment.recorded(ref(provider: .codex)).resolution
        )

        XCTAssertEqual(resolution.provider, .codex)
        XCTAssertEqual(resolution.confidence, .exact)
        XCTAssertEqual(
            resolution.transcriptURL?.path,
            "/Users/x/.claude/projects/proj/0c86fb73.jsonl"
        )
        XCTAssertEqual(resolution.foregroundPID, 0, "there is no process")
    }

    // MARK: - The pane itself

    @MainActor
    func testARecordedPaneCanNeverSendWhateverTheTranscriptSays() {
        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: nil,
            discovery: AgentLensDiscovery(),
            attachment: .recorded(ref())
        )

        // Everything else `canSend` asks for, said yes: a draft is typed, nothing is in
        // flight. The attachment is the only reason left for the answer to be no.
        model.draft = "please continue"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(
            model.attachment.recordedSession,
            ref(),
            "the pane holds the session it was opened with"
        )
    }

    @MainActor
    func testARecordedPaneOpensOnItsReadingRatherThanOnAnEmptyTerminal() {
        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: nil,
            discovery: AgentLensDiscovery(),
            attachment: .recorded(ref())
        )

        XCTAssertEqual(model.mode, .session)
    }

    /// The whole promise of the pane: it reads the session with Agent Lens itself, over a real
    /// transcript on disk, with no PTY and no discovery anywhere in the path. Both accounts are
    /// then available over that one reading — the Timeline is a projection of the same snapshot
    /// the chat spine draws, which is why it needs nothing here beyond the reading arriving.
    @MainActor
    func testARecordedPaneReadsItsTranscriptWithNoTerminalAndNoDiscovery() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-recorded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"assistant","uuid":"recorded-1","message":{"content":[{"type":"text","text":"The tab drag is fixed."}]}}

        """.utf8).write(to: transcript)

        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: nil,
            discovery: AgentLensDiscovery(),
            attachment: .recorded(try XCTUnwrap(AgentSessionRef(
                provider: .claude,
                sessionID: "recorded-session",
                transcriptPath: transcript.path
            )))
        )
        model.start()
        defer { model.stop() }

        var text: String?
        for _ in 0 ..< 60 where text == nil {
            try await Task.sleep(for: .milliseconds(50))
            text = model.snapshot.messages.last?.text
        }

        XCTAssertEqual(text, "The tab drag is fixed.", "the recorded transcript was read")
        XCTAssertEqual(model.resolution?.provider, .claude)
        XCTAssertFalse(model.canSend, "reading a session never makes it answerable")

        model.account = .timeline
        XCTAssertEqual(model.account, .timeline, "both accounts are available over one reading")
    }

    // MARK: - Resuming

    /// Composed through `AgentLaunchComposer`, so the options this person actually runs their
    /// agent with come along — the same line the Launcher and the sessions plugin would get.
    func testResumeSpellsTheProvidersOwnResumeAndKeepsThePersonsOptions() throws {
        let offer = AgentSessionResume.offer(
            for: ref(sessionID: "abc-123"),
            installed: [suggestion(.claude, arguments: ["--model", "opus"])]
        )
        let commandLine = try XCTUnwrap(offer.commandLine)

        XCTAssertTrue(commandLine.contains("--resume"), commandLine)
        XCTAssertTrue(commandLine.contains("abc-123"), commandLine)
        XCTAssertTrue(commandLine.contains("--model"), commandLine)
        XCTAssertTrue(commandLine.contains("opus"), commandLine)
        XCTAssertNil(offer.reason)
    }

    func testCodexResumesTheWayCodexSpellsIt() throws {
        let offer = AgentSessionResume.offer(
            for: ref(
                provider: .codex,
                sessionID: "rollout-99",
                path: "/Users/x/.codex/sessions/2026/rollout-99.jsonl"
            ),
            installed: [suggestion(.codex)]
        )
        let commandLine = try XCTUnwrap(offer.commandLine)

        XCTAssertTrue(commandLine.contains("resume"), commandLine)
        XCTAssertTrue(commandLine.contains("rollout-99"), commandLine)
        XCTAssertFalse(commandLine.contains("--resume"), "that is Claude Code's spelling")
    }

    /// The fork continuation composes through the same offer: the same installed check, the
    /// same reasons, one more word in the spelling. Claude Code forks with `--fork-session`
    /// on top of its resume; a plain resume must never grow that flag.
    func testAForkOfferSpellsANewSessionAndAResumeOfferDoesNot() throws {
        let reference = ref(sessionID: "abc-123")
        let installed = [suggestion(.claude, arguments: ["--model", "opus"])]

        let fork = AgentSessionResume.offer(
            for: reference,
            installed: installed,
            continuation: .fork
        )
        let resume = AgentSessionResume.offer(for: reference, installed: installed)

        let forkLine = try XCTUnwrap(fork.commandLine)
        XCTAssertTrue(forkLine.contains("--resume"), forkLine)
        XCTAssertTrue(forkLine.contains("--fork-session"), forkLine)
        XCTAssertTrue(forkLine.contains("--model"), "the person's options still come along")
        XCTAssertFalse(
            try XCTUnwrap(resume.commandLine).contains("--fork-session"),
            "a resume continues the session it names; only a fork mints a new one"
        )
    }

    func testCodexForksTheWayCodexSpellsIt() throws {
        let offer = AgentSessionResume.offer(
            for: ref(
                provider: .codex,
                sessionID: "rollout-99",
                path: "/Users/x/.codex/sessions/2026/rollout-99.jsonl"
            ),
            installed: [suggestion(.codex)],
            continuation: .fork
        )
        let commandLine = try XCTUnwrap(offer.commandLine)

        XCTAssertTrue(commandLine.contains("'fork' 'rollout-99'"), commandLine)
        XCTAssertFalse(commandLine.contains("--fork-session"), "that is Claude Code's spelling")
    }

    /// A button that fails on press teaches nothing. The reason is computed before it is
    /// pressed, and it names the agent rather than reporting a code.
    func testAnAgentThisMachineLacksIsRefusedWithAStatedReason() throws {
        let offer = AgentSessionResume.offer(
            for: ref(),
            installed: [suggestion(.codex)]
        )

        XCTAssertNil(offer.commandLine, "nothing is composed for an agent that is not here")
        let reason = try XCTUnwrap(offer.reason)
        XCTAssertTrue(reason.contains("Claude Code"), reason)
        XCTAssertTrue(reason.contains("not installed"), reason)
    }

    func testASessionIdentifierTheCLICannotResumeIsRefusedWithItsOwnReason() throws {
        // Bounded by `AgentSessionRef`, but not to the narrower shape the CLI accepts: a
        // space is a legal id here and not a resumable one, so the two rules disagree and
        // the offer is where that disagreement is reported.
        let awkward = try XCTUnwrap(
            AgentSessionRef(
                provider: .claude,
                sessionID: "not an id",
                transcriptPath: "/Users/x/.claude/projects/p/s.jsonl"
            )
        )
        let offer = AgentSessionResume.offer(for: awkward, installed: [suggestion(.claude)])

        XCTAssertNil(offer.commandLine)
        XCTAssertTrue(try XCTUnwrap(offer.reason).contains("identifier"), "\(offer)")
    }

    // MARK: - The door a plugin knocks on

    /// The first caller is a plugin naming a file on this person's disk. Containment is
    /// decided here, after symlinks, and refusal is typed input-invalid — so no pane opens
    /// and nothing partial is built.
    func testAPluginNamingATranscriptOutsideTheProviderRootsIsRefused() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-resume-\(UUID().uuidString)", isDirectory: true)
        let projects = home.appendingPathComponent(".claude/projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = AgentTranscriptPath.allowedRoots(home: home)

        let inside = projects.appendingPathComponent("session.jsonl")
        try Data().write(to: inside)
        let outside = home.appendingPathComponent("stolen.jsonl")
        try Data().write(to: outside)

        XCTAssertEqual(
            try WorkspaceIntentProvider.content(
                from: contentValue(transcriptPath: inside.path),
                transcriptRoots: roots
            ),
            .agentSession(try XCTUnwrap(AgentSessionRef(
                provider: .claude,
                sessionID: "abc",
                transcriptPath: inside.resolvingSymlinksInPath().standardizedFileURL.path
            )))
        )

        XCTAssertThrowsError(
            try WorkspaceIntentProvider.content(
                from: contentValue(transcriptPath: outside.path),
                transcriptRoots: roots
            ),
            "a path outside every provider root opens no pane"
        )

        // The name a caller wrote is never what is checked: this one is inside the root and
        // resolves out of it.
        let link = projects.appendingPathComponent("looks-contained.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try WorkspaceIntentProvider.content(
                from: contentValue(transcriptPath: link.path),
                transcriptRoots: roots
            ),
            "the resolved path is what is checked, not the name that was written"
        )
    }

    func testAnUnknownProviderNamedByAPluginIsRefused() {
        XCTAssertThrowsError(
            try WorkspaceIntentProvider.content(
                from: .object([
                    "kind": .string("agentSession"),
                    "provider": .string("gemini"),
                    "sessionID": .string("abc"),
                    "transcriptPath": .string("/Users/x/.claude/projects/p/s.jsonl"),
                ]),
                transcriptRoots: [URL(fileURLWithPath: "/Users/x/.claude/projects")]
            )
        )
    }

    private func contentValue(transcriptPath: String) -> IntentValue {
        .object([
            "kind": .string("agentSession"),
            "provider": .string("claude"),
            "sessionID": .string("abc"),
            "transcriptPath": .string(transcriptPath),
        ])
    }
}
