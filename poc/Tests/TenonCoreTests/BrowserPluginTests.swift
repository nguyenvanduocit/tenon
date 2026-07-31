import Foundation
@testable import TenonIntentCore
import XCTest
@testable import TenonCore

final class BrowserPluginTests: XCTestCase {
    private static var pluginDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins/browser")
    }

    func testOwnedPaletteIntentOpensTheBrowserViewThroughWorkspaceIntent()
        async throws
    {
        let manifest = try loadManifest()
        let provision = try XCTUnwrap(
            manifest.intents.provides.first {
                $0.name.rawValue == "dev.tenon.browser.open.v1"
            }
        )
        XCTAssertEqual(provision.title, "Open Browser")
        XCTAssertNotNil(provision.palette)

        let bridge = BrowserIntentBridge()
        let runtime = try makeRuntime(manifest: manifest, bridge: bridge)
        let started = try await runtime.start()
        let intentID = try IntentID("dev.tenon.browser.open.v1")
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == intentID }
        )
        let envelope = makeEnvelope(intentID: intentID)

        let reply = try await binding.invoke(
            envelope: envelope,
            context: IntentProviderContext(
                requestID: envelope.requestID,
                nestedSend: { request in
                    await bridge.send(request)
                }
            )
        )

        XCTAssertEqual(reply, .success(.object([:])))
        let requests = await bridge.nestedRequests()
        // T-039: the opener asks for content, not for a tab. Placement is host policy —
        // `workspace.content.open.v1` reuses a pane already showing this kind of content
        // and otherwise splits, and never opens a tab. A plugin naming `tab.create` here
        // would be deciding layout it has no business deciding.
        XCTAssertEqual(requests.map(\.intentID.rawValue), [
            "workspace.content.open.v1",
        ])
        XCTAssertEqual(
            requests.first?.input,
            .object([
                "content": .object([
                    "kind": .string("plugin"),
                    "pluginID": .string("dev.tenon.browser"),
                    "viewID": .string("browser"),
                ]),
            ])
        )
        _ = await runtime.shutdown()
    }

    func testBrowserInstanceRendersAndRoutesNavigationThroughSurfaceIntents()
        async throws
    {
        let bridge = BrowserIntentBridge()
        let runtime = try makeRuntime(
            manifest: loadManifest(),
            bridge: bridge
        )
        _ = try await runtime.start()

        try await runtime.openViewInstance(
            viewID: "browser",
            instanceID: "pane-a"
        )
        var snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(view.instanceID, "pane-a")
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 0,
                children: [
                    .browserBar(
                        url: "https://duckduckgo.com",
                        placeholder: "Search or enter website"
                    ),
                    .webview(surfaceID: "pane-a"),
                ]
            )
        )

        let navigated = try await runtime.invokeViewSelect(
            viewID: "browser",
            instanceID: "pane-a",
            itemID: "go",
            value: .string("example.com")
        )
        XCTAssertTrue(navigated)
        let navigationSettled = await eventually {
            guard case let .vstack(_, children) = await runtime.snapshot()
                .views.first?.body,
                case let .browserBar(url, _) = children.first
            else {
                return false
            }
            return url == "https://example.com"
        }
        XCTAssertTrue(navigationSettled)
        snapshot = await runtime.snapshot()
        guard case let .vstack(_, children) = snapshot.views.first?.body,
              case let .browserBar(url, _) = children.first
        else {
            _ = await runtime.shutdown()
            return XCTFail("expected browser bar after navigation")
        }
        XCTAssertEqual(url, "https://example.com")

        for action in ["back", "forward", "reload"] {
            let invoked = try await runtime.invokeViewSelect(
                viewID: "browser",
                instanceID: "pane-a",
                itemID: action
            )
            XCTAssertTrue(invoked)
        }

        let navigationRequestsSettled = await eventually {
            await bridge.topLevelRequests().map(\.intentID.rawValue) == [
                "browser.surface.load.v1",
                "browser.surface.load.v1",
                "browser.surface.back.v1",
                "browser.surface.forward.v1",
                "browser.surface.reload.v1",
            ]
        }
        XCTAssertTrue(navigationRequestsSettled)
        let requests = await bridge.topLevelRequests()
        XCTAssertEqual(
            requests.map(\.intentID.rawValue),
            [
                "browser.surface.load.v1",
                "browser.surface.load.v1",
                "browser.surface.back.v1",
                "browser.surface.forward.v1",
                "browser.surface.reload.v1",
            ]
        )
        XCTAssertTrue(
            requests.allSatisfy {
                $0.input.objectValue?["surfaceID"]?.stringValue == "pane-a"
            }
        )
        _ = await runtime.shutdown()
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

    private func makeRuntime(
        manifest: PluginManifest,
        bridge: BrowserIntentBridge
    ) throws -> PluginRuntime {
        try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: Self.pluginDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { request in await bridge.send(request) },
                    list: { .array([]) }
                ),
                local: PluginRuntimeLocalState(
                    settings: [
                        "homeURL": .string("https://duckduckgo.com"),
                        "searchEngine": .string(
                            "https://duckduckgo.com/?q="
                        ),
                    ]
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
                kind: .palette,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: .now.advanced(by: .seconds(5)),
            target: nil,
            idempotencyKey: nil
        )
    }

    private func eventually(
        attempts: Int = 200,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor BrowserIntentBridge {
    private var topLevel: [PluginIntentSendRequest] = []
    private var nested: [IntentProviderSendRequest] = []

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        topLevel.append(request)
        return success()
    }

    func send(_ request: IntentProviderSendRequest) -> IntentResult {
        nested.append(request)
        return success()
    }

    func topLevelRequests() -> [PluginIntentSendRequest] {
        topLevel
    }

    func nestedRequests() -> [IntentProviderSendRequest] {
        nested
    }

    private func success() -> IntentResult {
        .success(
            value: .object([:]),
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.tests")
        )
    }
}
