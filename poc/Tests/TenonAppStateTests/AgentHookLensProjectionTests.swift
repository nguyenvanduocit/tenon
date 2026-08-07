import Foundation
@testable import TenonApp
import XCTest

/// The hook transport is what makes the Session view live for Claude Code: its transcript
/// is written at turn boundaries, so a running tool and a waiting question exist nowhere
/// on disk while a human is looking at them. These pin the projection from hook fact to
/// lens fact, without a window and without a provider process.
final class AgentHookLensProjectionTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreToolUseProjectsARunningToolUnderTheProvidersOwnIdentity() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PreToolUse",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01Live",
                    toolInputJSON: jsonText([
                        "command": "swift test --filter AgentLens",
                        "description": "Run the lens suite",
                    ])
                )
            ),
            at: capturedAt
        )

        guard case let .toolStarted(tool) = try XCTUnwrap(events.first) else {
            return XCTFail("A started tool is the fact PreToolUse carries")
        }
        // The transcript later writes this same id, which is how one call stays one run.
        XCTAssertEqual(tool.id, "toolu_01Live")
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.kind, .command)
        XCTAssertEqual(tool.summary, "swift test --filter AgentLens")
        XCTAssertEqual(tool.state, .running)
        XCTAssertEqual(tool.evidence.source, .providerHook)
        XCTAssertEqual(tool.evidence.capturedAt, capturedAt)
    }

    func testAskUserQuestionBecomesAPendingInteractionCarryingItsOptions() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PreToolUse",
                activity: AgentHookActivity(
                    toolName: "AskUserQuestion",
                    toolUseID: "toolu_01Ask",
                    toolInputJSON: jsonText([
                        "questions": [
                            [
                                "question": "Which doctor did you mean?",
                                "header": "Doctor",
                                "multiSelect": false,
                                "options": [
                                    ["label": "remember:doctor", "description": "Diagnose Remember"],
                                    ["label": "omc-doctor", "description": "Diagnose OMC"],
                                ],
                            ],
                        ],
                    ])
                )
            ),
            at: capturedAt
        )

        let request = try XCTUnwrap(
            events.compactMap { event -> AgentInteractionRequest? in
                guard case let .interactionRequested(request) = event else { return nil }
                return request
            }.first
        )
        XCTAssertEqual(request.id, "toolu_01Ask-0")
        XCTAssertEqual(request.kind, .question)
        XCTAssertEqual(request.title, "Which doctor did you mean?")
        XCTAssertEqual(request.state, .pending)
        XCTAssertEqual(request.options.map(\.label), ["remember:doctor", "omc-doctor"])
        XCTAssertEqual(request.options.first?.detail, "Diagnose Remember")
        XCTAssertEqual(request.evidence.source, .providerHook)
    }

    func testEveryQuestionInOneAskGetsItsOwnPendingDecision() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PreToolUse",
                activity: AgentHookActivity(
                    toolName: "AskUserQuestion",
                    toolUseID: "toolu_01Two",
                    toolInputJSON: jsonText([
                        "questions": [
                            ["question": "Scope?", "header": "Scope", "options": [["label": "All"]]],
                            ["question": "When?", "header": "When", "options": [["label": "Now"]]],
                        ],
                    ])
                )
            ),
            at: capturedAt
        )

        let requests = events.compactMap { event -> AgentInteractionRequest? in
            guard case let .interactionRequested(request) = event else { return nil }
            return request
        }
        XCTAssertEqual(requests.map(\.id), ["toolu_01Two-0", "toolu_01Two-1"])
        XCTAssertEqual(requests.map(\.title), ["Scope?", "When?"])
    }

    func testPostToolUseCompletesTheRunAndCarriesWhatTheCommandSaid() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PostToolUse",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01Live",
                    toolInputJSON: jsonText(["command": "swift test"]),
                    toolResponseJSON: jsonText([
                        "stdout": "Executed 1006 tests, with 0 failures",
                        "stderr": "",
                        "interrupted": false,
                    ])
                )
            ),
            at: capturedAt
        )

        guard case let .toolFinished(tool) = try XCTUnwrap(events.first) else {
            return XCTFail("A finished tool is the fact PostToolUse carries")
        }
        XCTAssertEqual(tool.id, "toolu_01Live")
        XCTAssertEqual(tool.state, .succeeded)
        XCTAssertTrue(tool.detail.contains("Executed 1006 tests, with 0 failures"))
    }

    func testAFailedCommandKeepsItsExitStatusInsteadOfReadingAsSuccess() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PostToolUse",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01Fail",
                    toolInputJSON: jsonText(["command": "swift build"]),
                    toolResponseJSON: "\"Error: Exit code 2\\nerror: no such module\"",
                    isToolError: true
                )
            ),
            at: capturedAt
        )

        guard case let .toolFinished(tool) = try XCTUnwrap(events.first) else {
            return XCTFail("A failed tool is still a finished tool")
        }
        XCTAssertEqual(tool.state, .failed)
        XCTAssertEqual(tool.exitCode, 2)
        XCTAssertTrue(tool.detail.contains("no such module"))
    }

    func testAnInterruptedCommandIsNotReportedAsSucceeded() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PostToolUse",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01Stop",
                    toolResponseJSON: jsonText([
                        "stdout": "",
                        "stderr": "",
                        "interrupted": true,
                    ])
                )
            ),
            at: capturedAt
        )

        guard case let .toolFinished(tool) = try XCTUnwrap(events.first) else {
            return XCTFail("An interrupted tool still finishes")
        }
        XCTAssertEqual(tool.state, .declined)
    }

    func testAnsweringTheQuestionResolvesEveryDecisionItRaised() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PostToolUse",
                activity: AgentHookActivity(
                    toolName: "AskUserQuestion",
                    toolUseID: "toolu_01Two",
                    toolInputJSON: jsonText([
                        "questions": [
                            ["question": "Scope?", "header": "Scope", "options": [["label": "All"]]],
                            ["question": "When?", "header": "When", "options": [["label": "Now"]]],
                        ],
                    ]),
                    toolResponseJSON: jsonText([
                        "questions": ["Scope?", "When?"],
                        "answers": ["All", "Now"],
                    ])
                )
            ),
            at: capturedAt
        )

        let resolved = events.compactMap { event -> String? in
            guard case let .interactionResolved(id, _) = event else { return nil }
            return id
        }
        XCTAssertEqual(resolved, ["toolu_01Two-0", "toolu_01Two-1"])
    }

    func testStopEndsTheTurnWithoutInventingProseTheTranscriptOwns() throws {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "Stop",
                activity: AgentHookActivity(lastAssistantMessage: "All done.")
            ),
            at: capturedAt
        )

        XCTAssertFalse(
            events.contains { event in
                if case .assistantMessage = event { return true }
                if case .assistantDelta = event { return true }
                return false
            },
            "Prose carries evidence offsets only from the transcript; the hook must not duplicate it"
        )
        guard case let .status(status, _) = try XCTUnwrap(events.first) else {
            return XCTFail("Stop reports the end of a turn")
        }
        XCTAssertEqual(status, .completed)
    }

    func testNotificationRaisesTheWaitingStateAndClearsWhenWorkResumes() throws {
        let waiting = AgentHookLensProjection.events(
            for: hookEvent(
                name: "Notification",
                activity: AgentHookActivity(
                    message: "Claude needs your permission to use Bash"
                )
            ),
            at: capturedAt
        )

        guard case let .interactionRequested(request) = try XCTUnwrap(waiting.first) else {
            return XCTFail("A notification is a decision waiting on a human")
        }
        XCTAssertEqual(request.kind, .approval)
        XCTAssertEqual(request.title, "Claude needs your permission to use Bash")
        XCTAssertEqual(request.state, .pending)

        let resumed = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PreToolUse",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01After",
                    toolInputJSON: jsonText(["command": "ls"])
                )
            ),
            at: capturedAt
        )
        XCTAssertTrue(
            resumed.contains { event in
                guard case let .interactionResolved(id, _) = event else { return false }
                return id == request.id
            },
            "Work resuming is the evidence that the human already answered"
        )
    }

    func testSubagentHookFactsStayOutOfTheRootSessionTimeline() {
        let events = AgentHookLensProjection.events(
            for: hookEvent(
                name: "PreToolUse",
                agentID: "subagent-7",
                activity: AgentHookActivity(
                    toolName: "Bash",
                    toolUseID: "toolu_01Sub",
                    toolInputJSON: jsonText(["command": "ls"])
                )
            ),
            at: capturedAt
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testAHookWithoutTheFactsItClaimsProjectsNothing() {
        XCTAssertTrue(
            AgentHookLensProjection.events(
                for: hookEvent(name: "PreToolUse", activity: AgentHookActivity()),
                at: capturedAt
            ).isEmpty
        )
        XCTAssertTrue(
            AgentHookLensProjection.events(
                for: hookEvent(name: "PreCompact", activity: AgentHookActivity()),
                at: capturedAt
            ).isEmpty
        )
    }

    func testClaudeToolsAreNamedByWhatTheyDoInsteadOfTheirRawArguments() throws {
        let cases: [(String, [String: Any], AgentToolKind, String)] = [
            ("Bash", ["command": "git status"], .command, "git status"),
            ("Read", ["file_path": "/repo/poc/Package.swift"], .fileRead, "poc/Package.swift"),
            ("Write", ["file_path": "/repo/notes.md", "content": "x"], .fileChange, "notes.md"),
            ("Edit", ["file_path": "/repo/a/b/Main.swift"], .fileChange, "a/b/Main.swift"),
            ("Grep", ["pattern": "AgentLens", "path": "poc"], .search, "AgentLens in poc"),
            ("Glob", ["pattern": "**/*.swift"], .search, "**/*.swift"),
            ("WebFetch", ["url": "https://example.com/a"], .webSearch, "https://example.com/a"),
            ("WebSearch", ["query": "swift 6 actors"], .webSearch, "swift 6 actors"),
            ("Task", ["description": "Audit the decoder"], .subagent, "Audit the decoder"),
            ("AskUserQuestion", ["questions": [["question": "Which?"]]], .question, "Which?"),
        ]

        for (name, input, kind, summary) in cases {
            let presentation = ClaudeToolFacts.presentation(
                toolName: name,
                input: input,
                workspaceRoot: "/repo"
            )
            XCTAssertEqual(presentation.kind, kind, "\(name) kind")
            XCTAssertEqual(presentation.summary, summary, "\(name) summary")
            XCTAssertFalse(
                presentation.summary.hasPrefix("{"),
                "\(name) must not render as raw JSON"
            )
        }
    }

    func testACompletedToolIsNeverReopenedByALaterRecordOfItsStart() {
        var reducer = AgentLensReducer()
        let evidence = AgentEvidence(
            source: .providerHook,
            authority: .reported,
            location: "hook",
            byteOffset: nil,
            fingerprint: "",
            capturedAt: capturedAt,
            freshness: .current
        )
        reducer.apply(
            .toolStarted(
                AgentToolRun(
                    id: "toolu_01Race",
                    name: "Bash",
                    kind: .command,
                    summary: "swift test",
                    detail: "",
                    state: .running,
                    exitCode: nil,
                    evidence: evidence
                )
            )
        )
        reducer.apply(
            .toolFinished(
                AgentToolRun(
                    id: "toolu_01Race",
                    name: "Bash",
                    kind: .command,
                    summary: "swift test",
                    detail: "1006 tests",
                    state: .succeeded,
                    exitCode: 0,
                    evidence: evidence
                )
            )
        )
        // The transcript flushes the same call minutes later, still describing its start.
        reducer.apply(
            .toolStarted(
                AgentToolRun(
                    id: "toolu_01Race",
                    name: "Bash",
                    kind: .command,
                    summary: "swift test",
                    detail: "",
                    state: .running,
                    exitCode: nil,
                    evidence: AgentEvidence(
                        source: .transcript,
                        authority: .reported,
                        location: "/tmp/claude.jsonl",
                        byteOffset: 4_096,
                        fingerprint: "abc",
                        capturedAt: capturedAt,
                        freshness: .current
                    )
                )
            )
        )

        let tool = reducer.snapshot.tools.first { $0.id == "toolu_01Race" }
        XCTAssertEqual(tool?.state, .succeeded)
        XCTAssertEqual(tool?.detail, "1006 tests")
        XCTAssertEqual(
            tool?.evidence.byteOffset,
            4_096,
            "The transcript still wins as the anchor a human returns to"
        )
    }

    func testAnAnsweredQuestionIsNotRaisedAgainWhenTheTranscriptDescribesIt() {
        var reducer = AgentLensReducer()
        let hookEvidence = AgentEvidence(
            source: .providerHook,
            authority: .reported,
            location: "hook",
            byteOffset: nil,
            fingerprint: "",
            capturedAt: capturedAt,
            freshness: .current
        )
        let request = AgentInteractionRequest(
            id: "toolu_01Ask-0",
            kind: .question,
            title: "Which doctor did you mean?",
            detail: "Doctor",
            options: [AgentInteractionOption(id: "0-0", label: "remember:doctor", detail: "")],
            state: .pending,
            evidence: hookEvidence
        )
        reducer.apply(.interactionRequested(request))
        reducer.apply(.interactionResolved(id: request.id, evidence: hookEvidence))

        // Minutes later the turn flushes and the transcript describes the same question.
        reducer.apply(
            .interactionRequested(
                AgentInteractionRequest(
                    id: request.id,
                    kind: .question,
                    title: request.title,
                    detail: request.detail,
                    options: request.options,
                    state: .pending,
                    evidence: AgentEvidence(
                        source: .transcript,
                        authority: .reported,
                        location: "/tmp/claude.jsonl",
                        byteOffset: 2_048,
                        fingerprint: "abc",
                        capturedAt: capturedAt,
                        freshness: .current
                    )
                )
            )
        )

        XCTAssertEqual(reducer.snapshot.interactions.count, 1)
        XCTAssertEqual(reducer.snapshot.interactions.first?.state, .answered)
        XCTAssertNil(reducer.snapshot.pendingInteraction)
        XCTAssertEqual(reducer.snapshot.interactions.first?.evidence.byteOffset, 2_048)
    }

    func testATurnEndingDoesNotOverwriteAQuestionThatIsStillWaiting() {
        var reducer = AgentLensReducer()
        let evidence = AgentEvidence(
            source: .providerHook,
            authority: .reported,
            location: "hook",
            byteOffset: nil,
            fingerprint: "",
            capturedAt: capturedAt,
            freshness: .current
        )
        reducer.apply(
            .interactionRequested(
                AgentInteractionRequest(
                    id: "toolu_01Wait-0",
                    kind: .question,
                    title: "Scope?",
                    detail: "",
                    options: [],
                    state: .pending,
                    evidence: evidence
                )
            )
        )
        // A resolution for something else must not silently move the session on.
        reducer.apply(.interactionResolved(id: "hook-notification-session-1", evidence: evidence))

        XCTAssertEqual(reducer.snapshot.status, .waitingForUser)
        XCTAssertEqual(reducer.snapshot.pendingInteraction?.id, "toolu_01Wait-0")
    }

    private func hookEvent(
        name: String,
        agentID: String? = nil,
        activity: AgentHookActivity
    ) -> AgentHookEvent {
        AgentHookEvent(
            paneID: UUID(),
            surfaceToken: UUID(),
            provider: .claude,
            sessionID: "session-1",
            transcriptPath: "/tmp/claude.jsonl",
            hookEventName: name,
            agentID: agentID,
            processGroupID: 4_242,
            activity: activity
        )
    }

    private func jsonText(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
