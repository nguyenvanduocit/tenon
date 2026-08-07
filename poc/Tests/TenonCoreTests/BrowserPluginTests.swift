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
        // The whole body is the web surface: navigation lives in the pane's ONE chrome
        // header now, so the ~36 points the old in-body bar cost went back to the page.
        XCTAssertEqual(view.body, .webview(surfaceID: "pane-a"))
        XCTAssertEqual(
            view.header.leading.map(\.id),
            ["back", "forward", "reload"],
            "the same three navigation ids, drawn by the host from a published value"
        )
        XCTAssertEqual(
            view.header.trailing,
            [
                .textfield(
                    id: "go",
                    value: "https://duckduckgo.com",
                    placeholder: "Search or enter website",
                    flex: true,
                    isEnabled: true,
                    accessibilityID: nil
                ),
            ]
        )

        // A field COMMITS rather than selects. The address arrives once, when the user says
        // so — which is the split that keeps a redirect landing mid-typing from being
        // indistinguishable from the address the user is still entering.
        let navigated = try await runtime.invokeViewSubmit(
            viewID: "browser",
            instanceID: "pane-a",
            itemID: "go",
            text: "example.com"
        )
        XCTAssertTrue(navigated)
        let navigationSettled = await eventually {
            await Self.address(of: runtime.snapshot().views.first) == "https://example.com"
        }
        XCTAssertTrue(navigationSettled)
        snapshot = await runtime.snapshot()
        guard let address = Self.address(of: snapshot.views.first) else {
            _ = await runtime.shutdown()
            return XCTFail("expected the address field in the pane's chrome header")
        }
        XCTAssertEqual(address, "https://example.com")

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

    /// An opener names where it wants to go before the pane it will go in exists. Without
    /// this the browser can only ever show its home page, so nothing outside it can hand
    /// it an address — the gap that keeps a chosen handler from being usable at all.
    func testAnOpenerCanNameTheAddressTheNewPaneLandsOn() async throws {
        let manifest = try loadManifest()
        let provision = try XCTUnwrap(
            manifest.intents.provides.first {
                $0.name.rawValue == "dev.tenon.browser.open.v1"
            }
        )
        // Optional, so the palette entry that supplies no input still opens the home page.
        XCTAssertNil(provision.inputSchema?.objectValue?["required"])

        let bridge = BrowserIntentBridge()
        let runtime = try makeRuntime(manifest: manifest, bridge: bridge)
        let started = try await runtime.start()
        let intentID = try IntentID("dev.tenon.browser.open.v1")
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == intentID }
        )

        let reply = try await binding.invoke(
            envelope: makeEnvelope(
                intentID: intentID,
                input: .object(["url": .string("https://tenon.dev/docs")])
            ),
            context: IntentProviderContext(
                requestID: UUID(),
                nestedSend: { request in await bridge.send(request) }
            )
        )
        XCTAssertEqual(reply, .success(.object([:])))

        try await runtime.openViewInstance(viewID: "browser", instanceID: "pane-a")

        let landed = await eventually {
            await bridge.topLevelRequests().contains {
                $0.intentID.rawValue == "browser.surface.load.v1"
                    && $0.input.objectValue?["url"]?.stringValue
                    == "https://tenon.dev/docs"
            }
        }
        XCTAssertTrue(landed, "the new pane never loaded the address it was opened for")

        guard let address = Self.address(of: await runtime.snapshot().views.first) else {
            _ = await runtime.shutdown()
            return XCTFail("expected the address field in the pane's chrome header")
        }
        XCTAssertEqual(address, "https://tenon.dev/docs")
        _ = await runtime.shutdown()
    }

    /// A refused open must not redirect the next one. The parked address is one-shot.
    func testARefusedOpenDoesNotRedirectTheNextPane() async throws {
        let bridge = BrowserIntentBridge(failNestedRequests: true)
        let runtime = try makeRuntime(manifest: try loadManifest(), bridge: bridge)
        let started = try await runtime.start()
        let intentID = try IntentID("dev.tenon.browser.open.v1")
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == intentID }
        )

        _ = try await binding.invoke(
            envelope: makeEnvelope(
                intentID: intentID,
                input: .object(["url": .string("https://tenon.dev/docs")])
            ),
            context: IntentProviderContext(
                requestID: UUID(),
                nestedSend: { request in await bridge.send(request) }
            )
        )

        try await runtime.openViewInstance(viewID: "browser", instanceID: "pane-a")

        let showedHome = await eventually {
            await Self.address(of: runtime.snapshot().views.first)
                == "https://duckduckgo.com"
        }
        XCTAssertTrue(showedHome, "a refused open leaked its address into the next pane")
        _ = await runtime.shutdown()
    }

    /// The address this pane is showing, read off the `go` field the browser publishes into
    /// its pane's chrome header. Looked up by id rather than by position, because where in
    /// the strip the host ends up drawing it is the host's business.
    private static func address(of view: PluginViewInfo?) -> String? {
        guard case let .textfield(_, value, _, _, _, _) = view?.header.item(id: "go") else {
            return nil
        }
        return value
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

    private func makeEnvelope(
        intentID: IntentID,
        input: IntentValue = .object([:])
    ) -> IntentEnvelope {
        IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
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
    private let failNestedRequests: Bool

    init(failNestedRequests: Bool = false) {
        self.failNestedRequests = failNestedRequests
    }

    func send(_ request: PluginIntentSendRequest) -> IntentResult {
        topLevel.append(request)
        return success()
    }

    func send(_ request: IntentProviderSendRequest) -> IntentResult {
        nested.append(request)
        return failNestedRequests ? refusal() : success()
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

    private func refusal() -> IntentResult {
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
