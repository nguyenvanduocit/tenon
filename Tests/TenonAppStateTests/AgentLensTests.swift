import Foundation
import SwiftUI
import TenonCore
@testable import TenonApp
import XCTest

final class AgentLensDecoderTests: XCTestCase {
    func testClaudeAssistantResponsePreservesTextVerbatim() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let response = "    let value = 42\n\nDone.  \n"
        let line = try json([
            "type": "assistant",
            "uuid": "claude-verbatim-response",
            "message": [
                "content": [["type": "text", "text": response]],
            ],
        ])

        let events = try decoder.decode(
            line: line,
            byteOffset: 0,
            location: "/tmp/claude.jsonl"
        )

        guard case let .assistantMessage(message) = try XCTUnwrap(events.first) else {
            return XCTFail("Claude response was not projected as an assistant message")
        }
        XCTAssertEqual(message.text, response)
    }

    func testClaudeAssistantResponseSkipsWhitespaceOnlyTextWithoutNormalizingPayloads() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let line = try json([
            "type": "assistant",
            "uuid": "claude-blank-response",
            "message": [
                "content": [["type": "text", "text": "  \n\t"]],
            ],
        ])

        XCTAssertTrue(
            try decoder.decode(
                line: line,
                byteOffset: 0,
                location: "/tmp/claude.jsonl"
            ).isEmpty
        )
    }

    func testClaudeTranscriptProjectsMessagesReasoningAndToolLifecycleWithEvidence() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let assistant = try json([
            "type": "assistant",
            "uuid": "claude-message-1",
            "timestamp": "2026-08-05T10:00:00Z",
            "message": [
                "content": [
                    ["type": "thinking", "thinking": "Inspect the repository"],
                    ["type": "text", "text": "I found the seam."],
                    [
                        "type": "tool_use",
                        "id": "tool-1",
                        "name": "Read",
                        "input": ["file_path": "/tmp/source.swift"],
                    ],
                ],
            ],
        ])

        let events = try decoder.decode(
            line: assistant,
            byteOffset: 42,
            location: "/tmp/claude.jsonl"
        )

        XCTAssertEqual(events.count, 3)
        let reasoning = try XCTUnwrap(events.compactMap { event -> AgentLensMessage? in
            guard case let .reasoning(value) = event else { return nil }
            return value
        }.first)
        let message = try XCTUnwrap(events.compactMap { event -> AgentLensMessage? in
            guard case let .assistantMessage(value) = event else { return nil }
            return value
        }.first)
        let tool = try XCTUnwrap(events.compactMap { event -> AgentToolRun? in
            guard case let .toolStarted(value) = event else { return nil }
            return value
        }.first)
        XCTAssertEqual(reasoning.text, "Inspect the repository")
        XCTAssertEqual(message.id, "claude-message-1")
        XCTAssertEqual(message.text, "I found the seam.")
        XCTAssertEqual(message.evidence.source, .transcript)
        XCTAssertEqual(message.evidence.authority, .reported)
        XCTAssertEqual(message.evidence.byteOffset, 42)
        XCTAssertEqual(message.evidence.fingerprint.count, 64)
        XCTAssertEqual(tool.id, "tool-1")
        XCTAssertEqual(tool.state, .running)

        let result = try json([
            "type": "user",
            "uuid": "claude-result-1",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "tool-1",
                    "content": "file contents",
                    "is_error": false,
                ]],
            ],
        ])
        let resultEvents = try decoder.decode(
            line: result,
            byteOffset: 500,
            location: "/tmp/claude.jsonl"
        )
        guard case let .toolFinished(finished) = try XCTUnwrap(resultEvents.first) else {
            return XCTFail("Claude tool result was not normalized")
        }
        XCTAssertEqual(finished.id, "tool-1")
        XCTAssertEqual(finished.state, .succeeded)
        XCTAssertEqual(finished.detail, "file contents")
    }

    func testClaudeTranscriptNamesItsToolsAndReadsTheStructuredResultBesideThem() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let assistant = try json([
            "type": "assistant",
            "uuid": "claude-tools-1",
            "cwd": "/repo",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": "tool-bash",
                    "name": "Bash",
                    "input": ["command": "swift build", "description": "Compile"],
                ]],
            ],
        ])

        guard case let .toolStarted(tool) = try XCTUnwrap(
            try decoder.decode(line: assistant, byteOffset: 0, location: "/tmp/c.jsonl").first
        ) else {
            return XCTFail("A Claude Code tool call is a tool run")
        }
        XCTAssertEqual(tool.kind, .command)
        XCTAssertEqual(tool.summary, "swift build")

        // Claude Code keeps the structured result beside the message, not inside the block.
        let failure = try json([
            "type": "user",
            "uuid": "claude-tools-1-result",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "tool-bash",
                    "content": "Error: Exit code 1",
                    "is_error": true,
                ]],
            ],
            "toolUseResult": "Error: Exit code 1\nerror: no such module 'Ghostty'",
        ])
        guard case let .toolFinished(finished) = try XCTUnwrap(
            try decoder.decode(line: failure, byteOffset: 900, location: "/tmp/c.jsonl").first
        ) else {
            return XCTFail("A failed Claude Code tool call still finishes")
        }
        XCTAssertEqual(finished.state, .failed)
        XCTAssertEqual(finished.exitCode, 1)
        XCTAssertTrue(finished.detail.contains("no such module"))
    }

    func testClaudeTranscriptRecordsAnAnsweredQuestionAsTheDecisionItWas() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let asked = try json([
            "type": "assistant",
            "uuid": "claude-ask-1",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": "toolu_01Ask",
                    "name": "AskUserQuestion",
                    "input": [
                        "questions": [[
                            "question": "Which doctor did you mean?",
                            "header": "Doctor",
                            "options": [
                                ["label": "remember:doctor", "description": "Diagnose Remember"],
                                ["label": "omc-doctor", "description": "Diagnose OMC"],
                            ],
                        ]],
                    ],
                ]],
            ],
        ])

        let askedEvents = try decoder.decode(line: asked, byteOffset: 0, location: "/tmp/c.jsonl")
        guard case let .interactionRequested(request) = try XCTUnwrap(askedEvents.first) else {
            return XCTFail("A question is a decision, not an execution step")
        }
        // The same identity the live hook uses, so the two accounts are one decision.
        XCTAssertEqual(request.id, "toolu_01Ask-0")
        XCTAssertEqual(request.options.map(\.label), ["remember:doctor", "omc-doctor"])
        XCTAssertFalse(
            askedEvents.contains { event in
                if case .toolStarted = event { return true }
                return false
            }
        )

        let answered = try json([
            "type": "user",
            "uuid": "claude-ask-1-result",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_01Ask",
                    "content": "Your questions have been answered",
                ]],
            ],
            "toolUseResult": [
                "questions": ["Which doctor did you mean?"],
                "answers": ["remember:doctor"],
            ],
        ])
        let answeredEvents = try decoder.decode(
            line: answered,
            byteOffset: 700,
            location: "/tmp/c.jsonl"
        )
        guard case let .interactionResolved(id, _) = try XCTUnwrap(answeredEvents.first) else {
            return XCTFail("An answered question resolves its decision")
        }
        XCTAssertEqual(id, "toolu_01Ask-0")
    }

    func testClaudeTranscriptKeepsInjectedSkillInstructionsOutOfUserConversation() throws {
        let decoder = AgentTranscriptDecoder(provider: .claude)
        let skill = try json([
            "type": "user",
            "uuid": "claude-skill-context",
            "isMeta": true,
            "message": [
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": """
                    Base directory for this skill: /tmp/plugins/frontend-design/skills/frontend-design

                    This skill guides creation of distinct, production-grade interfaces.
                    """,
                ]],
            ],
        ])

        let events = try decoder.decode(
            line: skill,
            byteOffset: 80,
            location: "/tmp/claude.jsonl"
        )

        guard case let .contextMessage(message) = try XCTUnwrap(events.first) else {
            return XCTFail("Claude skill injection was presented as user conversation")
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.kind, .skill)
        XCTAssertTrue(message.text.hasPrefix("Base directory for this skill:"))
    }

    func testCodexTranscriptProjectsObservedCommandFacts() throws {
        let decoder = AgentTranscriptDecoder(provider: .codex)
        let line = try json([
            "type": "response_item",
            "payload": [
                "type": "commandExecution",
                "id": "command-1",
                "command": "swift test",
                "aggregatedOutput": "All tests passed",
                "status": "completed",
                "exitCode": 0,
            ],
        ])

        let events = try decoder.decode(
            line: line,
            byteOffset: 9,
            location: "/tmp/codex.jsonl"
        )
        guard case let .toolFinished(command) = try XCTUnwrap(events.first) else {
            return XCTFail("Codex command was not normalized")
        }
        XCTAssertEqual(command.id, "command-1")
        XCTAssertEqual(command.summary, "swift test")
        XCTAssertEqual(command.detail, "All tests passed")
        XCTAssertEqual(command.state, .succeeded)
        XCTAssertEqual(command.exitCode, 0)
        XCTAssertEqual(command.evidence.authority, .observed)
    }

    func testCodexTranscriptAcceptsCurrentTaskLifecycleNames() throws {
        let decoder = AgentTranscriptDecoder(provider: .codex)
        let fixtures: [(String, AgentLensStatus)] = [
            ("task_started", .running),
            ("task_complete", .completed),
            ("task_failed", .failed("Turn interrupted")),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let line = try json([
                "type": "event_msg",
                "payload": ["type": fixture.0],
            ])
            let events = try decoder.decode(
                line: line,
                byteOffset: UInt64(index),
                location: "/tmp/codex.jsonl"
            )
            guard case let .status(status, _) = try XCTUnwrap(events.first) else {
                return XCTFail("Codex task lifecycle was not normalized")
            }
            XCTAssertEqual(status, fixture.1)
        }
    }

    func testCodexTranscriptPreservesSystemDeveloperAndSkillMessages() throws {
        let decoder = AgentTranscriptDecoder(provider: .codex)
        let fixtures: [(String, String, AgentMessageRole, AgentMessageKind)] = [
            ("system", "System policy", .system, .instruction),
            ("developer", "Developer guidance", .developer, .instruction),
            (
                "developer",
                "<skills_instructions>Use the matching SKILL.md workflow.</skills_instructions>",
                .developer,
                .skill
            ),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let line = try json([
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "id": "context-\(index)",
                    "role": fixture.0,
                    "content": [["type": "input_text", "text": fixture.1]],
                ],
            ])

            let events = try decoder.decode(
                line: line,
                byteOffset: UInt64(index),
                location: "/tmp/codex.jsonl"
            )
            guard case let .contextMessage(message) = try XCTUnwrap(events.first) else {
                return XCTFail("Codex context message was not normalized")
            }
            XCTAssertEqual(message.role, fixture.2)
            XCTAssertEqual(message.kind, fixture.3)
            XCTAssertEqual(message.text, fixture.1)
        }
    }

    func testCodexTranscriptRecognizesInjectedProjectInstructions() throws {
        let decoder = AgentTranscriptDecoder(provider: .codex)
        let text = """
        <recommended_plugins>
        - Example plugin
        </recommended_plugins>

        # AGENTS.md instructions for /tmp/project

        <INSTRUCTIONS>
        Project rules
        </INSTRUCTIONS>
        <environment_context><cwd>/tmp/project</cwd></environment_context>
        """
        let line = try json([
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": "project-instructions",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])

        guard case let .contextMessage(message) = try XCTUnwrap(
            decoder.decode(
                line: line,
                byteOffset: 1,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Injected project instructions were not normalized as context") }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.kind, .instruction)
        XCTAssertEqual(message.text, text)

        let assistantLine = try json([
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": "assistant-example",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]],
            ],
        ])
        guard case let .assistantMessage(assistant) = try XCTUnwrap(
            decoder.decode(
                line: assistantLine,
                byteOffset: 2,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Assistant example was incorrectly treated as injected context") }
        XCTAssertEqual(assistant.kind, .conversation)

        let quotedLine = try json([
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": "quoted-example",
                "role": "user",
                "content": [["type": "input_text", "text": "Please explain this:\n\(text)"]],
            ],
        ])
        guard case let .userMessage(quoted) = try XCTUnwrap(
            decoder.decode(
                line: quotedLine,
                byteOffset: 3,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("A user quoting the wrapper was incorrectly treated as injected context") }
        XCTAssertEqual(quoted.kind, .conversation)
    }

    func testCodexTranscriptClassifiesSkillAndSubagentOperations() throws {
        let decoder = AgentTranscriptDecoder(provider: .codex)
        let skillCall = try json([
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "call_id": "skill-call",
                "name": "exec",
                "input": "sed -n '1,200p' /tmp/skills/ultra-bugfix/SKILL.md",
            ],
        ])
        let subagentCall = try json([
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "call_id": "subagent-call",
                "name": "spawn_agent",
                "arguments": "{\"task_name\":\"classification_review\"}",
            ],
        ])

        guard case let .toolStarted(skill) = try XCTUnwrap(
            decoder.decode(
                line: skillCall,
                byteOffset: 1,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Skill operation was not normalized") }
        XCTAssertEqual(skill.kind, .skill)
        XCTAssertEqual(skill.name, "ultra-bugfix")

        guard case let .toolStarted(subagent) = try XCTUnwrap(
            decoder.decode(
                line: subagentCall,
                byteOffset: 2,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Subagent operation was not normalized") }
        XCTAssertEqual(subagent.kind, .subagent)
        XCTAssertEqual(subagent.name, "Spawn subagent")

        let overlappingSubagentCall = try json([
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "call_id": "subagent-skill-review",
                "name": "spawn_agent",
                "arguments": "{\"message\":\"Review /tmp/skills/ultra-bugfix/SKILL.md\"}",
            ],
        ])
        guard case let .toolStarted(overlappingSubagent) = try XCTUnwrap(
            decoder.decode(
                line: overlappingSubagentCall,
                byteOffset: 3,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Overlapping subagent operation was not normalized") }
        XCTAssertEqual(overlappingSubagent.kind, .subagent)
        XCTAssertEqual(overlappingSubagent.name, "Spawn subagent")
    }

    func testCodexNativeProtocolProjectsDeltaApprovalAndResolution() throws {
        let decoder = CodexProtocolFrameDecoder()
        let delta = try json([
            "method": "item/agentMessage/delta",
            "params": ["itemId": "message-1", "delta": "hello"],
        ])
        let approval = try json([
            "id": 17,
            "method": "item/commandExecution/requestApproval",
            "params": ["command": "git push"],
        ])
        let resolved = try json([
            "method": "serverRequest/resolved",
            "params": ["requestId": 17],
        ])

        guard case let .assistantDelta(id, text, evidence) = try XCTUnwrap(
            decoder.decode(line: delta, sequence: 1).first
        ) else { return XCTFail("message delta was not projected") }
        XCTAssertEqual(id, "message-1")
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(evidence.source, .nativeProtocol)

        guard case let .interactionRequested(request) = try XCTUnwrap(
            decoder.decode(line: approval, sequence: 2).first
        ) else { return XCTFail("approval was not projected") }
        XCTAssertEqual(request.id, "17")
        XCTAssertEqual(request.kind, .approval)
        XCTAssertEqual(request.state, .pending)

        guard case let .interactionResolved(requestID, _) = try XCTUnwrap(
            decoder.decode(line: resolved, sequence: 3).first
        ) else { return XCTFail("resolution was not projected") }
        XCTAssertEqual(requestID, "17")
    }

    func testCodexNativeQuestionPreservesPromptAndSuggestedOptions() throws {
        let question = try json([
            "id": 24,
            "method": "item/tool/requestUserInput",
            "params": [
                "questions": [[
                    "header": "Direction",
                    "question": "Which implementation should I use?",
                    "options": [
                        ["label": "Small patch", "description": "Keep the current model"],
                        ["label": "Full redesign", "description": "Handle every state"],
                    ],
                ]],
            ],
        ])

        guard case let .interactionRequested(request) = try XCTUnwrap(
            CodexProtocolFrameDecoder().decode(line: question, sequence: 1).first
        ) else { return XCTFail("question was not projected") }

        XCTAssertEqual(request.title, "Which implementation should I use?")
        XCTAssertEqual(request.detail, "Direction")
        XCTAssertEqual(request.options.map(\.label), ["Small patch", "Full redesign"])
        XCTAssertEqual(request.options.last?.detail, "Handle every state")
    }

    func testPlanOperationsHaveTheirOwnTimelineKind() throws {
        let claudePlan = try json([
            "type": "assistant",
            "uuid": "claude-plan",
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": "todo-1",
                    "name": "TodoWrite",
                    "input": ["todos": [["content": "Polish timeline", "status": "in_progress"]]],
                ]],
            ],
        ])
        let codexPlan = try json([
            "method": "item/started",
            "params": [
                "item": [
                    "type": "plan",
                    "id": "plan-1",
                    "text": "- [x] Inspect\n- [ ] Implement",
                ],
            ],
        ])

        guard case let .toolStarted(claudeTool) = try XCTUnwrap(
            AgentTranscriptDecoder(provider: .claude).decode(
                line: claudePlan,
                byteOffset: 1,
                location: "/tmp/claude.jsonl"
            ).first
        ) else { return XCTFail("Claude plan was not projected") }
        guard case let .toolStarted(codexTool) = try XCTUnwrap(
            CodexProtocolFrameDecoder().decode(line: codexPlan, sequence: 2).first
        ) else { return XCTFail("Codex plan was not projected") }

        XCTAssertEqual(claudeTool.kind, .plan)
        XCTAssertEqual(claudeTool.summary, "0/1 steps complete")
        XCTAssertEqual(claudeTool.detail, "▸ Polish timeline")
        XCTAssertEqual(codexTool.kind, .plan)
        XCTAssertTrue(codexTool.detail.contains("Implement"))
    }

    func testCodexPreservesSchemaSpecificNativeUserAndTranscriptShellItems() throws {
        let decoder = CodexProtocolFrameDecoder()
        let user = try json([
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "userMessage",
                    "id": "user-1",
                    "content": [["type": "text", "text": "Native user prompt"]],
                ],
            ],
        ])
        let shell = try json([
            "type": "response_item",
            "payload": [
                "type": "local_shell_call",
                "id": "shell-1",
                "action": ["command": "swift test"],
                "status": "inProgress",
            ],
        ])

        guard case let .userMessage(message) = try XCTUnwrap(
            decoder.decode(line: user, sequence: 1).first
        ) else { return XCTFail("Native userMessage was not normalized") }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Native user prompt")

        guard case let .toolStarted(tool) = try XCTUnwrap(
            AgentTranscriptDecoder(provider: .codex).decode(
                line: shell,
                byteOffset: 2,
                location: "/tmp/codex.jsonl"
            ).first
        ) else { return XCTFail("Transcript local_shell_call was not normalized") }
        XCTAssertEqual(tool.kind, .command)
        XCTAssertEqual(tool.name, "local_shell_call")
        XCTAssertTrue(tool.summary.contains("swift test"))
    }

    func testDecoderRejectsOversizedRecordsAndUnknownProtocolMethodsStaySilent() throws {
        let oversized = Data(repeating: 0x61, count: (2 << 20) + 1)
        XCTAssertThrowsError(
            try AgentTranscriptDecoder(provider: .claude).decode(
                line: oversized,
                byteOffset: 0,
                location: "oversized"
            )
        ) { error in
            XCTAssertEqual(error as? AgentLensDecodeError, .recordTooLarge)
        }

        let unknown = try json(["method": "future/newNotification", "params": [:]])
        XCTAssertEqual(
            try CodexProtocolFrameDecoder().decode(line: unknown, sequence: 1),
            [],
            "unknown provider methods must not be guessed into product semantics"
        )
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

final class AgentLensReducerTests: XCTestCase {
    func testReplayIsDeterministicAndAdjacentOptimisticMessageReconcilesToTranscriptEvidence() {
        let pendingEvidence = evidence(
            source: .terminalInput,
            authority: .observed,
            location: "slot",
            offset: nil
        )
        let transcriptEvidence = evidence(
            source: .transcript,
            authority: .reported,
            location: "session.jsonl",
            offset: 200
        )
        let events: [AgentLensEvent] = [
            .connected(
                provider: .claude,
                capabilities: .transcriptPTY,
                transcriptPath: "session.jsonl",
                evidence: transcriptEvidence
            ),
            .userMessage(
                AgentLensMessage(
                    id: "pending",
                    role: .user,
                    text: "review this",
                    isStreaming: false,
                    evidence: pendingEvidence
                )
            ),
            .userMessage(
                AgentLensMessage(
                    id: "durable",
                    role: .user,
                    text: "review this",
                    isStreaming: false,
                    evidence: transcriptEvidence
                )
            ),
            .assistantDelta(id: "answer", text: "Hel", evidence: transcriptEvidence),
            .assistantDelta(id: "answer", text: "lo", evidence: transcriptEvidence),
        ]

        var first = AgentLensReducer()
        var second = AgentLensReducer()
        for event in events {
            first.apply(event)
            second.apply(event)
        }

        XCTAssertEqual(first.snapshot, second.snapshot)
        XCTAssertEqual(first.snapshot.messages.count, 2)
        XCTAssertEqual(first.snapshot.messages[0].text, "review this")
        XCTAssertEqual(first.snapshot.messages[0].evidence.authority, .observed)
        XCTAssertEqual(first.snapshot.messages[1].text, "Hello")
        XCTAssertTrue(first.snapshot.messages[1].isStreaming)
        XCTAssertEqual(first.snapshot.provider, .claude)
        XCTAssertTrue(first.snapshot.canSend)
    }

    func testProjectionCapacitiesAreBoundedAndSignalEarlierHistory() {
        var reducer = AgentLensReducer()
        for index in 0..<620 {
            reducer.apply(
                .userMessage(
                    AgentLensMessage(
                        id: "message-\(index)",
                        role: index.isMultiple(of: 2) ? .user : .assistant,
                        text: "message \(index)",
                        isStreaming: false,
                        evidence: evidence(
                            source: .transcript,
                            authority: .reported,
                            location: "fixture",
                            offset: UInt64(index)
                        )
                    )
                )
            )
        }
        for index in 0..<55 {
            let observed = evidence(
                source: .terminalInference,
                authority: .observed,
                location: "diagnostic",
                offset: UInt64(index)
            )
            reducer.apply(
                .diagnostic(
                    AgentLensDiagnostic(
                        id: "diagnostic-\(index)",
                        severity: .info,
                        message: "diagnostic \(index)",
                        evidence: observed
                    )
                )
            )
        }

        XCTAssertEqual(reducer.snapshot.messages.count, 600)
        XCTAssertEqual(reducer.snapshot.messages.first?.id, "message-20")
        // Trimming in memory names its own boundary: the oldest message still visible is
        // where the reader would have to go back from.
        XCTAssertEqual(reducer.snapshot.earlierHistory?.byteOffset, 20)
        XCTAssertEqual(reducer.snapshot.earlierHistory?.location, "fixture")
        XCTAssertEqual(reducer.snapshot.diagnostics.count, 40)
        XCTAssertEqual(reducer.snapshot.timelineItems.count, 640)
    }

    func testEarlierHistoryNamesTheTranscriptAndTheByteItBeginsAt() {
        var reducer = AgentLensReducer()
        let cut = evidence(
            source: .transcript,
            authority: .reported,
            location: "/tmp/agent/session.jsonl",
            offset: 4_096
        )
        reducer.apply(.earlierHistory(cut))

        XCTAssertEqual(reducer.snapshot.earlierHistory?.byteOffset, 4_096)
        XCTAssertEqual(reducer.snapshot.earlierHistory?.location, "/tmp/agent/session.jsonl")

        let notice = AgentLensEarlierHistoryNotice.text(for: cut)
        XCTAssertTrue(notice.contains("4096"), notice)
        XCTAssertTrue(notice.contains("session.jsonl"), notice)
    }

    func testOnlyARecordThatCarriesItsOwnMeaningOpensBoundedHistory() throws {
        let claude = AgentTranscriptDecoder(provider: .claude)
        let toolResult = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "uuid": "orphan",
            "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1"]]],
        ])
        let prompt = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "uuid": "prompt",
            "message": ["content": [["type": "text", "text": "carry on"]]],
        ])
        let call = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "uuid": "call",
            "message": ["content": [[
                "type": "tool_use", "id": "toolu_2", "name": "Bash", "input": ["command": "ls"],
            ]]],
        ])
        let attachment = try JSONSerialization.data(withJSONObject: ["type": "attachment"])

        XCTAssertFalse(claude.opensHistoryWindow(line: toolResult))
        XCTAssertTrue(claude.opensHistoryWindow(line: prompt))
        XCTAssertTrue(claude.opensHistoryWindow(line: call))
        XCTAssertFalse(claude.opensHistoryWindow(line: attachment))
        XCTAssertFalse(claude.opensHistoryWindow(line: Data("{ not json".utf8)))

        let codex = AgentTranscriptDecoder(provider: .codex)
        let codexOutput = try JSONSerialization.data(withJSONObject: [
            "type": "response_item",
            "payload": ["type": "function_call_output", "call_id": "call_1", "output": "done"],
        ])
        let codexMessage = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "payload": ["type": "agent_message", "message": "carry on"],
        ])
        XCTAssertFalse(codex.opensHistoryWindow(line: codexOutput))
        XCTAssertTrue(codex.opensHistoryWindow(line: codexMessage))
    }

    func testBoundedAttachSkipsTheToolResultItsWindowCutThrough() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-lens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")

        // One Claude turn spans two records: the call is named in the assistant record and
        // answered in the next user record. A window that opens between them used to admit
        // the answer alone, which the decoder can only render as an unnamed finished "Tool".
        let call = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "uuid": "call-record",
            "message": ["content": [[
                "type": "tool_use",
                "id": "toolu_cut",
                "name": "Bash",
                "input": ["command": "swift test --filter Padding\(String(repeating: "x", count: 200))"],
            ]]],
        ])
        let result = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "uuid": "result-record",
            "message": ["content": [[
                "type": "tool_result", "tool_use_id": "toolu_cut", "content": "1854 passed",
            ]]],
        ])
        let after = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "uuid": "after-record",
            "message": ["content": [["type": "text", "text": "after the cut"]]],
        ])
        let newline = Data([0x0A])
        try (call + newline + result + newline + after + newline).write(to: file)

        // Land the window five bytes inside the call record, so the seek drops a partial
        // record and the first whole record it meets is the orphaned result.
        let window = UInt64(result.count + 1 + after.count + 1 + 5)
        let stream = await AgentTranscriptTailer().events(
            fileURL: file,
            provider: .claude,
            pollInterval: .milliseconds(5),
            initialWindowBytes: window
        )

        var collected: [AgentLensEvent] = []
        var iterator = stream.makeAsyncIterator()
        while collected.count < 8 {
            guard let event = try await iterator.next() else { break }
            collected.append(event)
            if case .assistantMessage = event { break }
        }

        let toolFacts = collected.filter {
            if case .toolFinished = $0 { return true }
            if case .toolStarted = $0 { return true }
            return false
        }
        XCTAssertTrue(toolFacts.isEmpty, "a half-seen call was projected: \(toolFacts)")
        // The cut is a claim like any other, so it names the file and the byte a reader would
        // have to open to see what came before it.
        let cut = collected.compactMap { event -> AgentEvidence? in
            guard case let .earlierHistory(evidence) = event else { return nil }
            return evidence
        }.first
        XCTAssertEqual(cut?.location, file.path)
        XCTAssertEqual(cut?.byteOffset, UInt64(call.count + 1) - 5)
        guard case let .assistantMessage(message) = try XCTUnwrap(collected.last) else {
            return XCTFail("the record after the cut was never read")
        }
        XCTAssertEqual(message.text, "after the cut")
    }

    func testSessionTimelineOrdersFactsSeparatesContextAndGroupsExecution() throws {
        let source = { (offset: UInt64) in
            self.evidence(
                source: .transcript,
                authority: .reported,
                location: "session.jsonl",
                offset: offset
            )
        }
        var snapshot = AgentLensSnapshot.empty
        snapshot.messages = [
            AgentLensMessage(
                id: "system",
                role: .system,
                kind: .instruction,
                text: "System policy",
                isStreaming: false,
                evidence: source(1)
            ),
            AgentLensMessage(
                id: "user",
                role: .user,
                text: "Fix the session UI",
                isStreaming: false,
                evidence: source(2)
            ),
            AgentLensMessage(
                id: "assistant",
                role: .assistant,
                text: "Done",
                isStreaming: false,
                evidence: source(5)
            ),
        ]
        snapshot.tools = [
            AgentToolRun(
                id: "skill-1",
                name: "swiftui-expert",
                kind: .skill,
                summary: "Loaded instructions",
                detail: "",
                state: .succeeded,
                exitCode: nil,
                evidence: source(3)
            ),
            AgentToolRun(
                id: "skill-2",
                name: "swiftui-expert",
                kind: .skill,
                summary: "Loaded instructions",
                detail: "",
                state: .succeeded,
                exitCode: nil,
                evidence: source(4)
            ),
            AgentToolRun(
                id: "spawn",
                name: "Spawn subagent",
                kind: .subagent,
                summary: "review",
                detail: "",
                state: .succeeded,
                exitCode: nil,
                evidence: source(6)
            ),
            AgentToolRun(
                id: "wait",
                name: "Wait for subagent",
                kind: .subagent,
                summary: "review",
                detail: "",
                state: .succeeded,
                exitCode: nil,
                evidence: source(7)
            ),
        ]

        XCTAssertEqual(snapshot.contextMessages.map(\.id), ["system"])
        XCTAssertEqual(snapshot.goalSummary, "Fix the session UI")

        let timeline = snapshot.timelineItems
        XCTAssertEqual(timeline.count, 4)
        guard case .message(let user) = timeline[0].content,
              case .tools(let skills) = timeline[1].content,
              case .message(let assistant) = timeline[2].content,
              case .tools(let subagents) = timeline[3].content
        else { return XCTFail("session facts were not projected into chronological groups") }
        XCTAssertEqual(user.id, "user")
        XCTAssertEqual(skills.kind, .skill)
        XCTAssertEqual(skills.tools.count, 2)
        XCTAssertEqual(assistant.id, "assistant")
        XCTAssertEqual(subagents.kind, .subagent)
        XCTAssertEqual(subagents.tools.count, 2)

        XCTAssertEqual(
            snapshot.sessionTimelineItems.compactMap { item -> AgentTimelineToolGroup? in
                guard case .tools(let group) = item.content else { return nil }
                return group
            },
            [],
            "completed tools stay out of the Session projection"
        )

        snapshot.tools[2].state = .running
        snapshot.tools[3].state = .running
        let visibleTools = snapshot.sessionTimelineItems.compactMap { item -> AgentTimelineToolGroup? in
            guard case .tools(let group) = item.content else { return nil }
            return group
        }
        XCTAssertEqual(visibleTools.count, 1)
        XCTAssertEqual(visibleTools.first?.tools.map(\.id), ["wait"])
    }

    func testToolCompletionPreservesSkillOrSubagentClassificationFromStart() throws {
        let source = evidence(
            source: .transcript,
            authority: .reported,
            location: "session.jsonl",
            offset: 10
        )
        var reducer = AgentLensReducer()
        reducer.apply(
            .toolStarted(
                AgentToolRun(
                    id: "subagent-call",
                    name: "Spawn subagent",
                    kind: .subagent,
                    summary: "classification_review",
                    detail: "",
                    state: .running,
                    exitCode: nil,
                    evidence: source
                )
            )
        )
        reducer.apply(
            .toolFinished(
                AgentToolRun(
                    id: "subagent-call",
                    name: "Tool",
                    summary: "completed",
                    detail: "review passed",
                    state: .succeeded,
                    exitCode: nil,
                    evidence: source
                )
            )
        )

        let tool = try XCTUnwrap(reducer.snapshot.tools.first)
        XCTAssertEqual(tool.name, "Spawn subagent")
        XCTAssertEqual(tool.kind, .subagent)
        XCTAssertEqual(tool.state, .succeeded)
    }

    func testCapabilitiesDescribeTransportInsteadOfAssumingProviderParity() {
        XCTAssertTrue(AgentLensCapabilities.transcriptPTY.contains(.terminalInput))
        XCTAssertTrue(AgentLensCapabilities.transcriptPTY.contains(.transcript))
        XCTAssertFalse(AgentLensCapabilities.transcriptPTY.contains(.approvals))
        XCTAssertTrue(AgentLensCapabilities.protocolNative.contains(.structuredInput))
        XCTAssertTrue(AgentLensCapabilities.protocolNative.contains(.approvals))
        XCTAssertFalse(AgentLensCapabilities.protocolNative.contains(.terminalInput))
    }

    private func evidence(
        source: AgentEvidenceSource,
        authority: AgentEvidenceAuthority,
        location: String,
        offset: UInt64?
    ) -> AgentEvidence {
        AgentEvidence(
            source: source,
            authority: authority,
            location: location,
            byteOffset: offset,
            fingerprint: "fixture",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            freshness: .current
        )
    }
}

final class AgentLensStreamTests: XCTestCase {
    func testNativeProtocolIngressIsOrderedAndSurfacesMalformedFrames() async throws {
        let valid = try JSONSerialization.data(withJSONObject: [
            "method": "turn/started",
            "params": [:],
        ])
        let frames = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(valid)
            continuation.yield(Data("not-json".utf8))
            continuation.finish()
        }

        var events: [AgentLensEvent] = []
        for try await event in CodexProtocolIngress().events(frames: frames) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        guard case .status(.running, _) = events[0],
              case let .diagnostic(diagnostic) = events[1]
        else { return XCTFail("protocol events were reordered or malformed frame was hidden") }
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertEqual(diagnostic.evidence.source, .terminalInference)
    }

    func testNativeProtocolBoundedWriterTerminatesOnConsumerOverflow() async throws {
        let evidence = AgentEvidence.terminalInference("overflow-fixture")
        let event = AgentLensEvent.status(.running, evidence: evidence)
        let stream = AsyncThrowingStream<AgentLensEvent, any Error>(
            bufferingPolicy: .bufferingOldest(1)
        ) { continuation in
            XCTAssertTrue(CodexProtocolIngress.yield(event, to: continuation))
            XCTAssertFalse(
                CodexProtocolIngress.yield(event, to: continuation),
                "the second undrained fact must terminate instead of being silently dropped"
            )
        }
        var received = 0
        do {
            for try await _ in stream { received += 1 }
            XCTFail("overflow must be explicit, never a silent semantic drop")
        } catch {
            XCTAssertEqual(error as? AgentLensSourceError, .overflow)
        }
        XCTAssertEqual(received, 1)
    }

    func testTranscriptTailerReadsExistingLineAndCancellationFinishes() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-lens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let record = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "uuid": "tail-message",
            "message": ["content": [["type": "text", "text": "from disk"]]],
        ])
        try (record + Data([0x0A])).write(to: file)

        let stream = await AgentTranscriptTailer().events(
            fileURL: file,
            provider: .claude,
            pollInterval: .milliseconds(5)
        )
        let task = Task { () throws -> AgentLensEvent? in
            for try await event in stream { return event }
            return nil
        }
        let event = try await task.value
        task.cancel()

        guard case let .assistantMessage(message) = try XCTUnwrap(event) else {
            return XCTFail("existing transcript data was not tailed")
        }
        XCTAssertEqual(message.id, "tail-message")
        XCTAssertEqual(message.text, "from disk")
        XCTAssertEqual(message.evidence.location, file.path)
    }

    func testTranscriptTailerReadsRecordAppendedAfterAttachment() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-lens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let existing = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "before attachment"],
        ])
        try (existing + Data([0x0A])).write(to: file)

        let stream = await AgentTranscriptTailer().events(
            fileURL: file,
            provider: .codex,
            pollInterval: .milliseconds(5)
        )
        let appended = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "payload": ["type": "agent_message", "message": "after attachment"],
        ])
        let sink = AgentLensMessageSink()
        let collector = Task {
            var iterator = stream.makeAsyncIterator()
            guard let initial = try await iterator.next() else { return }
            if case .userMessage = initial {
                await sink.recordInitialRead()
            }
            while let event = try await iterator.next() {
                if case let .assistantMessage(message) = event {
                    await sink.record(message)
                    return
                }
            }
        }
        defer { collector.cancel() }
        for _ in 0..<200 {
            if await sink.didReadInitialRecord { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let didReadInitialRecord = await sink.didReadInitialRecord
        XCTAssertTrue(didReadInitialRecord)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended + Data([0x0A]))
        try handle.close()

        for _ in 0..<200 {
            if await sink.message != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let received = await sink.message
        let message = try XCTUnwrap(received)
        XCTAssertEqual(message.text, "after attachment")
    }
}

@MainActor
final class AgentLensInputAndSurfaceTests: XCTestCase {
    func testInputQueueFramesPasteThenReturnAndSanitizesPasteTerminator() async throws {
        let recorder = AgentLensFrameRecorder()
        let queue = AgentLensInputQueue(
            transport: AgentLensInputTransport { frame in recorder.send(frame) }
        )

        try await queue.send("hello\u{1B}[201~world")

        XCTAssertEqual(
            recorder.frames,
            ["\u{1B}[200~helloworld\u{1B}[201~", "\r"]
        )
        await queue.stop()
    }

    func testClaudeListedOptionSelectsAndSubmitsInOneGuardedFrame() async throws {
        let recorder = AgentLensFrameRecorder()
        let queue = AgentLensInputQueue(
            transport: AgentLensInputTransport { frame in recorder.send(frame) }
        )

        try await queue.submitOption("2", using: AgentProvider.claude.optionSubmission)

        XCTAssertEqual(recorder.frames, ["2\r"])
        await queue.stop()
    }

    func testCodexListedOptionDoesNotLeakReturnIntoTheNextPrompt() async throws {
        let recorder = AgentLensFrameRecorder()
        let queue = AgentLensInputQueue(
            transport: AgentLensInputTransport { frame in recorder.send(frame) }
        )

        try await queue.submitOption("2", using: AgentProvider.codex.optionSubmission)

        XCTAssertEqual(recorder.frames, ["2"])
        await queue.stop()
    }

    func testListedOptionsHaveOneNativeRenderer() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = packageRoot.appendingPathComponent("Sources/TenonApp/AgentLensView.swift")
        let source = try String(contentsOf: view, encoding: .utf8)
        let rendererCount = source.components(separatedBy: "ForEach(request.options)").count - 1

        XCTAssertEqual(rendererCount, 1, "Listed options must have one native renderer")
    }

    func testOptionSubmissionGateRejectsDoubleClickUntilTheProviderAdvances() {
        var gate = AgentOptionSubmissionGate()

        XCTAssertTrue(gate.begin(requestID: "question-1", pendingRequestID: "question-1"))
        XCTAssertFalse(gate.begin(requestID: "question-1", pendingRequestID: "question-1"))

        gate.reconcile(pendingRequestID: "question-2")
        XCTAssertTrue(gate.begin(requestID: "question-2", pendingRequestID: "question-2"))
    }

    func testOptionSubmissionGateReopensWhenDeliveryFails() {
        var gate = AgentOptionSubmissionGate()

        XCTAssertTrue(gate.begin(requestID: "question-1", pendingRequestID: "question-1"))
        gate.fail(requestID: "question-1")

        XCTAssertTrue(gate.begin(requestID: "question-1", pendingRequestID: "question-1"))
    }

    func testAFailedHookInstallCanBeRepeatedFromWhereItIsReported() {
        let status = AgentHookInstallStatus()
        var attempts = 0
        status.register(provider: .claude, result: .unavailable("settings.json was locked")) {
            attempts += 1
            return .installed
        }

        XCTAssertEqual(status.failureReason(for: .claude), "settings.json was locked")
        XCTAssertTrue(status.canRetry(.claude))
        XCTAssertNil(status.failureReason(for: .codex), "one provider's failure is not another's")

        XCTAssertEqual(status.retry(provider: .claude), .installed)

        XCTAssertEqual(attempts, 1)
        XCTAssertNil(status.failureReason(for: .claude))
    }

    func testInputQueueReportsForegroundProcessChangeWithoutSendingReturn() async {
        let recorder = AgentLensFrameRecorder()
        recorder.acceptsFrames = false
        let queue = AgentLensInputQueue(
            transport: AgentLensInputTransport { frame in recorder.send(frame) }
        )

        do {
            try await queue.send("do not leak")
            XCTFail("a changed foreground process must reject input")
        } catch {
            XCTAssertEqual(error as? AgentLensInputError, .foregroundProcessChanged)
        }
        XCTAssertEqual(recorder.frames, [])
        await queue.stop()
    }

    func testSameSlotModeSwitchKeepsIdenticalSurfaceAndPIDGuardRefusesStaleTarget() {
        let slotID = UUID()
        let cwd = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let surface = AgentLensTestSurface(foregroundPID: 41)
        let pool = SurfacePool(backendName: "Agent Lens test") { _, _ in surface }
        let materialized = pool.surface(for: slotID, workspacePath: cwd)
        let lensPool = AgentLensPool()
        let model = lensPool.model(for: slotID, terminalPool: pool)

        model.mode = .session
        model.mode = .terminal

        XCTAssertTrue(materialized === pool.surface(for: slotID, workspacePath: cwd))
        XCTAssertEqual(pool.agentTerminalIdentity(for: slotID)?.foregroundPID, 41)
        XCTAssertTrue(pool.sendAgentInputFrame("safe", to: slotID, expectedForegroundPID: 41))
        surface.foregroundPID = 99
        XCTAssertFalse(pool.sendAgentInputFrame("stale", to: slotID, expectedForegroundPID: 41))
        XCTAssertEqual(surface.frames, ["safe"])
    }

    func testClosingSlotCancelsLensWorkAndReleasesItsViewModel() async {
        let slotID = UUID()
        let cwd = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let surface = AgentLensTestSurface(foregroundPID: nil)
        let terminalPool = SurfacePool(backendName: "Agent Lens test") { _, _ in surface }
        _ = terminalPool.surface(for: slotID, workspacePath: cwd)
        let lensPool = AgentLensPool()
        var model: AgentLensViewModel? = lensPool.model(for: slotID, terminalPool: terminalPool)
        weak let weakModel = model
        model?.start()

        lensPool.retainOnly([])
        model = nil
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(weakModel, "a closed slot must not retain discovery or transcript tasks")
    }

    func testLiveProcessTranscriptPipelineKeepsTheTerminalAndRoutesGuardedInput() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-lens-e2e-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let transcript = sessions.appendingPathComponent("live-session.jsonl")
        let session = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta",
            "payload": ["cwd": workspace.path],
        ])
        let assistant = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "payload": [
                "type": "agent_message",
                "id": "live-message",
                "message": "semantic projection is live",
            ],
        ])
        try (session + Data([0x0A]) + assistant + Data([0x0A])).write(to: transcript)

        // Preserve the PID while making both proofs observable to discovery: argv[0]
        // identifies Codex and tail keeps the exact transcript file descriptor open.
        let launcher = root.appendingPathComponent("codex")
        try Data("#!/bin/zsh\nexec -a /codex /usr/bin/tail -f \"$1\"\n".utf8).write(to: launcher)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let process = Process()
        process.executableURL = launcher
        process.arguments = [transcript.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let slotID = UUID()
        let surface = AgentLensTestSurface(foregroundPID: UInt64(process.processIdentifier))
        let terminalPool = SurfacePool(backendName: "Agent Lens E2E") { _, _ in surface }
        _ = terminalPool.surface(for: slotID, workspacePath: workspace)
        let identity = try XCTUnwrap(terminalPool.agentTerminalIdentity(for: slotID))
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        await registry.record(
            AgentHookEvent(
                paneID: slotID,
                surfaceToken: identity.surfaceToken,
                provider: .codex,
                sessionID: "live-root-session",
                transcriptPath: transcript.path,
                hookEventName: "SessionStart",
                agentID: nil
            )
        )
        let discovery = AgentLensDiscovery(
            homeDirectory: home,
            sessionRegistry: registry
        )
        let model = AgentLensViewModel(
            slotID: slotID,
            terminalPool: terminalPool,
            discovery: discovery
        )
        model.start()
        defer { model.stop() }

        try await waitUntil(timeout: .seconds(5)) {
            model.snapshot.messages.contains { $0.id == "live-message" } &&
                model.resolution?.confidence == .exact
        }
        XCTAssertEqual(model.resolution?.provider, .codex)
        XCTAssertEqual(model.resolution?.confidence, .exact)
        // Attaching a transcript is an observation, not a decision: the pane the person is
        // typing into keeps rendering its PTY until they pick another renderer themselves.
        XCTAssertEqual(model.mode, .terminal)
        XCTAssertEqual(model.snapshot.messages.last?.text, "semantic projection is live")

        model.draft = "continue safely"
        await model.sendDraft()
        XCTAssertEqual(
            surface.frames,
            ["\u{1B}[200~continue safely\u{1B}[201~", "\r"]
        )
        XCTAssertTrue(model.snapshot.messages.contains { message in
            message.role == .user && message.text == "continue safely" &&
                message.evidence.authority == .observed
        })

        // The person moves to the Session view and the agent then stops being the foreground
        // process. A send that cannot reach it says so — the diagnostic reaches the chrome
        // header — and leaves both the renderer and the unsent text exactly where they were.
        model.mode = .session
        surface.foregroundPID = 999_999
        model.draft = "into a changed foreground"
        await model.sendDraft()

        XCTAssertEqual(model.mode, .session)
        XCTAssertEqual(model.draft, "into a changed foreground")
        XCTAssertEqual(
            surface.frames,
            ["\u{1B}[200~continue safely\u{1B}[201~", "\r"]
        )
        XCTAssertTrue(model.snapshot.diagnostics.contains { $0.severity == .error })
    }

    func testCodexWithoutHookDoesNotAttachAnotherTranscriptFromSameDirectory() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-lens-stable-inference-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstTranscript = sessions.appendingPathComponent("first.jsonl")
        let competingTranscript = sessions.appendingPathComponent("competing.jsonl")
        let session = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta",
            "payload": ["cwd": workspace.path],
        ]) + Data([0x0A])
        try session.write(to: firstTranscript)
        try session.write(to: competingTranscript)
        let now = Date()
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: firstTranscript.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: competingTranscript.path
        )

        let launcher = root.appendingPathComponent("codex")
        let heartbeat = root.appendingPathComponent("heartbeat.txt")
        try Data().write(to: heartbeat)
        try Data("#!/bin/zsh\nexec -a /codex /usr/bin/tail -f \"$1\"\n".utf8).write(to: launcher)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let process = Process()
        process.executableURL = launcher
        process.arguments = [heartbeat.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let identity = AgentTerminalIdentity(
            slotID: UUID(),
            surfaceToken: UUID(),
            foregroundPID: UInt64(process.processIdentifier),
            cwd: workspace,
            title: "Codex"
        )
        let discovery = AgentLensDiscovery(homeDirectory: home)
        let resolved = await discovery.resolve(identity)
        let resolution = try XCTUnwrap(resolved)

        XCTAssertNil(resolution.transcriptURL)
        XCTAssertEqual(resolution.confidence, .processOnly)
    }

    func testClaudeWithoutHookDoesNotAttachAnotherTranscriptFromSameDirectory() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-claude-stable-identity-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = home.appendingPathComponent(
            ".claude/projects/-" + workspace.path.dropFirst().replacingOccurrences(of: "/", with: "-"),
            isDirectory: true
        )
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let unrelated = project.appendingPathComponent("another-session.jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"other work\"}}\n".utf8)
            .write(to: unrelated)

        let discovery = AgentLensDiscovery(
            homeDirectory: home,
            processProvider: { _ in .claude }
        )
        let resolved = await discovery.resolve(
            AgentTerminalIdentity(
                slotID: UUID(),
                surfaceToken: UUID(),
                foregroundPID: 42,
                cwd: workspace,
                title: "Claude"
            )
        )
        let resolution = try XCTUnwrap(resolved)

        XCTAssertNil(resolution.transcriptURL)
        XCTAssertEqual(resolution.confidence, .processOnly)
    }

    func testCodexHookBindingIsAuthoritativeAndScopedToSurfaceIncarnation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-binding-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        let transcript = sessions.appendingPathComponent("bound.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: root) }

        let slotID = UUID()
        let currentToken = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        await registry.record(
            AgentHookEvent(
                paneID: slotID,
                surfaceToken: currentToken,
                provider: .codex,
                sessionID: "root-session",
                transcriptPath: transcript.path,
                hookEventName: "SessionStart",
                agentID: nil,
                processGroupID: 42
            )
        )

        let discovery = AgentLensDiscovery(
            homeDirectory: root,
            sessionRegistry: registry,
            processProvider: { _ in .codex }
        )
        let current = AgentTerminalIdentity(
            slotID: slotID,
            surfaceToken: currentToken,
            foregroundPID: 42,
            cwd: root,
            title: "Codex"
        )
        let stale = AgentTerminalIdentity(
            slotID: slotID,
            surfaceToken: UUID(),
            foregroundPID: 42,
            cwd: root,
            title: "Codex"
        )

        let attachedValue = await discovery.resolve(current)
        let rejectedValue = await discovery.resolve(stale)
        let attached = try XCTUnwrap(attachedValue)
        let rejected = try XCTUnwrap(rejectedValue)
        XCTAssertEqual(attached.transcriptURL, transcript.standardizedFileURL)
        XCTAssertEqual(attached.sessionID, "root-session")
        XCTAssertEqual(attached.confidence, .exact)
        XCTAssertNil(rejected.transcriptURL)
        XCTAssertEqual(rejected.confidence, .processOnly)
    }

    func testHookBindingWaitsForTranscriptCreatedAfterClaudePromptHook() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-delayed-transcript-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent(".claude/projects/-tmp-workspace", isDirectory: true)
        let transcript = project.appendingPathComponent("claude-session.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paneID = UUID()
        let surfaceToken = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [project])
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: surfaceToken,
                provider: .claude,
                sessionID: "claude-session",
                transcriptPath: transcript.path,
                hookEventName: "UserPromptSubmit",
                agentID: nil,
                processGroupID: 42
            )
        )

        let beforeCreation = await registry.binding(
            paneID: paneID,
            surfaceToken: surfaceToken
        )
        XCTAssertNil(beforeCreation)

        try Data("{}\n".utf8).write(to: transcript)
        let afterCreation = await registry.binding(
            paneID: paneID,
            surfaceToken: surfaceToken
        )

        XCTAssertEqual(afterCreation?.provider, .claude)
        XCTAssertEqual(afterCreation?.sessionID, "claude-session")
        XCTAssertEqual(afterCreation?.transcriptURL, transcript.standardizedFileURL)
        XCTAssertEqual(afterCreation?.processGroupID, 42)
    }

    func testPendingNewSessionStartSurvivesDelayedOldStop() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-pending-race-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent(".claude/projects/-tmp-workspace", isDirectory: true)
        let oldTranscript = project.appendingPathComponent("old-session.jsonl")
        let newTranscript = project.appendingPathComponent("new-session.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: oldTranscript)
        defer { try? FileManager.default.removeItem(at: root) }

        let paneID = UUID()
        let surfaceToken = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [project])
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: surfaceToken,
                provider: .claude,
                sessionID: "old-session",
                transcriptPath: oldTranscript.path,
                hookEventName: "SessionStart",
                agentID: nil,
                processGroupID: 42
            )
        )
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: surfaceToken,
                provider: .claude,
                sessionID: "new-session",
                transcriptPath: newTranscript.path,
                hookEventName: "SessionStart",
                agentID: nil,
                processGroupID: 42
            )
        )
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: surfaceToken,
                provider: .claude,
                sessionID: "old-session",
                transcriptPath: oldTranscript.path,
                hookEventName: "Stop",
                agentID: nil,
                processGroupID: 42
            )
        )

        try Data("{}\n".utf8).write(to: newTranscript)
        let binding = await registry.binding(paneID: paneID, surfaceToken: surfaceToken)

        XCTAssertEqual(binding?.sessionID, "new-session")
        XCTAssertEqual(binding?.transcriptURL, newTranscript.standardizedFileURL)
    }

    func testClaudeHookBindingMatchesAProviderChildInTheSameProcessGroup() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-claude-process-group-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = home.appendingPathComponent(
            ".claude/projects/-" + workspace.path.dropFirst().replacingOccurrences(of: "/", with: "-"),
            isDirectory: true
        )
        let transcript = project.appendingPathComponent("claude-session.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: root) }

        let paneID = UUID()
        let surfaceToken = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [project])
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: surfaceToken,
                provider: .claude,
                sessionID: "claude-session",
                transcriptPath: transcript.path,
                hookEventName: "SessionStart",
                agentID: nil,
                processGroupID: 42
            )
        )
        let discovery = AgentLensDiscovery(
            homeDirectory: home,
            sessionRegistry: registry,
            processProvider: { _ in .claude },
            processGroupProvider: { _ in 42 }
        )

        let resolution = await discovery.resolve(
            AgentTerminalIdentity(
                slotID: paneID,
                surfaceToken: surfaceToken,
                foregroundPID: 84,
                cwd: workspace,
                title: "Claude child"
            )
        )

        XCTAssertEqual(resolution?.confidence, .exact)
        XCTAssertEqual(resolution?.transcriptURL, transcript.standardizedFileURL)
    }

    func testSubagentHookCannotReplaceRootBinding() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-subagent-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        let rootTranscript = sessions.appendingPathComponent("root.jsonl")
        let childTranscript = sessions.appendingPathComponent("child.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: rootTranscript)
        try Data("{}\n".utf8).write(to: childTranscript)
        defer { try? FileManager.default.removeItem(at: root) }

        let slotID = UUID()
        let surfaceToken = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        await registry.record(
            AgentHookEvent(
                paneID: slotID,
                surfaceToken: surfaceToken,
                provider: .codex,
                sessionID: "root-session",
                transcriptPath: rootTranscript.path,
                hookEventName: "SessionStart",
                agentID: nil
            )
        )
        await registry.record(
            AgentHookEvent(
                paneID: slotID,
                surfaceToken: surfaceToken,
                provider: .codex,
                sessionID: "root-session",
                transcriptPath: childTranscript.path,
                hookEventName: "SubagentStart",
                agentID: "child-agent"
            )
        )

        let bindingValue = await registry.binding(
            paneID: slotID,
            surfaceToken: surfaceToken
        )
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.transcriptURL, rootTranscript.standardizedFileURL)
        XCTAssertEqual(binding.sessionID, "root-session")
    }

    func testDelayedOldSessionCannotReclaimBindingAndNewSessionStartCanReplaceIt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        let first = sessions.appendingPathComponent("first.jsonl")
        let second = sessions.appendingPathComponent("second.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: first)
        try Data("{}\n".utf8).write(to: second)
        let now = Date()
        try FileManager.default.setAttributes(
            [.creationDate: now.addingTimeInterval(-10)],
            ofItemAtPath: first.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: now],
            ofItemAtPath: second.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let paneID = UUID()
        let token = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        func event(_ sessionID: String, _ path: URL, _ name: String) -> AgentHookEvent {
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: token,
                provider: .codex,
                sessionID: sessionID,
                transcriptPath: path.path,
                hookEventName: name,
                agentID: nil
            )
        }

        await registry.record(event("first", first, "SessionStart"))
        await registry.record(event("second", second, "SessionStart"))
        await registry.record(event("first", first, "SessionStart"))

        let binding = await registry.binding(paneID: paneID, surfaceToken: token)
        XCTAssertEqual(binding?.sessionID, "second")
        XCTAssertEqual(binding?.transcriptURL, second.standardizedFileURL)
    }

    func testRegistryRejectsOutOfRootAndSymlinkEscapedTranscripts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-agent-hook-path-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        let outside = root.appendingPathComponent("outside.jsonl")
        let escaped = sessions.appendingPathComponent("escaped.jsonl")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let paneID = UUID()
        let token = UUID()
        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        for path in [outside, escaped] {
            await registry.record(
                AgentHookEvent(
                    paneID: paneID,
                    surfaceToken: token,
                    provider: .codex,
                    sessionID: path.lastPathComponent,
                    transcriptPath: path.path,
                    hookEventName: "SessionStart",
                    agentID: nil
                )
            )
        }

        let binding = await registry.binding(paneID: paneID, surfaceToken: token)
        XCTAssertNil(binding)
    }

    func testSurfaceRecreationRotatesIncarnationToken() {
        let slotID = UUID()
        let workspace = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let surface = AgentLensTestSurface(foregroundPID: 7)
        var minted: [UUID] = []
        let pool = SurfacePool(
            backendName: "Agent Lens identity",
            makeSurfaceWithIdentity: { _, token, _ in
                minted.append(token)
                return surface
            }
        )

        _ = pool.surface(for: slotID, workspacePath: workspace)
        let first = pool.agentTerminalIdentity(for: slotID)?.surfaceToken
        pool.retainOnly([])
        _ = pool.surface(for: slotID, workspacePath: workspace)
        let second = pool.agentTerminalIdentity(for: slotID)?.surfaceToken

        XCTAssertEqual(minted.count, 2)
        XCTAssertNotEqual(first, second)
    }

    func testAgentHookInstallerPreservesExistingHooksAndIsIdempotent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-hook-install-\(UUID().uuidString)", isDirectory: true)
        let script = root.appendingPathComponent("runtime/codex-hook.sh")
        let hooks = root.appendingPathComponent("codex/hooks.json")
        try FileManager.default.createDirectory(
            at: hooks.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "description": "keep me",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "existing-command"]],
                ]],
                "SessionStart": [[
                    "hooks": [["type": "command", "command": "existing-session-hook"]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: hooks)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            AgentHookInstaller.install(provider: .codex, scriptURL: script, hooksURL: hooks),
            .installed
        )
        let once = try Data(contentsOf: hooks)
        let otherChannelScript = root.appendingPathComponent(
            "other-channel/runtime/codex-hook.sh"
        )
        XCTAssertEqual(
            AgentHookInstaller.install(
                provider: .codex,
                scriptURL: otherChannelScript,
                hooksURL: hooks
            ),
            .alreadyInstalled
        )
        XCTAssertEqual(try Data(contentsOf: hooks), once)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: once) as? [String: Any]
        )
        XCTAssertEqual(document["description"] as? String, "keep me")
        let installedHooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        XCTAssertNotNil(installedHooks["PreToolUse"])
        let sessionGroups = try XCTUnwrap(installedHooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionGroups.count, 2)
        let preservedHandlers = sessionGroups[0]["hooks"] as? [[String: Any]]
        XCTAssertEqual(preservedHandlers?.first?["command"] as? String, "existing-session-hook")
        let installedHandlers = try XCTUnwrap(sessionGroups[1]["hooks"] as? [[String: Any]])
        let installedCommand = try XCTUnwrap(installedHandlers.first?["command"] as? String)
        XCTAssertTrue(installedCommand.contains("TENON_AGENT_HOOK_SCRIPT"), installedCommand)
        XCTAssertFalse(installedCommand.contains(script.path), installedCommand)
        XCTAssertFalse(installedCommand.contains(otherChannelScript.path), installedCommand)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testAgentHookInstallerWritesClaudeProviderIntoAdditiveSettingsHook() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-claude-hook-install-\(UUID().uuidString)", isDirectory: true)
        let script = root.appendingPathComponent("runtime/agent-hook.sh")
        let settings = root.appendingPathComponent("claude/settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            AgentHookInstaller.install(
                provider: .claude,
                scriptURL: script,
                hooksURL: settings
            ),
            .installed
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let handlers = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(handlers.first?["command"] as? String)
        let scriptText = try String(contentsOf: script, encoding: .utf8)

        XCTAssertTrue(command.contains("TENON_AGENT_PROVIDER='claude'"), command)
        XCTAssertTrue(command.contains("TENON_AGENT_HOOK_SCRIPT"), command)
        XCTAssertFalse(command.contains(script.path), command)
        XCTAssertTrue(command.contains("tenon-agent-hook-v3"), command)
        XCTAssertTrue(scriptText.contains("-o ppid="), scriptText)
        XCTAssertTrue(scriptText.contains("-o comm="), scriptText)
        XCTAssertTrue(scriptText.contains("agent_pgid"), scriptText)

        // Claude Code's transcript is written at turn boundaries, so these are the only
        // account of a tool that is still running or a question still waiting.
        XCTAssertEqual(
            Set(hooks.keys),
            [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "Notification",
                "Stop",
            ]
        )
    }

    func testCodexKeepsTheSmallerHookSetItsNativeProtocolAlreadyCovers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-codex-hook-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("codex/hooks.json")

        XCTAssertEqual(
            AgentHookInstaller.install(
                provider: .codex,
                scriptURL: root.appendingPathComponent("runtime/agent-hook.sh"),
                hooksURL: hooksURL
            ),
            .installed
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])

        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "UserPromptSubmit", "Stop"])
    }

    func testAgentHookInstallerReplacesLegacyTenonHandlerAndPreservesUnrelatedHook() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-hook-migration-\(UUID().uuidString)", isDirectory: true)
        let script = root.appendingPathComponent("runtime/agent-hook.sh")
        let hooksURL = root.appendingPathComponent("codex/hooks.json")
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyCommand = "/bin/sh /tmp/codex-hook.sh # tenon-agent-hook-v1"
        let previousCommand = "/bin/sh /tmp/codex-hook.sh # tenon-agent-hook-v2"
        let unrelatedCommand = "/bin/sh /tmp/keep-me.sh"
        try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "SessionStart": [[
                    "hooks": [
                        ["type": "command", "command": legacyCommand],
                        ["type": "command", "command": previousCommand],
                        ["type": "command", "command": unrelatedCommand],
                    ],
                ]],
            ],
        ]).write(to: hooksURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            AgentHookInstaller.install(
                provider: .codex,
                scriptURL: script,
                hooksURL: hooksURL
            ),
            .installed
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = groups.flatMap { group in
            (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }

        XCTAssertFalse(commands.contains(legacyCommand))
        XCTAssertFalse(commands.contains(previousCommand))
        XCTAssertTrue(commands.contains(unrelatedCommand))
        XCTAssertTrue(commands.contains { command in
            command.contains("TENON_AGENT_PROVIDER='codex'") &&
                command.contains("tenon-agent-hook-v3")
        })
    }

    func testHookRequestCarriesTheToolFactsTheLensProjectsAndBoundsThem() throws {
        let paneID = UUID()
        let surfaceToken = UUID()
        let headers = [
            "authorization": "Bearer expected",
            "x-tenon-pane-id": paneID.uuidString,
            "x-tenon-surface-token": surfaceToken.uuidString,
            "x-tenon-process-group": "42",
            "x-tenon-agent-provider": "claude",
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "transcript_path": "/tmp/session.jsonl",
            "hook_event_name": "PreToolUse",
            "cwd": "/repo",
            "permission_mode": "default",
            "tool_name": "Bash",
            "tool_use_id": "toolu_01Boundary",
            "tool_input": ["command": "swift test", "description": "Run the suite"],
        ])

        let event = try AgentHookRequestDecoder.decode(
            headers: headers,
            body: body,
            expectedBearerToken: "expected"
        )

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.activity.toolName, "Bash")
        XCTAssertEqual(event.activity.toolUseID, "toolu_01Boundary")
        XCTAssertEqual(event.activity.workingDirectory, "/repo")
        XCTAssertEqual(event.activity.permissionMode, "default")
        XCTAssertEqual(
            event.activity.toolInputJSON,
            #"{"command":"swift test","description":"Run the suite"}"#
        )

        // A tool argument can be a whole file. The record is accepted and the oversized
        // document is dropped rather than kept half-parsed.
        let oversized = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "transcript_path": "/tmp/session.jsonl",
            "hook_event_name": "PreToolUse",
            "tool_name": "Write",
            "tool_use_id": "toolu_01Big",
            "tool_input": ["content": String(repeating: "x", count: 64 << 10)],
        ])
        let bounded = try AgentHookRequestDecoder.decode(
            headers: headers,
            body: oversized,
            expectedBearerToken: "expected"
        )
        XCTAssertEqual(bounded.activity.toolUseID, "toolu_01Big")
        XCTAssertNil(bounded.activity.toolInputJSON)
    }

    func testHookRequestDecoderRejectsWrongTokenAndOversizedBodies() throws {
        let headers = [
            "authorization": "Bearer expected",
            "x-tenon-pane-id": UUID().uuidString,
            "x-tenon-surface-token": UUID().uuidString,
            "x-tenon-process-group": "42",
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "transcript_path": "/tmp/session.jsonl",
            "hook_event_name": "SessionStart",
        ])

        XCTAssertThrowsError(
            try AgentHookRequestDecoder.decode(
                headers: headers,
                body: body,
                expectedBearerToken: "wrong"
            )
        )
        XCTAssertThrowsError(
            try AgentHookRequestDecoder.decode(
                headers: headers,
                body: Data(repeating: 0x61, count: AgentHookRequestDecoder.maxBodyBytes + 1),
                expectedBearerToken: "expected"
            )
        )
        let unknownEvent = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "transcript_path": "/tmp/session.jsonl",
            "hook_event_name": "FutureEvent",
        ])
        XCTAssertThrowsError(
            try AgentHookRequestDecoder.decode(
                headers: headers,
                body: unknownEvent,
                expectedBearerToken: "expected"
            )
        )
    }

    func testHookRequestDecoderPreservesDeclaredClaudeProvider() throws {
        let paneID = UUID()
        let surfaceToken = UUID()
        let event = try AgentHookRequestDecoder.decode(
            headers: [
                "authorization": "Bearer expected",
                "x-tenon-pane-id": paneID.uuidString,
                "x-tenon-surface-token": surfaceToken.uuidString,
                "x-tenon-process-group": "42",
                "x-tenon-agent-provider": "claude",
            ],
            body: try JSONSerialization.data(withJSONObject: [
                "session_id": "claude-session",
                "transcript_path": "/tmp/claude.jsonl",
                "hook_event_name": "SessionStart",
            ]),
            expectedBearerToken: "expected"
        )

        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.paneID, paneID)
        XCTAssertEqual(event.surfaceToken, surfaceToken)
    }

    func testHookServerAcceptsAuthenticatedLoopbackEvent() async throws {
        let sink = AgentHookEventSink()
        let server = AgentHookServer { event in
            Task { await sink.record(event) }
        }
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let paneID = UUID()
        let surfaceToken = UUID()
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/agent-events")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(server.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(paneID.uuidString, forHTTPHeaderField: "X-Tenon-Pane-ID")
        request.setValue(
            surfaceToken.uuidString,
            forHTTPHeaderField: "X-Tenon-Surface-Token"
        )
        request.setValue("77", forHTTPHeaderField: "X-Tenon-Process-Group")
        request.setValue("claude", forHTTPHeaderField: "X-Tenon-Agent-Provider")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_id": "root-session",
            "transcript_path": "/tmp/root.jsonl",
            "hook_event_name": "SessionStart",
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        for _ in 0..<20 {
            if await sink.event != nil { break }
            await Task.yield()
        }
        let event = await sink.event
        XCTAssertEqual(event?.paneID, paneID)
        XCTAssertEqual(event?.surfaceToken, surfaceToken)
        XCTAssertEqual(event?.processGroupID, 77)
        XCTAssertEqual(event?.provider, .claude)
        XCTAssertEqual(event?.sessionID, "root-session")
    }

    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw AgentLensE2ETestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private enum AgentLensE2ETestError: Error {
    case timedOut
}

/// What the Agent Lens pane contributes to the ONE chrome header its card draws, and the
/// mapping the picker's three states make onto the two properties the pane actually holds.
///
/// Both live outside the view so they can be asserted without a window — the fitness test
/// `docs/tdd.md` sets. Everything conditional is asserted in BOTH directions in the same test:
/// a projection that returned `.empty` for every input would satisfy any suppression assertion
/// on its own, so each negative is paired with the positive that rules that failure out.
final class AgentLensPaneHeaderTests: XCTestCase {
    // MARK: - Item readers
    //
    // `PaneHeaderItem` is a flat enum with no accessors beyond `id`, so these are the test's
    // own way in. They match on the CASE as well as the payload, so an assertion cannot be
    // satisfied by the right text arriving in the wrong kind of item.

    private func dotTint(_ item: PaneHeaderItem?) -> ColorToken? {
        guard case let .dot(_, tint, _) = item else { return nil }
        return tint
    }

    private func dotTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .dot(_, _, tooltip) = item else { return nil }
        return tooltip
    }

    private func labelText(_ item: PaneHeaderItem?) -> String? {
        guard case let .label(_, text, _, _, _, _) = item else { return nil }
        return text
    }

    private func labelWeight(_ item: PaneHeaderItem?) -> FontWeight? {
        guard case let .label(_, _, weight, _, _, _) = item else { return nil }
        return weight
    }

    private func labelColor(_ item: PaneHeaderItem?) -> ColorToken? {
        guard case let .label(_, _, _, color, _, _) = item else { return nil }
        return color
    }

    private func labelTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .label(_, _, _, _, _, tooltip) = item else { return nil }
        return tooltip
    }

    private func imageSymbol(_ item: PaneHeaderItem?) -> String? {
        guard case let .image(_, systemName, _, _) = item else { return nil }
        return systemName
    }

    private func imageTint(_ item: PaneHeaderItem?) -> ColorToken? {
        guard case let .image(_, _, tint, _) = item else { return nil }
        return tint
    }

    private func segments(_ item: PaneHeaderItem?) -> [PaneHeaderSegment]? {
        guard case let .segmented(_, segments, _, _, _) = item else { return nil }
        return segments
    }

    private func selection(_ item: PaneHeaderItem?) -> String? {
        guard case let .segmented(_, _, selection, _, _) = item else { return nil }
        return selection
    }

    private func segmentedAccessibilityID(_ item: PaneHeaderItem?) -> String? {
        guard case let .segmented(_, _, _, _, accessibilityID) = item else { return nil }
        return accessibilityID
    }

    private func toggleSymbol(_ item: PaneHeaderItem?) -> String? {
        guard case let .toggle(_, systemName, _, _, _, _) = item else { return nil }
        return systemName
    }

    private func toggleIsOn(_ item: PaneHeaderItem?) -> Bool? {
        guard case let .toggle(_, _, isOn, _, _, _) = item else { return nil }
        return isOn
    }

    /// The renderer picker, found by its own command id rather than by position: the trailing
    /// run's ORDER is pinned by one test on purpose, and every other test asking about the
    /// picker should keep passing when a control is added beside it.
    private func presentationPicker(_ header: PaneHeader) -> PaneHeaderItem? {
        header.trailing.first { $0.id == PaneHeaderCommand.agentLensPresentation.rawValue }
    }

    private func toggleTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .toggle(_, _, _, _, tooltip, _) = item else { return nil }
        return tooltip
    }

    private func header(
        isAgentDetected: Bool = true,
        provider: AgentProvider? = .claude,
        status: AgentLensStatus = .running,
        currentAction: String = "Working",
        hasDiagnostics: Bool = false,
        presentation: AgentLensPresentation = .session,
        showsInspector: Bool = false
    ) -> PaneHeader {
        AgentLensPaneHeader.header(
            isAgentDetected: isAgentDetected,
            provider: provider,
            status: status,
            currentAction: currentAction,
            hasDiagnostics: hasDiagnostics,
            presentation: presentation,
            showsInspector: showsInspector
        )
    }

    // MARK: - What the pane says

    /// A plain shell pane keeps the bare chrome it has today. Nothing is detected, so there is
    /// no provider to name, no status to report and no second renderer to switch to — and a
    /// picker offering a Session view of a session that does not exist is worse than no picker.
    func testAPaneWithNoDetectedAgentContributesNothingToTheChrome() {
        XCTAssertEqual(header(isAgentDetected: false), .empty)
        // Paired so the assertion above cannot pass by the projection returning `.empty` for
        // everything, which is exactly what an unimplemented projection does.
        XCTAssertNotEqual(header(isAgentDetected: true), .empty)
    }

    func testADetectedAgentNamesItsProviderAndStatusInTheLeadingRun() {
        let detected = header(
            provider: .claude,
            status: .waitingForUser,
            currentAction: "Approve the write to Package.swift"
        )

        XCTAssertEqual(detected.leading.map(\.id), ["state", "provider", "status"])
        XCTAssertEqual(dotTint(detected.leading.first), .amber)
        XCTAssertEqual(labelText(detected.leading.dropFirst().first), "Claude")
        XCTAssertEqual(labelWeight(detected.leading.dropFirst().first), .semibold)
        XCTAssertEqual(labelText(detected.leading.last), "Needs input")
        XCTAssertEqual(labelColor(detected.leading.last), .muted)
        // What the agent is doing right now is the one thing in this strip that is not already
        // written on it, so it hangs off the two items that are about status.
        XCTAssertEqual(dotTooltip(detected.leading.first), "Approve the write to Package.swift")
        XCTAssertEqual(labelTooltip(detected.leading.last), "Approve the write to Package.swift")
    }

    /// A provider Agent Lens has not identified yet still has a pane, and the pane still has to
    /// name itself.
    func testAnUnidentifiedProviderStillNamesThePane() {
        XCTAssertEqual(labelText(header(provider: nil).leading.dropFirst().first), "Agent")
        XCTAssertEqual(labelText(header(provider: .codex).leading.dropFirst().first), "Codex")
    }

    /// The dot resolves its colour through the header's own token space rather than a
    /// hand-mixed `Color`, so the one strip cannot disagree with itself about what green is.
    func testTheStatusDotSpeaksTheHeadersOwnColourTokens() {
        let tints: [(AgentLensStatus, ColorToken)] = [
            (.completed, .green),
            (.failed("boom"), .red),
            (.running, .amber),
            (.waitingForUser, .amber),
            (.degraded("partial"), .amber),
            (.ready, .muted),
            (.detecting, .muted),
            (.unavailable, .muted),
        ]
        for (status, expected) in tints {
            XCTAssertEqual(
                dotTint(header(status: status).leading.first),
                expected,
                "\(status.title) should read as \(expected.rawValue)"
            )
        }
    }

    func testTheDiagnosticWarningAppearsOnlyWhileThereAreDiagnostics() {
        let quiet = header(hasDiagnostics: false)
        XCTAssertEqual(quiet.leading.map(\.id), ["state", "provider", "status"])

        let noisy = header(hasDiagnostics: true)
        XCTAssertEqual(noisy.leading.map(\.id), ["state", "provider", "status", "diagnostics"])
        XCTAssertEqual(imageSymbol(noisy.leading.last), "exclamationmark.triangle.fill")
        XCTAssertEqual(imageTint(noisy.leading.last), .amber)
    }

    // MARK: - What the pane offers

    func testThePickerAndTheInspectorToggleAreTheTrailingRun() {
        let shown = header(presentation: .split, showsInspector: true)

        // Three controls, and the order is the claim: the account is a property of the CONTENT
        // and the other two are the pane's own chrome, so the content control sits furthest from
        // the close button and is the first to fold away when the pane narrows.
        XCTAssertEqual(
            shown.trailing.map(\.id),
            [
                PaneHeaderCommand.agentLensAccount.rawValue,
                PaneHeaderCommand.agentLensPresentation.rawValue,
                PaneHeaderCommand.agentLensInspector.rawValue,
            ]
        )
        XCTAssertEqual(
            segments(shown.trailing[1])?.map(\.value),
            AgentLensPresentation.allCases.map(\.rawValue)
        )
        XCTAssertEqual(selection(shown.trailing[1]), "split")
        // The XCUITest anchor the in-body picker carried. A plugin cannot mint one; a
        // host-native producer must, or the identifier is lost in the move into chrome.
        XCTAssertEqual(segmentedAccessibilityID(shown.trailing[1]), "tenon.agentLens.mode")

        XCTAssertEqual(toggleSymbol(shown.trailing.last), "sidebar.right")
        // `isOn` is the item's own CURRENT state, not the next one.
        XCTAssertEqual(toggleIsOn(shown.trailing.last), true)
        XCTAssertEqual(toggleTooltip(shown.trailing.last), "Hide context and evidence")

        // A terminal-only pane draws no Chat and no Timeline, so it publishes no account picker
        // and the presentation control is the whole head of its run again.
        let hidden = header(presentation: .terminal, showsInspector: false)
        XCTAssertEqual(
            hidden.trailing.map(\.id),
            [
                PaneHeaderCommand.agentLensPresentation.rawValue,
                PaneHeaderCommand.agentLensInspector.rawValue,
            ]
        )
        XCTAssertEqual(selection(hidden.trailing.first), "terminal")
        XCTAssertEqual(toggleIsOn(hidden.trailing.last), false)
        XCTAssertEqual(toggleTooltip(hidden.trailing.last), "Show context and evidence")
    }

    /// The split option is the one control in this strip that draws no words, so the two
    /// readers that need some are both written for: the pointer wants hover text, VoiceOver
    /// wants a spoken name.
    func testTheSplitOptionIsIconOnlyAndSaysWhatItIsToBothReaders() {
        let options = try? XCTUnwrap(segments(presentationPicker(header())))
        let split = options?.first { $0.value == "split" }

        XCTAssertEqual(split?.systemName, "rectangle.split.2x1")
        XCTAssertNil(split?.label, "the split option draws its glyph, never a word")
        XCTAssertEqual(split?.tooltip, "Session and Terminal side by side")
        // A spoken name stands in for a visible segment label and is bounded like one, so it
        // is written short rather than truncated: `PaneHeaderSegment.maximumLabelLength` is 32
        // and the sentence above is 33, which reached VoiceOver as "side by sid".
        XCTAssertEqual(split?.accessibilityLabel, "Session beside Terminal")
        XCTAssertLessThanOrEqual(
            split?.accessibilityLabel?.count ?? .max,
            PaneHeaderSegment.maximumLabelLength,
            "an over-long spoken name arrives cut mid-word, which is worse than a shorter one"
        )

        // The other two DO show their names, so a tooltip repeating the text under the pointer
        // would be noise — which is the rule `PaneHeaderSegment` states and this pins.
        let session = options?.first { $0.value == "session" }
        XCTAssertEqual(session?.label, "Session")
        XCTAssertNil(session?.tooltip)
    }

    /// Every clickable thing this pane publishes must resolve back into a typed command,
    /// because that resolution is the only route the canvas offers a host-native pane: an id
    /// that fails it is a control a user can click while nothing happens.
    func testEveryInteractiveAgentLensHeaderItemResolvesBackToAPaneHeaderCommand() {
        let interactive = (header().leading + header().trailing)
            .filter(\.isInteractive)
            .map(\.id)

        XCTAssertEqual(
            Set(interactive),
            [
                PaneHeaderCommand.agentLensAccount.rawValue,
                PaneHeaderCommand.agentLensPresentation.rawValue,
                PaneHeaderCommand.agentLensInspector.rawValue,
            ]
        )
        for id in interactive {
            XCTAssertNotNil(
                PaneHeaderCommand(rawValue: id),
                "\(id) is clickable but resolves to no typed command, so its click is dropped"
            )
        }
    }

    // MARK: - Three states, two properties

    /// The picker names a combination of two properties the pane holds separately, so the
    /// mapping runs both ways and neither direction may invent state the other does not.
    func testThePickerReadsAndWritesThePanesTwoRendererProperties() {
        XCTAssertEqual(AgentLensPresentation(mode: .session, showsSplitView: false), .session)
        XCTAssertEqual(AgentLensPresentation(mode: .terminal, showsSplitView: false), .terminal)
        // Split wins over whichever single renderer was last chosen, because it is showing it.
        XCTAssertEqual(AgentLensPresentation(mode: .session, showsSplitView: true), .split)
        XCTAssertEqual(AgentLensPresentation(mode: .terminal, showsSplitView: true), .split)

        XCTAssertEqual(AgentLensPresentation.session.mode, .session)
        XCTAssertFalse(AgentLensPresentation.session.showsSplitView)
        XCTAssertEqual(AgentLensPresentation.terminal.mode, .terminal)
        XCTAssertFalse(AgentLensPresentation.terminal.showsSplitView)
        // Picking split leaves the single-renderer choice alone: it is still the renderer the
        // pane returns to when split is turned off, and overwriting it here would silently
        // discard the person's last answer.
        XCTAssertNil(AgentLensPresentation.split.mode)
        XCTAssertTrue(AgentLensPresentation.split.showsSplitView)
    }

    /// Whatever the pane is showing, the picker shows it back: a state the projection could
    /// not name would leave the control with no selected segment at all.
    func testEveryRendererStateTheModelCanHoldNamesASegment() {
        for mode in AgentLensMode.allCases {
            for showsSplitView in [false, true] {
                let presentation = AgentLensPresentation(
                    mode: mode,
                    showsSplitView: showsSplitView
                )
                let published = presentationPicker(header(presentation: presentation))
                XCTAssertEqual(selection(published), presentation.rawValue)
                XCTAssertTrue(
                    segments(published)?
                        .contains { $0.value == presentation.rawValue } ?? false,
                    "\(presentation.rawValue) is selected but is not one of the options"
                )
            }
        }
    }
}

private actor AgentHookEventSink {
    private(set) var event: AgentHookEvent?

    func record(_ event: AgentHookEvent) {
        self.event = event
    }
}

private actor AgentLensMessageSink {
    private(set) var didReadInitialRecord = false
    private(set) var message: AgentLensMessage?

    func recordInitialRead() {
        didReadInitialRecord = true
    }

    func record(_ message: AgentLensMessage) {
        self.message = message
    }
}

@MainActor
private final class AgentLensFrameRecorder {
    var acceptsFrames = true
    private(set) var frames: [String] = []

    func send(_ frame: String) -> Bool {
        guard acceptsFrames else { return false }
        frames.append(frame)
        return true
    }
}

@MainActor
private final class AgentLensTestSurface: TerminalSurface {
    let backendName = "Agent Lens test"
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var foregroundPID: UInt64?
    var processExited = false
    private(set) var frames: [String] = []

    init(foregroundPID: UInt64?) {
        self.foregroundPID = foregroundPID
    }

    func makeView() -> AnyView { AnyView(EmptyView()) }
    func sendText(_ text: String) { frames.append(text) }
}
