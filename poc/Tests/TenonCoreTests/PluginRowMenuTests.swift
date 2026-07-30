import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginRowMenuTests: XCTestCase {
    func testRowMenuMetadataAndSelectionRoundTrip() async throws {
        let logs = RowMenuLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("tree", { title: "Tree" });
            tenon.views.set("tree", {
              items: [{
                id: "/a",
                label: "a",
                menu: [
                  { id: "open", label: "Open" },
                  {
                    id: "trash",
                    label: "Move to Trash",
                    destructive: true,
                    separatorBefore: true
                  }
                ]
              }]
            });
            tenon.views.onSelect("tree", function (item, action) {
              tenon.log(item + ":" + action);
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()

        let snapshot = await runtime.snapshot()
        let row = try XCTUnwrap(snapshot.views.first?.items.first)
        XCTAssertEqual(row.menu.map(\.id), ["open", "trash"])
        XCTAssertTrue(row.menu[1].destructive)
        XCTAssertTrue(row.menu[1].separatorBefore)

        let invoked = try await runtime.invokeViewSelect(
            viewID: "tree",
            itemID: "/a",
            value: .string("trash")
        )
        XCTAssertTrue(invoked)
        let delivered = await eventually {
            let values = await logs.values()
            return values.contains("[row-menu-tests] /a:trash")
        }
        XCTAssertTrue(delivered)
        _ = await runtime.shutdown()
    }

    func testRowsWithoutMenusStayEmpty() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("tree", { title: "Tree" });
            tenon.views.set("tree", {
              items: [{ id: "/a", label: "a" }]
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.views.first?.items.first?.menu, [])
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-row-menu-\(UUID().uuidString)",
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
                    id: "dev.tenon.row-menu-tests",
                    name: "row-menu-tests",
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

private actor RowMenuLogSink {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func values() -> [String] {
        lines
    }
}
