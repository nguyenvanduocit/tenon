import Foundation
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// The public boundary over the host's own answer to "which agents does this person run, and
/// how". Both contracts are read-only: one lists, the other composes a line a caller then
/// hands to `terminal.open.v1`, so pane topology stays where it already lives.
@MainActor
final class AgentIntentProviderTests: XCTestCase {
    // MARK: - Inventory

    func testTheInventoryListsInstalledAgentsWithTheOptionsThisPersonPasses() async throws {
        let machine = try Machine(installed: ["claude"], history: [
            "claude --model opus",
            "ls",
            "claude --model opus",
        ])

        let value = try successReply(
            await machine.invoke(.agentInventory, input: .object([:]))
        )

        guard case let .object(document) = value,
              case let .array(agents)? = document["agents"],
              case let .object(claude)? = agents.first
        else {
            return XCTFail("inventory must return an agents array")
        }
        XCTAssertEqual(agents.count, 1, "codex is not on this machine")
        XCTAssertEqual(claude["id"], .string("claude"))
        XCTAssertEqual(claude["label"], .string("Claude Code"))
        XCTAssertEqual(
            claude["arguments"],
            .array([.string("--model"), .string("opus")])
        )
        XCTAssertEqual(claude["habit"], .string("Model opus"))
    }

    /// A person's shell history is theirs. The inventory answers what to offer and what to
    /// pass, and nothing that would let a caller reconstruct where the binary lives or what
    /// else was typed at that prompt.
    func testTheInventoryCarriesNoPathAndNoHistory() async throws {
        let machine = try Machine(installed: ["claude"], history: [
            "claude --model opus",
            "claude --model opus",
            "ssh deploy@production",
        ])

        let value = try successReply(
            await machine.invoke(.agentInventory, input: .object([:]))
        )
        let rendered = String(describing: value)

        XCTAssertFalse(rendered.contains(machine.binDirectory.path))
        XCTAssertFalse(rendered.contains("ssh"))
        XCTAssertFalse(rendered.lowercased().contains("path"))
    }

    // MARK: - Composing a command

    func testTheComposedCommandCarriesTheHabitAndThePrompt() async throws {
        let machine = try Machine(installed: ["claude"], history: [
            "claude --model opus",
            "claude --model opus",
        ])

        let value = try successReply(
            await machine.invoke(
                .agentCommand,
                input: .object([
                    "agent": .string("claude"),
                    "prompt": .string("Do task T-104"),
                ])
            )
        )

        guard case let .object(document) = value else {
            return XCTFail("command must return an object")
        }
        XCTAssertEqual(
            document["arguments"],
            .array([
                .string("--model"),
                .string("opus"),
                .string("Do task T-104"),
            ])
        )
        XCTAssertEqual(document["handoff"], .bool(false))
        XCTAssertEqual(document["agent"], .string("claude"))
        guard case let .string(commandLine)? = document["commandLine"] else {
            return XCTFail("command must return a command line")
        }
        XCTAssertEqual(
            commandLine,
            "'\(machine.binDirectory.path)/claude' '--model' 'opus' 'Do task T-104'"
        )
    }

    func testACallerCanAskForThePlainAgentWithoutThisPersonsOptions() async throws {
        let machine = try Machine(installed: ["claude"], history: [
            "claude --dangerously-skip-permissions",
            "claude --dangerously-skip-permissions",
        ])

        let value = try successReply(
            await machine.invoke(
                .agentCommand,
                input: .object([
                    "agent": .string("claude"),
                    "includeUserOptions": .bool(false),
                ])
            )
        )

        guard case let .object(document) = value else {
            return XCTFail("command must return an object")
        }
        XCTAssertEqual(document["arguments"], .array([]))
    }

    func testAnAgentThisMachineDoesNotHaveFailsTypedInsteadOfGuessing() async throws {
        let machine = try Machine(installed: ["claude"], history: [])

        let reply = await machine.invoke(
            .agentCommand,
            input: .object(["agent": .string("codex")])
        )

        XCTAssertEqual(
            try failureCode(reply),
            "dev.tenon.core.agent-unavailable"
        )
    }

    func testAnUnknownAgentNameIsRefusedTheSameWay() async throws {
        let machine = try Machine(installed: ["claude"], history: [])

        let reply = await machine.invoke(
            .agentCommand,
            input: .object(["agent": .string("gemini")])
        )

        XCTAssertEqual(
            try failureCode(reply),
            "dev.tenon.core.agent-unavailable"
        )
    }

    // MARK: - Continuing a session across agents

    func testTheSessionsOwnAgentResumesItTheProvidersOwnWay() async throws {
        let machine = try Machine(installed: ["claude", "codex"], history: [])
        let session = "0199f0c1-2b7a-4d51-9d16-5b6f4a5c33d0"

        let value = try successReply(
            await machine.invoke(
                .agentCommand,
                input: .object([
                    "agent": .string("codex"),
                    "session": .object([
                        "agent": .string("codex"),
                        "sessionID": .string(session),
                    ]),
                ])
            )
        )

        guard case let .object(document) = value else {
            return XCTFail("command must return an object")
        }
        XCTAssertEqual(
            document["arguments"],
            .array([.string("resume"), .string(session)])
        )
        XCTAssertEqual(document["handoff"], .bool(false))
    }

