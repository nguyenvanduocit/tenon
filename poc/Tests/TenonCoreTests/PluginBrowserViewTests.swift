import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// Browser chrome and surfaces are declarative view contributions. Navigation
/// behavior belongs to the browser plugin's intent-routed tests.
final class PluginBrowserViewTests: XCTestCase {
    func testBrowserNodesParseIntoTheNativeViewTree() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("pane", { title: "Browser" });
            tenon.views.set("pane", {
              body: {
                type: "vstack",
                children: [
                  {
                    type: "textfield",
                    value: "https://example.com",
                    placeholder: "Search or URL",
                    action: "go"
                  },
                  { type: "webview", surfaceID: "main" }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()

        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 8,
                children: [
                    .textfield(
                        value: "https://example.com",
                        placeholder: "Search or URL",
                        action: "go"
                    ),
                    .webview(surfaceID: "main"),
                ]
            )
        )
        XCTAssertTrue(snapshot.permissionViolations.isEmpty)
        _ = await runtime.shutdown()
    }

    func testTextfieldWithoutActionIsSkippedWithoutDestabilizingRuntime()
        async throws
    {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("pane", { title: "Browser" });
            tenon.views.set("pane", {
              body: {
                type: "textfield",
                value: "https://example.com",
                placeholder: "Search or URL"
              }
            });
            """
        )
        _ = try await runtime.start()

        let snapshot = await runtime.snapshot()
        XCTAssertNil(snapshot.views.first?.body)
        XCTAssertEqual(snapshot.phase, .active)
        XCTAssertTrue(snapshot.permissionViolations.isEmpty)
        _ = await runtime.shutdown()
    }

    private func makeRuntime(source: String) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-browser-view-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginManifest(
                    id: "dev.tenon.browser-view-tests",
                    name: "browser-view-tests",
                    version: "1"
                ),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                )
            )
        )
    }

    private static func unavailable() -> IntentResult {
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
