import Foundation
import SwiftUI
@testable import TenonApp
import XCTest

final class AgentLensDecoderTests: XCTestCase {
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
        XCTAssertTrue(reducer.snapshot.earlierHistoryAvailable)
        XCTAssertEqual(reducer.snapshot.diagnostics.count, 40)
        XCTAssertLessThanOrEqual(reducer.snapshot.activities.count, 500)
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

        model.mode = .conversation
        model.mode = .activity
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

    func testLiveProcessTranscriptPipelineAutoSwitchesAndRoutesGuardedInput() async throws {
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
        let discovery = AgentLensDiscovery(homeDirectory: home)
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
        XCTAssertEqual(model.mode, .conversation)
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
