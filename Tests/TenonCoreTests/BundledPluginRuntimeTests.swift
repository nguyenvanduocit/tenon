import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
import TenonIntentCore
import XCTest

final class BundledPluginRuntimeTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    func testNativeManifestLoadsWithoutJavaScriptEntrypoint() throws {
        let directory = Self.pluginsRoot.appendingPathComponent("clock")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("main.js").path
            )
        )
        let manifest = try PluginLoader.loadManifest(at: directory)
        XCTAssertEqual(manifest.runtime, .bundledSwift)
    }

    func testManifestWithoutRuntimeStillDefaultsToJavaScriptEntrypoint() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-js-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(
            """
            {
              "id": "dev.example.javascript",
              "name": "javascript",
              "version": "1.0.0",
              "permissions": [],
              "intents": { "uses": [], "provides": [] }
            }
            """.utf8
        ).write(to: temporary.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(try PluginLoader.loadManifest(at: temporary)) {
            guard case .entrypointMissing = $0 as? PluginLoadError else {
                return XCTFail("an omitted runtime did not require main.js: \($0)")
            }
        }
    }

    func testMissingCompiledImplementationFailsByExactPluginID() async throws {
        let manifest = try PluginManifest(
            id: "dev.example.missing-native",
            name: "missing-native",
            version: "1.0.0",
            runtime: .bundledSwift
        )
        let configuration = PluginRuntimeConfiguration(
            manifest: manifest,
            directory: FileManager.default.temporaryDirectory,
            intents: PluginRuntimeIntentBridge(
                send: { _ in Self.unavailableResult() },
                list: { .array([]) }
            )
        )

        do {
            _ = try await BundledPluginRuntime.factory.make(configuration)
            XCTFail("a missing compiled implementation was accepted")
        } catch {
            XCTAssertEqual(
                error as? PluginRuntimeError,
                .bundledSwiftImplementationUnavailable(manifest.id)
            )
        }
    }

    func testShutdownDeadlineReportsANonCooperativeEventPump() async throws {
        let pluginID: PluginID = "dev.example.blocked-native"
        let gate = BlockingEventGate()
        let program = BundledPluginProgram(
            id: pluginID,
            subscribedEvents: ["blocked"],
            providedIntents: [],
            activate: { _ in .empty },
            receiveEvent: { _, _, _ in
                await gate.wait()
                return nil
            },
            invokeIntent: { envelope, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
        let manifest = try PluginManifest(
            id: pluginID,
            name: "blocked-native",
            version: "1.0.0",
            runtime: .bundledSwift
        )
        let runtime = BundledPluginRuntimeActor(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: FileManager.default.temporaryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                )
            ),
            program: program
        )

        _ = try await runtime.start()
        XCTAssertTrue(
            runtime.acceptEvent(event: "blocked", payload: .object([:]))
        )
        try await gate.waitUntilEntered()
        let report = await runtime.shutdown(timeout: 0.01)
        XCTAssertEqual(report.stalledPhase, .callbackPump)
        let stoppedSnapshot = await runtime.snapshot()
        XCTAssertEqual(stoppedSnapshot.phase, .stopped)
        await gate.release()
    }

    func testActivationIsBoundedByTheConfiguredStartupTimeout() async throws {
        let pluginID: PluginID = "dev.example.slow-native"
        let manifest = try PluginManifest(
            id: pluginID,
            name: "slow-native",
            version: "1.0.0",
            runtime: .bundledSwift
        )
        let runtime = BundledPluginRuntimeActor(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: FileManager.default.temporaryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                ),
                startupTimeout: 0.01
            ),
            program: BundledPluginProgram(
                id: pluginID,
                subscribedEvents: [],
                providedIntents: [],
                activate: { _ in
                    try await Task.sleep(for: .seconds(1))
                    return .empty
                },
                receiveEvent: { _, _, _ in nil },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            )
        )

        do {
            _ = try await runtime.start()
            XCTFail("activation exceeded its configured deadline")
        } catch {
            XCTAssertEqual(
                error as? PluginRuntimeError,
                .startupTimedOut(0.01)
            )
        }
        let failedSnapshot = await runtime.snapshot()
        XCTAssertEqual(failedSnapshot.phase, .failed)
        _ = await runtime.shutdown(timeout: 1)
    }

    func testCompiledWorkspaceStatusKeepsPluginLifecycleAndEventBoundary() async throws {
        let directory = Self.pluginsRoot.appendingPathComponent("workspace-status")
        let manifest = try PluginLoader.loadManifest(at: directory)
        let recorder = RuntimeSnapshotRecorder()
        let runtime = try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                ),
                onStateChange: { snapshot in
                    await recorder.record(snapshot)
                }
            )
        )

        let started = try await runtime.start()
        XCTAssertNil(started.snapshot.runtimeThreadIdentifier)
        XCTAssertEqual(started.snapshot.statusBarText, "⊞ workspace")
        let handlesWorkspaceChanges = await runtime.handles(
            event: "workspace.changed"
        )
        XCTAssertTrue(handlesWorkspaceChanges)
        XCTAssertTrue(
            runtime.acceptEvent(
                event: "workspace.changed",
                payload: .object([
                    "tabs": .integer(1),
                    "slots": .integer(2),
                ])
            )
        )

        let updated = try await recorder.snapshot(
            where: { $0.statusBarText == "⊞ 1 tab · 2 slots" }
        )
        XCTAssertEqual(updated.phase, .active)
        let report = await runtime.shutdown(timeout: 2)
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertNil(report.createdThreadIdentifier)
    }

    func testUntrustedInventoryCannotSelectCompiledSwiftCode() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-native-trust-\(UUID().uuidString)")
        let plugins = temporary.appendingPathComponent("plugins")
        let pluginDirectory = plugins.appendingPathComponent("native")
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(
            """
            {
              "id": "dev.example.native",
              "name": "native",
              "version": "1.0.0",
              "runtime": "bundled-swift",
              "permissions": [],
              "intents": { "uses": [], "provides": [] }
            }
            """.utf8
        ).write(to: pluginDirectory.appendingPathComponent("manifest.json"))

        let host = try await PluginHost(
            pluginsRoot: plugins,
            stateRoot: temporary.appendingPathComponent("state"),
            kernel: IntentKernelComponents(
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            )
        )

        try await host.loadAll()
        let failures = await host.loadFailures
        XCTAssertEqual(failures.first?.directoryName, "native")
        XCTAssertTrue(
            failures.first?.diagnostic.contains("untrusted inventory") ?? false
        )
        await host.shutdown()
    }

    func testCompiledPluginStillEnablesAndDisablesThroughPluginHost() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-native-lifecycle-\(UUID().uuidString)")
        let plugins = temporary.appendingPathComponent("plugins")
        let plugin = plugins.appendingPathComponent("workspace-status")
        try FileManager.default.createDirectory(
            at: plugin,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(
            at: Self.pluginsRoot
                .appendingPathComponent("workspace-status/manifest.json"),
            to: plugin.appendingPathComponent("manifest.json")
        )

        let host = try await PluginHost(
            pluginsRoot: plugins,
            stateRoot: temporary.appendingPathComponent("state"),
            kernel: IntentKernelComponents(
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            ),
            authorization: .bundledInventory,
            invocationScopeProvider: { InvocationScope() },
            runtimeFactory: BundledPluginRuntime.factory
        )
        try await host.loadAll()
        let pluginID: PluginID = "dev.tenon.workspace-status"
        let loadedStatus = await host.statusItems.map(\.text)
        XCTAssertEqual(loadedStatus, ["⊞ workspace"])

        try await host.setEnabled(false, pluginID: pluginID)
        let disabledStatuses = await host.statusItems
        let disabledPlugin = await host.plugins.first { $0.id == pluginID }
        XCTAssertTrue(disabledStatuses.isEmpty)
        XCTAssertEqual(disabledPlugin?.isEnabled, false)
        XCTAssertEqual(disabledPlugin?.isLoaded, false)

        try await host.setEnabled(true, pluginID: pluginID)
        let restoredStatus = await host.statusItems.map(\.text)
        let enabledPlugin = await host.plugins.first { $0.id == pluginID }
        XCTAssertEqual(restoredStatus, ["⊞ workspace"])
        XCTAssertEqual(enabledPlugin?.isEnabled, true)
        XCTAssertEqual(enabledPlugin?.isLoaded, true)
        await host.shutdown()
    }

    private static func unavailableResult() -> IntentResult {
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

private actor RuntimeSnapshotRecorder {
    private var snapshots: [PluginRuntimeSnapshot] = []

    func record(_ snapshot: PluginRuntimeSnapshot) {
        snapshots.append(snapshot)
    }

    func snapshot(
        where predicate: @Sendable (PluginRuntimeSnapshot) -> Bool
    ) async throws -> PluginRuntimeSnapshot {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let match = snapshots.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuntimeSnapshotRecorderError.timedOut
    }
}

private enum RuntimeSnapshotRecorderError: Error {
    case timedOut
}

private actor BlockingEventGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard entered else { throw RuntimeSnapshotRecorderError.timedOut }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
