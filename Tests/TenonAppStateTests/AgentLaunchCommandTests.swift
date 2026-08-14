import Foundation
import XCTest
@testable import TenonApp

/// The composition every caller shares. These assert the command line a person would have
/// typed themselves — the options they always pass, the provider's own resume shape, and,
/// when the agent picked did not write the session, a prompt that hands the other agent the
/// transcript instead of pretending a `--resume` flag exists across providers.
final class AgentLaunchCommandTests: XCTestCase {
    private let claudePath = "/opt/homebrew/bin/claude"
    private let codexPath = "/opt/homebrew/bin/codex"

    // MARK: - The person's own options

    func testAPlainStartPutsThePromptAfterTheOptionsThisPersonAlwaysPasses() throws {
        let plan = try AgentLaunchComposer.plan(
            agent: .claude,
            executablePath: claudePath,
            userArguments: ["--model", "opus"],
            prompt: "Do task T-104",
            session: nil
        )

        XCTAssertEqual(plan.arguments, ["--model", "opus", "Do task T-104"])
        XCTAssertEqual(
            plan.commandLine,
            "'/opt/homebrew/bin/claude' '--model' 'opus' 'Do task T-104'"
        )
        XCTAssertFalse(plan.handoff)
    }

    func testAStartWithNoPromptIsJustTheAgentAsThisPersonRunsIt() throws {
        let plan = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: ["--full-auto"],
            prompt: nil,
            session: nil
        )

