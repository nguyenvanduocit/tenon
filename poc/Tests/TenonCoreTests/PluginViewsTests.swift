import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginViewsTests: XCTestCase {
    func testDeclarativeBodyParsesIntoNativeViewTree() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              title: "Panel",
              subtitle: "native",
              actions: [{ id: "refresh", icon: "arrow.clockwise" }],
              body: {
                type: "vstack",
                spacing: 8,
                children: [
                  { type: "text", value: "Build passing", weight: "semibold" },
                  { type: "badge", value: "main", tint: "green" },
                  { type: "progress", value: 0.42, tint: "amber" }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(view.title, "Panel")
        XCTAssertEqual(view.subtitle, "native")
        XCTAssertEqual(view.actions.map(\.id), ["refresh"])
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 8,
                children: [
                    .text(
                        "Build passing",
                        style: .body,
                        weight: .semibold,
                        color: .default
                    ),
                    .badge("main", tint: .green),
                    .progress(value: 0.42, tint: .amber),
                ]
            )
        )
        _ = await runtime.shutdown()
    }

    func testStructuredAndStringActionsRoundTripToHandler() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "vstack",
                children: [
                  {
                    type: "button",
                    label: "Stage",
                    action: { operation: "stage", path: "a.swift" }
                  },
                  { type: "button", label: "Refresh", action: "refresh" }
                ]
              }
            });
            tenon.views.onSelect("panel", function (action) {
              tenon.log(typeof action === "string"
                ? action
                : action.operation + ":" + action.path);
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()

        let snapshot = await runtime.snapshot()
        guard case let .vstack(_, children) = try XCTUnwrap(
            snapshot.views.first?.body
        ),
            case let .button(_, structuredAction, _) = children[0],
            case let .button(_, stringAction, _) = children[1]
        else {
            return XCTFail("expected two parsed buttons")
        }
        let structured = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: structuredAction
        )
        let string = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: stringAction
        )
        XCTAssertTrue(structured)
        XCTAssertTrue(string)
        let delivered = await eventually {
            let lines = await logs.values()
            return lines.contains("[view-tests] stage:a.swift")
                && lines.contains("[view-tests] refresh")
        }
        XCTAssertTrue(delivered)
        _ = await runtime.shutdown()
    }

    func testProgressValuesAreClampedAtParsingBoundary() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "vstack",
                children: [
                  { type: "progress", value: -2 },
                  { type: "progress", value: 5 }
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
                    .progress(value: 0, tint: .default),
                    .progress(value: 1, tint: .default),
                ]
            )
        )
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-views-\(UUID().uuidString)",
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
                    id: "dev.tenon.view-tests",
                    name: "view-tests",
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

private actor ViewLogSink {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func values() -> [String] {
        lines
    }
}
