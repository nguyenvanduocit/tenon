import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

final class CoreCommandsPluginTests: XCTestCase {
    private static var pluginDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins/core-commands")
    }

    func testPaletteProjectionIsDeclaredByPluginOwnedContracts() throws {
        let manifest = try loadManifest()
        let titles = Set(
            manifest.intents.provides.compactMap { provision in
                provision.palette == nil ? nil : provision.title
            }
        )
        XCTAssertEqual(
            titles,
            [
                "New Tab",
                "New Terminal",
                "Split Right",
                "Split Down",
                "Close Pane",
                "Open Changes",
                "Open Automation",
                "Next Tab",
                "Previous Tab",
                "Focus Next Pane",
                "Switch Workspace…",
            ]
        )
        XCTAssertTrue(
            manifest.intents.provides.allSatisfy {
                $0.name.rawValue.hasPrefix(
                    manifest.id.rawValue + "."
                )
            }
        )
    }

    func testShippedProductKeysReceiveBindings() throws {
        let manifest = try loadManifest()
        let requests = manifest.intents.provides.compactMap {
            provision -> KeyBindingRequest? in
            guard let key = provision.palette?.key else {
                return nil
            }
            return KeyBindingRequest(
                target: KeyBindingTarget(
                    pluginID: manifest.id,
                    intentID: provision.name
                ),
                rawKey: key
            )
        }

        let index = KeyBindingIndex(
            requests: requests,
            reserved: KeyBindingIndex.shellReserved
        )
        let bindings = Dictionary(
            uniqueKeysWithValues: index.bindings.map {
                ($0.target.intentID.rawValue, $0.chord.display)
            }
        )

        XCTAssertEqual(
            bindings,
            [
                "dev.tenon.core-commands.tab.new.v1": "⌘T",
                "dev.tenon.core-commands.pane.split-right.v1": "⌘D",
                "dev.tenon.core-commands.pane.split-down.v1": "⇧⌘D",
                "dev.tenon.core-commands.pane.close.v2": "⌘W",
                "dev.tenon.core-commands.tab.next.v1": "⇧⌘]",
                "dev.tenon.core-commands.tab.previous.v1": "⇧⌘[",
                "dev.tenon.core-commands.pane.focus-next.v1": "⌘]",
            ]
        )
        XCTAssertEqual(index.diagnostics, [])
    }

    func testHandlersDelegateToCanonicalWorkspaceIntents() async throws {
        let runtime = try await makeRuntime()
        let started = try await runtime.start()
        let recorder = NestedRequestRecorder()

        for intent in [
            "dev.tenon.core-commands.tab.new.v1",
            "dev.tenon.core-commands.terminal.new.v1",
            "dev.tenon.core-commands.pane.split-right.v1",
            "dev.tenon.core-commands.pane.split-down.v1",
            "dev.tenon.core-commands.pane.close.v2",
            "dev.tenon.core-commands.changes.open.v1",
            "dev.tenon.core-commands.automation.open.v1",
            "dev.tenon.core-commands.tab.next.v1",
            "dev.tenon.core-commands.tab.previous.v1",
            "dev.tenon.core-commands.pane.focus-next.v1",
        ] {
            let intentID = try IntentID(intent)
            let binding = try XCTUnwrap(
                started.bindings.first { $0.intentID == intentID }
            )
            let envelope = makeEnvelope(intentID: intentID)
            let reply = try await binding.invoke(
                envelope: envelope,
                context: IntentProviderContext(
                    requestID: envelope.requestID,
                    nestedSend: { request in
                        await recorder.record(request)
                        return Self.success(.object([:]))
                    }
                )
            )
            XCTAssertEqual(reply, .success(.object([:])))
        }

        let recordedNames = await recorder.intentNames()
        XCTAssertEqual(
            recordedNames,
            [
                "workspace.tab.create.v1",
                "workspace.tab.create.v1",
                "workspace.pane.split.v1",
                "workspace.pane.split.v1",
                "workspace.pane.close.v2",
                "workspace.tab.create.v1",
                "workspace.tab.create.v1",
                "workspace.tab.next.v1",
                "workspace.tab.previous.v1",
                "workspace.pane.focus-next.v1",
            ]
        )
        let recordedRequests = await recorder.allRequests()
        XCTAssertEqual(
            recordedRequests[6].input,
            .object([
                "content": .object([
                    "kind": .string("automation"),
                ]),
            ])
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testSwitchWorkspaceReadsPicksAndSelects() async throws {
        let runtime = try await makeRuntime()
        let started = try await runtime.start()
        let intentID = try IntentID(
            "dev.tenon.core-commands.workspace.switch.v1"
        )
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == intentID }
        )
        let workspaceID = UUID()
        let recorder = NestedRequestRecorder(
            responses: [
                "workspace.state.v1": Self.success(
                    .object([
                        "nodes": .array([
                            .object([
                                "kind": .string("workspace"),
                                "id": .string(workspaceID.uuidString),
                                "name": .string("Tenon"),
                                "path": .string("/tmp/tenon"),
                            ]),
                        ]),
                    ])
                ),
                "ui.pick.v1": Self.success(
                    .object([
                        "selectedID": .string(
                            workspaceID.uuidString
                        ),
                    ])
                ),
                "workspace.select.v1": Self.success(.object([:])),
            ]
        )
        let envelope = makeEnvelope(intentID: intentID)

        let reply = try await binding.invoke(
            envelope: envelope,
            context: IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { request in
                    await recorder.response(for: request)
                }
            )
        )

        XCTAssertEqual(reply, .success(.object([:])))
        let recordedNames = await recorder.intentNames()
        XCTAssertEqual(
            recordedNames,
            [
                "workspace.state.v1",
                "ui.pick.v1",
                "workspace.select.v1",
            ]
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    private func loadManifest() throws -> PluginManifest {
        try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(
                contentsOf: Self.pluginDirectory
                    .appendingPathComponent("manifest.json")
            )
        )
    }

    private func makeRuntime() async throws -> any PluginHostRuntime {
        try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: loadManifest(),
                directory: Self.pluginDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.failure() },
                    list: { .array([]) }
                )
            )
        )
    }

    private func makeEnvelope(intentID: IntentID) -> IntentEnvelope {
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
            deadline: .now.advanced(by: .seconds(5)),
            target: nil,
            idempotencyKey: nil
        )
    }

    fileprivate static func success(_ value: IntentValue) -> IntentResult {
        .success(
            value: value,
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }

    private static func failure() -> IntentResult {
        .failure(
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
}

private actor NestedRequestRecorder {
    private var requests: [IntentProviderSendRequest] = []
    private let responses: [String: IntentResult]

    init(responses: [String: IntentResult] = [:]) {
        self.responses = responses
    }

    func record(_ request: IntentProviderSendRequest) {
        requests.append(request)
    }

    func response(
        for request: IntentProviderSendRequest
    ) -> IntentResult {
        requests.append(request)
        return responses[request.intentID.rawValue]
            ?? CoreCommandsPluginTests.success(.object([:]))
    }

    func intentNames() -> [String] {
        requests.map(\.intentID.rawValue)
    }

    func allRequests() -> [IntentProviderSendRequest] {
        requests
    }
}