        XCTAssertEqual(plan.arguments, ["--full-auto"])
        XCTAssertEqual(plan.commandLine, "'/opt/homebrew/bin/codex' '--full-auto'")
    }

    // MARK: - Resuming the agent's own session

    func testClaudeResumesThroughItsFlagAndCodexThroughItsSubcommand() throws {
        let session = "0199f0c1-2b7a-4d51-9d16-5b6f4a5c33d0"

        let claude = try AgentLaunchComposer.plan(
            agent: .claude,
            executablePath: claudePath,
            userArguments: ["--model", "opus"],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .claude,
                sessionID: session,
                transcriptPath: "/Users/x/.claude/projects/-Users-x-p/\(session).jsonl"
            )
        )
        let codex = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: [],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .codex,
                sessionID: session,
                transcriptPath: nil
            )
        )

        // The person's options come first for both, because `codex` takes its options ahead
        // of the subcommand and `claude` does not care.
        XCTAssertEqual(claude.arguments, ["--model", "opus", "--resume", session])
        XCTAssertEqual(codex.arguments, ["resume", session])
        XCTAssertFalse(claude.handoff)
        XCTAssertFalse(codex.handoff)
    }

    func testResumingItsOwnSessionCarriesAnOpeningPromptWhenOneIsGiven() throws {
        let session = "0199f0c1-2b7a-4d51-9d16-5b6f4a5c33d0"

        let plan = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: [],
            prompt: "Pick up where you left off",
            session: AgentSessionHandoff(
                provider: .codex,
                sessionID: session,
                transcriptPath: nil
            )
        )

        XCTAssertEqual(
            plan.arguments,
            ["resume", session, "Pick up where you left off"]
        )
    }

    // MARK: - Forking the agent's own session

    /// A fork is the provider's own "continue this as a NEW session" spelling — verified
    /// against both installed CLIs: `claude --resume <id> --fork-session`, `codex fork <id>`.
    /// The person's options still come first, exactly as they do for a resume.
    func testClaudeForksThroughItsFlagAndCodexThroughItsSubcommand() throws {
        let session = "0199f0c1-2b7a-4d51-9d16-5b6f4a5c33d0"

        let claude = try AgentLaunchComposer.plan(
            agent: .claude,
            executablePath: claudePath,
            userArguments: ["--model", "opus"],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .claude,
                sessionID: session,
                transcriptPath: "/Users/x/.claude/projects/-Users-x-p/\(session).jsonl",
                continuation: .fork
            )
        )
        let codex = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: ["--full-auto"],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .codex,
                sessionID: session,
                transcriptPath: nil,
                continuation: .fork
            )
        )

        XCTAssertEqual(
            claude.arguments,
            ["--model", "opus", "--resume", session, "--fork-session"]
        )
        XCTAssertEqual(codex.arguments, ["--full-auto", "fork", session])
        XCTAssertFalse(claude.handoff)
        XCTAssertFalse(codex.handoff)
    }

    /// Across providers there is no fork flag either: the same transcript handoff a resume
    /// takes, because a handoff already IS a new session reading a recorded one.
    func testForkingAnotherAgentsSessionStaysTheTranscriptHandoff() throws {
        let path = "/Users/x/.claude/projects/-Users-x-p/0199f0c1.jsonl"

        let plan = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: [],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .claude,
                sessionID: "0199f0c1",
                transcriptPath: path,
                continuation: .fork
            )
        )

        XCTAssertTrue(plan.handoff)
        XCTAssertFalse(plan.arguments.contains("fork"))
        XCTAssertFalse(plan.arguments.contains("--fork-session"))
        XCTAssertTrue(try XCTUnwrap(plan.arguments.last).contains(path))
    }

    // MARK: - Continuing someone else's session

    func testAHandoffPromptNamesTheTranscriptTheOtherAgentMustRead() throws {
        let path = "/Users/x/.claude/projects/-Users-x-p/0199f0c1.jsonl"

        let plan = try AgentLaunchComposer.plan(
            agent: .codex,
            executablePath: codexPath,
            userArguments: ["--full-auto"],
            prompt: nil,
            session: AgentSessionHandoff(
                provider: .claude,
                sessionID: "0199f0c1",
                transcriptPath: path
            )
        )

        XCTAssertTrue(plan.handoff)
        XCTAssertEqual(plan.arguments.count, 2)
        XCTAssertEqual(plan.arguments.first, "--full-auto")
        let handoffPrompt = try XCTUnwrap(plan.arguments.last)
        XCTAssertTrue(
            handoffPrompt.contains(path),
            "the other agent is given the path or it cannot read anything"
        )
        XCTAssertTrue(
            handoffPrompt.contains(AgentCLI.claude.label),
            "it is told which agent wrote the transcript it is about to read"
        )
        // No provider ever grew a flag for another provider's session id.
        XCTAssertFalse(plan.arguments.contains("resume"))
        XCTAssertFalse(plan.arguments.contains("--resume"))
    }

    func testAHandoffKeepsTheCallersOwnPromptAfterTheInstructions() throws {
        let plan = try AgentLaunchComposer.plan(
            agent: .claude,
            executablePath: claudePath,
            userArguments: [],
            prompt: "Then finish the failing test",
            session: AgentSessionHandoff(
                provider: .codex,
                sessionID: "019fe641-4929-7ad2-b104-c5f681496edd",
                transcriptPath: "/Users/x/.codex/sessions/2026/08/09/rollout-019fe641.jsonl"
            )
        )

        let prompt = try XCTUnwrap(plan.arguments.last)
        XCTAssertTrue(prompt.contains("Then finish the failing test"))
        XCTAssertTrue(
            prompt.contains("/Users/x/.codex/sessions/2026/08/09/rollout-019fe641.jsonl")
        )
        XCTAssertEqual(plan.arguments.count, 1, "one prompt, not two")
    }

    func testAHandoffWithoutATranscriptIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(
            try AgentLaunchComposer.plan(
                agent: .claude,
                executablePath: claudePath,
                userArguments: [],
                prompt: nil,
                session: AgentSessionHandoff(
                    provider: .codex,
                    sessionID: "019fe641",
                    transcriptPath: nil
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentLaunchPlanError,
                .handoffTranscriptRequired
            )
        }
    }

    // MARK: - Nothing reaches the shell unquoted

    func testAPromptCarryingQuotesAndNewlinesSurvivesAsOneArgument() throws {
        let plan = try AgentLaunchComposer.plan(
            agent: .claude,
            executablePath: claudePath,
            userArguments: [],
            prompt: "it's two\nlines; rm -rf /",
            session: nil
        )

        XCTAssertEqual(plan.arguments, ["it's two\nlines; rm -rf /"])
        XCTAssertEqual(
            plan.commandLine,
            "'/opt/homebrew/bin/claude' 'it'\\''s two\nlines; rm -rf /'"
        )
    }

    func testASessionIdentifierThatIsNotOneIsRefused() {
        for identifier in ["", "  ", "abc def", "abc;rm -rf /", "--dangerous"] {
            XCTAssertThrowsError(
                try AgentLaunchComposer.plan(
                    agent: .claude,
                    executablePath: claudePath,
                    userArguments: [],
                    prompt: nil,
                    session: AgentSessionHandoff(
                        provider: .claude,
                        sessionID: identifier,
                        transcriptPath: nil
                    )
                ),
                "session id \(identifier) must not reach a command line"
            ) { error in
                XCTAssertEqual(
                    error as? AgentLaunchPlanError,
                    .invalidSessionIdentifier
                )
            }
        }
    }

    func testControlCharactersNeverReachTheCommandLine() {
        XCTAssertThrowsError(
            try AgentLaunchComposer.plan(
                agent: .claude,
                executablePath: claudePath,
                userArguments: [],
                prompt: "kill the pane\u{1B}[2J",
                session: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentLaunchPlanError,
                .unusableText("prompt")
            )
        }
    }

    func testAnExecutableMustBeAnAbsolutePath() {
        XCTAssertThrowsError(
            try AgentLaunchComposer.plan(
                agent: .claude,
                executablePath: "claude",
                userArguments: [],
                prompt: nil,
                session: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentLaunchPlanError,
                .unusableText("executablePath")
            )
        }
    }
}