    func testAnotherAgentIsHandedTheTranscriptInsteadOfAFlagThatDoesNotExist() async throws {
        let machine = try Machine(installed: ["claude", "codex"], history: [])
        let transcript = "/Users/x/.claude/projects/-Users-x-p/0199f0c1.jsonl"

        let value = try successReply(
            await machine.invoke(
                .agentCommand,
                input: .object([
                    "agent": .string("codex"),
                    "session": .object([
                        "agent": .string("claude"),
                        "sessionID": .string("0199f0c1"),
                        "transcriptPath": .string(transcript),
                    ]),
                ])
            )
        )

        guard case let .object(document) = value,
              case let .array(arguments)? = document["arguments"],
              case let .string(prompt)? = arguments.last
        else {
            return XCTFail("a handoff must arrive as a prompt")
        }
        XCTAssertEqual(document["handoff"], .bool(true))
        XCTAssertTrue(prompt.contains(transcript))
        XCTAssertTrue(prompt.contains("Claude Code"))
    }

    func testAHandoffWithNoTranscriptFailsRatherThanStartingBlind() async throws {
        let machine = try Machine(installed: ["claude", "codex"], history: [])

        let reply = await machine.invoke(
            .agentCommand,
            input: .object([
                "agent": .string("codex"),
                "session": .object([
                    "agent": .string("claude"),
                    "sessionID": .string("0199f0c1"),
                ]),
            ])
        )

        XCTAssertEqual(
            try failureCode(reply),
            "dev.tenon.core.agent-handoff-unresolved"
        )
    }

    func testASessionIdentifierThatCouldBeAnOptionIsRefused() async throws {
        let machine = try Machine(installed: ["claude"], history: [])

        let reply = await machine.invoke(
            .agentCommand,
            input: .object([
                "agent": .string("claude"),
                "session": .object([
                    "agent": .string("claude"),
                    "sessionID": .string("--dangerously-skip-permissions"),
                ]),
            ])
        )

        guard case let .failure(failure) = reply else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(failure.code, .kernel(.invalidInput))
    }
}

// MARK: - Harness

private extension AgentIntentProviderTests {
    /// One machine with exactly the agents and the shell history a test says it has, so the
    /// answers never depend on what the developer running the suite happens to have
    /// installed.
    @MainActor
    struct Machine {
        let binDirectory: URL
        let bindings: [IntentProviderBinding]

        init(installed: [String], history: [String]) throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agent-inventory-\(UUID().uuidString)")
            binDirectory = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                at: binDirectory,
                withIntermediateDirectories: true
            )
            for name in installed {
                let executable = binDirectory.appendingPathComponent(name)
                try "#!/bin/sh\n".write(
                    to: executable,
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path
                )
            }
            let historyFile = root.appendingPathComponent("history")
            try history.joined(separator: "\n").write(
                to: historyFile,
                atomically: true,
                encoding: .utf8
            )

            bindings = try AgentIntentProvider(
                detector: AgentLaunchDetector(
                    environment: [:],
                    homeDirectory: root,
                    executableDirectories: [binDirectory],
                    historyFileURLs: [historyFile]
                )
            ).bindings()
        }

        func invoke(
            _ name: CoreIntentName,
            input: IntentValue
        ) async -> IntentProviderReply {
            guard let intentID = try? name.intentID,
                  let binding = bindings.first(where: { $0.intentID == intentID })
            else {
                return .failure(
                    IntentProviderFailure(code: .kernel(.internal))
                )
            }
            let envelope = IntentEnvelope(
                requestID: UUID(),
                traceID: UUID(),
                parentRequestID: nil,
                name: intentID,
                input: input,
                caller: IntentPrincipal(
                    id: "test:agent-provider",
                    kind: .cli,
                    sessionRevision: 1
                ),
                scope: InvocationScope(),
                deadline: .now.advanced(by: .seconds(5)),
                target: nil,
                idempotencyKey: nil
            )
            let context = IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { _ in
                    .failure(
                        error: IntentError(
                            code: .kernel(.internal),
                            details: .null,
                            retryable: false,
                            retryAfterMilliseconds: nil,
                            outcome: .notStarted
                        ),
                        requestID: UUID(),
                        providerID: nil
                    )
                }
            )
            do {
                return try await binding.invoke(
                    envelope: envelope,
                    context: context
                )
            } catch {
                return .failure(IntentProviderFailure(code: .kernel(.internal)))
            }
        }
    }

    func successReply(_ reply: IntentProviderReply) throws -> IntentValue {
        guard case let .success(value) = reply else {
            XCTFail("expected success, got \(reply)")
            throw HarnessError.expectedSuccess
        }
        return value
    }

    func failureCode(_ reply: IntentProviderReply) throws -> String {
        guard case let .failure(failure) = reply else {
            XCTFail("expected failure, got \(reply)")
            throw HarnessError.expectedFailure
        }
        guard case let .domain(code) = failure.code else {
            XCTFail("expected a domain error, got \(failure.code)")
            throw HarnessError.expectedFailure
        }
        return code.rawValue
    }

    enum HarnessError: Error {
        case expectedSuccess
        case expectedFailure
    }
}
