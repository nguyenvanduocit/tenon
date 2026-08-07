import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginViewInstanceTests: XCTestCase {
    func testInstancedViewsOwnIndependentBodiesAndLifecycle() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("web", { title: "Web", instanced: true });
            tenon.views.onOpen("web", function (instanceID) {
              tenon.views.set("web", {
                body: { type: "text", value: "page " + instanceID }
              }, instanceID);
            });
            tenon.views.onClose("web", function (instanceID) {
              tenon.log("closed:" + instanceID);
            });
            """
        )
        _ = try await runtime.start()
        let initialSnapshot = await runtime.snapshot()
        XCTAssertTrue(initialSnapshot.views.isEmpty)

        try await runtime.openViewInstance(
            viewID: "web",
            instanceID: "pane-a"
        )
        try await runtime.openViewInstance(
            viewID: "web",
            instanceID: "pane-b"
        )
        var snapshot = await runtime.snapshot()
        XCTAssertEqual(
            Set(snapshot.views.compactMap(\.instanceID)),
            ["pane-a", "pane-b"]
        )
        XCTAssertEqual(
            Set(snapshot.views.compactMap { view -> String? in
                guard case let .text(value, _, _, _) = view.body else {
                    return nil
                }
                return value
            }),
            ["page pane-a", "page pane-b"]
        )

        try await runtime.closeViewInstance(
            viewID: "web",
            instanceID: "pane-a"
        )
        snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.views.compactMap(\.instanceID), ["pane-b"])
        _ = await runtime.shutdown()
    }

    func testViewCallbacksReceiveOwningInstanceID() async throws {
        let logs = InstanceLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("web", { title: "Web", instanced: true });
            tenon.views.onOpen("web", function (instanceID) {
              tenon.views.set("web", {
                body: {
                  type: "button",
                  label: "Go",
                  action: "go"
                }
              }, instanceID);
            });
            tenon.views.onSelect("web", function (action, value, instanceID) {
              tenon.log(action + ":" + instanceID);
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()
        try await runtime.openViewInstance(
            viewID: "web",
            instanceID: "pane-a"
        )
        let invoked = try await runtime.invokeViewSelect(
            viewID: "web",
            instanceID: "pane-a",
            itemID: "go"
        )
        XCTAssertTrue(invoked)
        let delivered = await eventually {
            let values = await logs.values()
            return values.contains("[view-instance-tests] go:pane-a")
        }
        XCTAssertTrue(delivered)
        _ = await runtime.shutdown()
    }

    func testSingletonViewPublishesWithoutAnInstance() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: { type: "text", value: "singleton" }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertNil(view.instanceID)
        XCTAssertFalse(view.instanced)
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-view-instance-\(UUID().uuidString)",
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
                    id: "dev.tenon.view-instance-tests",
                    name: "view-instance-tests",
                    version: "1"
                ),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                ),
                log: log
            )
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

private actor InstanceLogSink {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func values() -> [String] {
        lines
    }
}
