import Foundation
import XCTest
@testable import TenonCore
@testable import TenonIntentCore

/// T-048: `tenon.agents.run` — the platform `agent()` for AI-authored automations.
///
/// Classification: JavaScript composition over the INTENT adapter, running in the
/// caller's generation under the caller's principal. These tests pin the composition
/// rules against a scripted bridge: open → wait (scoped to the opened pane, retried
/// until met, deadline-bounded) → scrollback paged read (scoped, cursor-chained,
/// one restart on invalidation), plus the shell-quoting rule that keeps a prompt
/// from becoming shell injection into the user's PTY.
final class AgentsRunTests: XCTestCase {
    private static let paneID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    func testRunComposesOpenWaitAndPagedReadInOrderWithScope() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [(try Self.waitSuccess(met: true), 0)])
        await bridge.script("terminal.scrollback.read.v1", [
            (try Self.page(text: "A", cursor: "1:2"), 0),
            (try Self.page(text: "B", cursor: nil), 0),
        ])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude", arguments: ["-p", "hi"] }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, true)
        let value = try XCTUnwrap(result["value"] as? [String: Any])
        XCTAssertEqual(value["paneID"] as? String, Self.paneID)
        XCTAssertEqual(value["transcript"] as? String, "AB")

        let recorded = await bridge.recorded
        XCTAssertEqual(
            recorded.map(\.intentID),
            [
                "terminal.open.v1",
                "terminal.wait.v1",
                "terminal.write.v1",
                "terminal.scrollback.read.v1",
                "terminal.scrollback.read.v1",
            ],
            "the wait must be armed BEFORE the command is sent — the wait snapshots its "
                + "completion baseline when issued, so a command sent first can finish in "
                + "the gap and never be seen"
        )
        XCTAssertNil(
            recorded[0].paneScope,
            "open creates the pane; it cannot be scoped to one"
        )
        XCTAssertEqual(recorded[1].paneScope, Self.paneID)
        XCTAssertEqual(recorded[2].paneScope, Self.paneID)
        XCTAssertEqual(recorded[3].paneScope, Self.paneID)
        XCTAssertEqual(recorded[4].paneScope, Self.paneID)
        XCTAssertNil(
            recorded[0].input.objectValue?["command"],
            "the pane opens empty; the command follows the armed wait"
        )
        XCTAssertEqual(
            recorded[3].input.objectValue?.keys.contains("cursor"),
            false,
            "the first page starts without a cursor"
        )
        XCTAssertEqual(
            recorded[4].input.objectValue?["cursor"]?.stringValue,
            "1:2",
            "the second page continues the returned cursor"
        )
        XCTAssertEqual(
            recorded[1].input.objectValue?["condition"]?.stringValue,
            "command-finished"
        )
    }

    func testRunQuotesEveryArgumentForTheShell() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [(try Self.waitSuccess(met: true), 0)])
        await bridge.script("terminal.scrollback.read.v1", [
            (try Self.page(text: "", cursor: nil), 0),
        ])

        _ = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude", arguments: ["-p", "it's; $(rm -rf /) `x`"] }"#
        )

        let recorded = await bridge.recorded
        let written = try XCTUnwrap(
            recorded.first { $0.intentID == "terminal.write.v1" }
        )
        XCTAssertEqual(
            written.input.objectValue?["text"]?.stringValue,
            "'claude' '-p' 'it'\\''s; $(rm -rf /) `x`'\n",
            "every argument must be single-quoted with embedded quotes escaped"
        )
    }

    func testRunRetriesWaitUntilMet() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [
            (try Self.waitSuccess(met: false), 0),
            (try Self.waitSuccess(met: false), 0),
            (try Self.waitSuccess(met: true), 0),
        ])
        await bridge.script("terminal.scrollback.read.v1", [
            (try Self.page(text: "done", cursor: nil), 0),
        ])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude" }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, true)
        let waits = await bridge.recorded.filter {
            $0.intentID == "terminal.wait.v1"
        }
        XCTAssertEqual(waits.count, 3, "an unmet wait re-arms until the condition is met")
    }

    func testRunTimesOutWhenTheDeadlinePasses() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        // Every wait answers "not yet" after 30 ms; a 50 ms budget starves.
        await bridge.script("terminal.wait.v1", [
            (try Self.waitSuccess(met: false), 30),
            (try Self.waitSuccess(met: false), 30),
            (try Self.waitSuccess(met: false), 30),
        ])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude", timeoutMs: 50 }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, false)
        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "dev.tenon.agents.timeout")
        XCTAssertEqual(result["paneID"] as? String, Self.paneID)
        let reads = await bridge.recorded.filter {
            $0.intentID == "terminal.scrollback.read.v1"
        }
        XCTAssertTrue(reads.isEmpty, "a timed-out run must not read a transcript")
    }

    func testRunRestartsThePageWalkOnceWhenInvalidated() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [(try Self.waitSuccess(met: true), 0)])
        await bridge.script("terminal.scrollback.read.v1", [
            (try Self.page(text: "STALE", cursor: "1:9", invalidated: true), 0),
            (try Self.page(text: "fresh", cursor: nil), 0),
        ])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude" }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, true)
        let value = try XCTUnwrap(result["value"] as? [String: Any])
        XCTAssertEqual(
            value["transcript"] as? String,
            "fresh",
            "an invalidated walk restarts clean; stale pages must not leak into the transcript"
        )
        let reads = await bridge.recorded.filter {
            $0.intentID == "terminal.scrollback.read.v1"
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(
            reads.last?.input.objectValue?.keys.contains("cursor"),
            false,
            "the restart begins again without a cursor"
        )
    }

    func testRunFailsClosedWhenTheWalkInvalidatesTwice() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [(try Self.waitSuccess(met: true), 0)])
        await bridge.script("terminal.scrollback.read.v1", [
            (try Self.page(text: "", cursor: nil, invalidated: true), 0),
            (try Self.page(text: "", cursor: nil, invalidated: true), 0),
        ])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude" }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, false)
        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(
            error["code"] as? String,
            "dev.tenon.agents.scrollback-unstable"
        )
    }

    func testRunFailsClosedWhenOpenIsRefused() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(Self.refusal(), 0)])

        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude" }"#
        )

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNotNil(result["error"])
        let after = await bridge.recorded.dropFirst()
        XCTAssertTrue(
            after.isEmpty,
            "a refused open must stop the composition; nothing may wait or read"
        )
    }

    func testRunRejectsAMalformedRequestWithASuggestion() async throws {
        let bridge = ScriptedIntentBridge()
        let result = try await runFixture(
            bridge: bridge,
            request: #"{ arguments: ["-p"] }"#
        )
        let thrown = try XCTUnwrap(result["threw"] as? String)
        XCTAssertTrue(
            thrown.contains("command"),
            "the error must name the missing field: \(thrown)"
        )
        let recorded = await bridge.recorded
        XCTAssertTrue(recorded.isEmpty)
    }

    func testAgentsRunRejectsANonSenderArgument() async throws {
        let bridge = ScriptedIntentBridge()
        let result = try await runFixture(
            bridge: bridge,
            request: #"{ command: "claude" }"#,
            sender: "null"
        )
        let thrown = try XCTUnwrap(result["threw"] as? String)
        XCTAssertTrue(
            thrown.contains("sender"),
            "the error must name the sender argument: \(thrown)"
        )
        let recorded = await bridge.recorded
        XCTAssertTrue(
            recorded.isEmpty,
            "a malformed sender must stop the composition before it opens a pane"
        )
    }

    /// The sender is opt-in, and it MUST stay opt-in: `agents.run` called with no sender
    /// starts a root plugin request under the ambient scope, on its own 600s budget
    /// rather than the invoking intent's deadline. Green before and after the sender
    /// parameter existed — this fence is what keeps the default from flipping silently.
    func testAgentsRunWithoutASenderStillUsesTheTopLevelBridge() async throws {
        let bridge = ScriptedIntentBridge()
        await bridge.script("terminal.open.v1", [(try Self.openSuccess(), 0)])
        await bridge.script("terminal.wait.v1", [(try Self.waitSuccess(met: true), 0)])
        await bridge.script(
            "terminal.scrollback.read.v1",
            [(try Self.page(text: "x", cursor: nil), 0)]
        )
        let intentID = try IntentID("dev.tenon.agents-tests.run.v1")
        let runtime = try makeRuntime(
            bridge: bridge,
            provides: [intentID],
            source: """
            tenon.intents.handle(
              "\(intentID.rawValue)",
              async function (input, call) {
                await tenon.agents.run(
                  { command: "echo", arguments: ["x"], timeoutMs: 6000 }
                );
                return {};
              }
            );
            """
        )
        let started = try await runtime.start()
        let binding = try XCTUnwrap(started.bindings.first { $0.intentID == intentID })
        let recorder = NestedSendRecorder(responses: [:])
        let envelope = makeProviderEnvelope(intentID: intentID)
        let reply = try await binding.invoke(
            envelope: envelope,
            context: IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { request in await recorder.response(for: request) }
            )
        )
        _ = await runtime.shutdown()

        let topLevel = await bridge.recorded.map(\.intentID)
        let nested = await recorder.intentNames()

        XCTAssertEqual(reply, .success(.object([:])))
        // `agents.run` starts the wait WITHOUT awaiting it and only then writes the command,
        // so the wait's baseline precedes the run — see PluginRuntimeBootstrap's
        // "Opening with the command loses every short run". Those two sends are concurrent
        // by design, and which of them reaches the bridge first is a scheduling accident.
        // Assert the rule this test is named for — every send took the top-level path — plus
        // the two orderings the composition really does guarantee.
        XCTAssertEqual(
            Set(topLevel),
            [
                "terminal.open.v1",
                "terminal.wait.v1",
                "terminal.write.v1",
                "terminal.scrollback.read.v1",
            ],
            "omitting the sender must keep the run on the top-level intent path"
        )
        XCTAssertEqual(topLevel.count, 4, "each composed intent is sent exactly once")
        XCTAssertEqual(
            topLevel.first,
            "terminal.open.v1",
            "the pane must exist before anything is scoped to it"
        )
        XCTAssertEqual(
            topLevel.last,
            "terminal.scrollback.read.v1",
            "the transcript is read only after the run has settled"
        )
        XCTAssertEqual(
            nested,
            [],
            "nothing may reach the invoking call's nested channel when no sender is given"
        )
    }

    /// Passing the invoking `call` into `agents.run` is what buys the invocation's
    /// workspace/pane targeting, the parent deadline, causal parentage, and cancellation
    /// linkage — none of which an options bag can carry.
    func testAgentsRunUsesTheProvidingCallWhenGivenIt() async throws {
        let bridge = ScriptedIntentBridge()
        let intentID = try IntentID("dev.tenon.agents-tests.run.v1")
        let runtime = try makeRuntime(
            bridge: bridge,
            provides: [intentID],
            source: """
            tenon.intents.handle(
              "\(intentID.rawValue)",
              async function (input, call) {
                await tenon.agents.run(
                  { command: "echo", arguments: ["x"], timeoutMs: 6000 },
                  call
                );
                return {};
              }
            );
            """
        )
        let started = try await runtime.start()
        let binding = try XCTUnwrap(started.bindings.first { $0.intentID == intentID })
        let recorder = NestedSendRecorder(responses: [
            "terminal.open.v1": try Self.openSuccess(),
            "terminal.wait.v1": try Self.waitSuccess(met: true),
            "terminal.write.v1": .success(
                value: .object([:]),
                requestID: UUID(),
                providerID: try ProviderID("dev.tenon.core")
            ),
            "terminal.scrollback.read.v1": try Self.page(text: "x", cursor: nil),
        ])
        let envelope = makeProviderEnvelope(intentID: intentID)
        let reply = try await binding.invoke(
            envelope: envelope,
            context: IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { request in await recorder.response(for: request) }
            )
        )
        _ = await runtime.shutdown()

        let nested = await recorder.intentNames()
        let scopes = await recorder.paneScopes()
        let topLevel = await bridge.recorded.map(\.intentID)

        XCTAssertEqual(reply, .success(.object([:])))
        // The run's shape is asserted at the two ends, where the order is a guarantee, and as a
        // set in the middle, where it is not.
        //
        // `agents.run` starts `terminal.wait.v1` WITHOUT awaiting it and only then writes the
        // command, deliberately: a wait armed after the command runs loses every short run
        // (PluginRuntimeBootstrap.swift:553-565). So the two are in flight together, and which
        // one crosses into this recorder's actor first is a scheduling detail — CI observed
        // write before wait on 2026-08-11 (run 31531099048) having observed wait before write
        // the run before, on the same tree. Asserting the arrival order here asserts the test
        // double's scheduling, not the code: the double is called directly through `nestedSend`
        // and never passes the per-pane lane that orders these for real.
        XCTAssertEqual(nested.first, "terminal.open.v1", "the run has to open a pane first")
        XCTAssertEqual(
            nested.last,
            "terminal.scrollback.read.v1",
            "the transcript is read last, after the wait has settled"
        )
        XCTAssertEqual(
            Set(nested.dropFirst().dropLast()),
            ["terminal.wait.v1", "terminal.write.v1"],
            "every step of the run must ride the invoking call's nested channel"
        )
        XCTAssertEqual(
            scopes,
            [nil, Self.paneID, Self.paneID, Self.paneID],
            "open creates the pane; every step after it is scoped to that pane"
        )
        XCTAssertTrue(
            topLevel.isEmpty,
            "a run given a sender must send nothing as a root plugin request"
        )
    }

    // MARK: - Fixture

    /// Evaluates one `tenon.agents.run` call in a real runtime against the scripted
    /// bridge and decodes the JSON the fixture publishes through its status bar.
    private func runFixture(
        bridge: ScriptedIntentBridge,
        request: String,
        sender: String? = nil
    ) async throws -> [String: Any] {
        let arguments = sender.map { "\(request), \($0)" } ?? request
        let runtime = try makeRuntime(
            bridge: bridge,
            source: """
            (async function () {
              try {
                var result = await tenon.agents.run(\(arguments));
                tenon.statusBar.set(JSON.stringify(result));
              } catch (error) {
                tenon.statusBar.set(JSON.stringify({ threw: error.message }));
              }
            })();
            """
        )
        _ = try await runtime.start()
        var text: String?
        for _ in 0 ..< 800 {
            text = await runtime.snapshot().statusBarText
            if text != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await runtime.shutdown()
        let payload = try XCTUnwrap(text, "the fixture never published a result")
        let object = try JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        )
        return try XCTUnwrap(object as? [String: Any])
    }

    /// An envelope for invoking a fixture's own provider binding directly. The suite
    /// cannot borrow `CoreCommandsPluginTests`' equivalent — that one is fileprivate.
    private func makeProviderEnvelope(intentID: IntentID) -> IntentEnvelope {
        IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: .object([:]),
            caller: IntentPrincipal(
                id: "tests",
                kind: .user,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: .now.advanced(by: .seconds(30)),
            target: nil,
            idempotencyKey: nil
        )
    }

    private func makeRuntime(
        bridge: ScriptedIntentBridge,
        provides: [IntentID] = [],
        source: String
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-agents-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = try PluginManifest(
            id: "dev.tenon.agents-tests",
            name: "agents-tests",
            version: "1",
            intents: PluginIntentManifest(
                provides: provides.map { PluginIntentProvision(name: $0) }
            )
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.handle(request) },
                    list: { .array([]) }
                )
            )
        )
    }

    // MARK: - Canned results

    private static func openSuccess() throws -> IntentResult {
        .success(
            value: .object(["paneID": .string(paneID)]),
            requestID: UUID(),
            providerID: try ProviderID("dev.tenon.core")
        )
    }

    private static func waitSuccess(met: Bool) throws -> IntentResult {
        .success(
            value: .object([
                "paneID": .string(paneID),
                "condition": .string("command-finished"),
                "met": .bool(met),
            ]),
            requestID: UUID(),
            providerID: try ProviderID("dev.tenon.core")
        )
    }

    private static func page(
        text: String,
        cursor: String?,
        invalidated: Bool = false
    ) throws -> IntentResult {
        var value: [String: IntentValue] = [
            "paneID": .string(paneID),
            "text": .string(text),
            "totalRows": .integer(2),
            "invalidated": .bool(invalidated),
        ]
        if let cursor {
            value["cursor"] = .string(cursor)
        } else {
            value["cursor"] = .null
        }
        return .success(
            value: .object(value),
            requestID: UUID(),
            providerID: try ProviderID("dev.tenon.core")
        )
    }

    private static func refusal() -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.denied),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: nil
        )
    }
}

