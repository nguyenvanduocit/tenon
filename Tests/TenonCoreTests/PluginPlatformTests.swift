import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginPlatformTests: XCTestCase {
    func testStatusAndEventsRemainSeparateContributionAndFactSurfaces() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.statusBar.set("ready");
            tenon.events.on("workspace.changed", function (event) {
              tenon.statusBar.set("tabs:" + event.tabs);
            });
            """
        )
        _ = try await runtime.start()
        var snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.statusBarText, "ready")
        let handlesWorkspaceChanges = await runtime.handles(
            event: "workspace.changed"
        )
        XCTAssertTrue(handlesWorkspaceChanges)

        try await runtime.emit(
            event: "workspace.changed",
            payload: .object(["tabs": .integer(3)])
        )
        let updated = await eventually {
            await runtime.snapshot().statusBarText == "tabs:3"
        }
        XCTAssertTrue(updated)
        snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.phase, .active)
        _ = await runtime.shutdown()
    }

    func testLogAndStorageCrossTheRuntimeAsOwnedValues() async throws {
        let sink = PlatformSink()
        let runtime = try makeRuntime(
            source: """
            tenon.log("boot", { ok: true });
            tenon.storage.set("state", { count: 2 });
            """,
            log: { line in await sink.log(line) },
            persistStorage: { key, value in
                await sink.persist(key: key, value: value)
            }
        )
        _ = try await runtime.start()
        let observed = await eventually {
            let lines = await sink.logLines()
            let value = await sink.value(for: "state")
            return lines.contains("[platform-tests] boot {\"ok\":true}")
                && value == .object(["count": .integer(2)])
        }
        XCTAssertTrue(observed)
        _ = await runtime.shutdown()
    }

    func testRuntimeShutdownDestroysThePinnedThread() async throws {
        let runtime = try makeRuntime(source: "")
        let started = try await runtime.start()
        let report = await runtime.shutdown()
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertEqual(
            report.createdThreadIdentifier,
            started.snapshot.runtimeThreadIdentifier
        )
        XCTAssertEqual(
            report.createdThreadIdentifier,
            report.destroyedThreadIdentifier
        )
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in },
        persistStorage: @escaping PluginRuntimeConfiguration.PersistStorage = {
            _, _ in
        }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-platform-\(UUID().uuidString)",
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
                    id: "dev.tenon.platform-tests",
                    name: "platform-tests",
                    version: "1"
                ),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                ),
                log: log,
                persistStorage: persistStorage
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

private actor PlatformSink {
    private var lines: [String] = []
    private var values: [String: IntentValue] = [:]

    func log(_ line: String) {
        lines.append(line)
    }

    func persist(key: String, value: IntentValue) {
        values[key] = value
    }

    func logLines() -> [String] {
        lines
    }

    func value(for key: String) -> IntentValue? {
        values[key]
    }
}
