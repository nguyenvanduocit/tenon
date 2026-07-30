import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginCapabilityTests: XCTestCase {
    func testProcessStreamRequiresDeclaredCapability() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.process.stream("/usr/bin/printf", ["denied"], {});
            tenon.process.stream("/usr/bin/printf", ["denied-again"], {});
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.permissionViolations,
            ["tenon.process.stream requires permission process.exec"]
        )
        let firstHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonProcessExit(1, 0)"
        )
        let secondHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonProcessExit(2, 0)"
        )
        XCTAssertEqual(firstHandlerRetired, .bool(false))
        XCTAssertEqual(secondHandlerRetired, .bool(false))
        _ = await runtime.shutdown()
    }

    func testFilesystemWatchRequiresDeclaredCapability() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.fs.watch("/tmp", function () {});
            tenon.fs.watch("/tmp", function () {});
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.permissionViolations,
            ["tenon.fs.watch requires permission filesystem.read"]
        )
        let firstHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonWatchPaths(1, [])"
        )
        let secondHandlerRetired = try await runtime.evaluateForTesting(
            "__tenonWatchPaths(2, [])"
        )
        XCTAssertEqual(firstHandlerRetired, .bool(false))
        XCTAssertEqual(secondHandlerRetired, .bool(false))
        _ = await runtime.shutdown()
    }

    func testDeclaredResourceCapabilitiesProduceNoViolation() async throws {
        let runtime = try makeRuntime(
            source: """
            var process = tenon.process.stream(
              "/usr/bin/printf",
              ["ok"],
              {}
            );
            process.cancel();
            var watch = tenon.fs.watch("/tmp", function () {});
            watch.cancel();
            """,
            permissions: ["process.exec", "filesystem.read"]
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.permissionViolations.isEmpty)
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        permissions: [String] = []
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-capabilities-\(UUID().uuidString)",
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
                    id: "dev.tenon.capability-tests",
                    name: "capability-tests",
                    version: "1",
                    permissions: permissions
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