/// The nested channel of one provider invocation: records every request and answers it
/// from a keyed table. It MUST answer — an unanswered nested send leaves `agents.run`
/// awaiting forever and hangs the whole suite.
private actor NestedSendRecorder {
    private var requests: [IntentProviderSendRequest] = []
    private let responses: [String: IntentResult]

    init(responses: [String: IntentResult]) {
        self.responses = responses
    }

    func response(for request: IntentProviderSendRequest) -> IntentResult {
        requests.append(request)
        return responses[request.intentID.rawValue]
            ?? .failure(
                error: IntentError(
                    code: .kernel(.providerUnavailable),
                    details: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    outcome: .notStarted
                ),
                requestID: UUID(),
                providerID: nil
            )
    }

    func intentNames() -> [String] {
        requests.map(\.intentID.rawValue)
    }

    func paneScopes() -> [String?] {
        requests.map { $0.scopeOverride?.paneID?.uuidString }
    }
}

/// Captures every send and answers from per-intent queues, with optional delays.
actor ScriptedIntentBridge {
    struct Recorded: Sendable {
        let intentID: String
        let input: IntentValue
        let paneScope: String?
    }

    private(set) var recorded: [Recorded] = []
    private var queues: [String: [(IntentResult, Int)]] = [:]

    func script(_ intentID: String, _ responses: [(IntentResult, Int)]) {
        queues[intentID, default: []].append(contentsOf: responses)
    }

    func handle(_ request: PluginIntentSendRequest) async -> IntentResult {
        recorded.append(
            Recorded(
                intentID: request.intentID.rawValue,
                input: request.input,
                paneScope: request.scopeOverride?.paneID?.uuidString
            )
        )
        // The command is delivered with `terminal.write.v1` after the wait is armed, so
        // every composition reaches it. It is plumbing rather than a rule these tests pin,
        // so it succeeds unless a test scripts it deliberately — that keeps each test
        // scripting only the step it is about.
        if request.intentID.rawValue == "terminal.write.v1",
           queues["terminal.write.v1"]?.isEmpty ?? true
        {
            return .success(
                value: .object([:]),
                requestID: UUID(),
                providerID: (try? ProviderID("dev.tenon.core"))!
            )
        }
        guard var queue = queues[request.intentID.rawValue],
              !queue.isEmpty
        else {
            return .failure(
                error: IntentError(
                    code: .kernel(.providerUnavailable),
                    details: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    outcome: .notStarted
                ),
                requestID: UUID(),
                providerID: nil
            )
        }
        let (result, delayMilliseconds) = queue.removeFirst()
        queues[request.intentID.rawValue] = queue
        if delayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        return result
    }
}
