import Foundation
import XCTest
@testable import TenonApp

@MainActor
final class AppStatePathsTests: XCTestCase {
    func testEnvironmentOverrideChangesOnlyPluginInventoryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "source-plugins",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: inventoryRoot,
            withIntermediateDirectories: true
        )
        let sentinel = inventoryRoot.appendingPathComponent(".settings.json")
        try Data(#"{"legacy":true}"#.utf8).write(to: sentinel)
        let inventoryBefore = try Data(contentsOf: sentinel)

        let paths = try AppStatePaths.resolve(
            environment: ["TENON_PLUGINS_DIR": inventoryRoot.path],
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: nil
        )

        XCTAssertEqual(paths.pluginInventoryRoot, inventoryRoot)
        XCTAssertEqual(
            paths.stateRoot,
            applicationSupport
                .appendingPathComponent("Tenon", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        )
        XCTAssertEqual(
            paths.pluginStateRoot,
            paths.stateRoot.appendingPathComponent(
                "plugins",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            paths.workspaceStateRoot,
            paths.stateRoot.appendingPathComponent(
                "workspace",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            paths.runtimeStateRoot,
            paths.stateRoot.appendingPathComponent(
                "runtime",
                isDirectory: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), inventoryBefore)
    }

    func testBundleFallbackTrustsPluginInventory() async throws {
        let consents = try await standingConsentContracts(
            environment: [:],
            pluginID: "dev.test.bundle-fallback"
        )

        XCTAssertEqual(consents, ["process.exec.v1"])
    }

    func testEnvironmentOverrideIsUntrustedForCopiedBundledPluginID()
        async throws
    {
        let consents = try await standingConsentContracts(
            environment: [
                "TENON_PLUGINS_DIR": "$INVENTORY_ROOT",
            ],
            pluginID: "dev.tenon.core-commands"
        )

        XCTAssertEqual(consents, [])
    }

    func testEnvironmentOverrideWithExactTrustFlagIsDeveloperTrusted()
        async throws
    {
        let consents = try await standingConsentContracts(
            environment: [
                "TENON_PLUGINS_DIR": "$INVENTORY_ROOT",
                "TENON_TRUST_PLUGIN_INVENTORY": "1",
            ],
            pluginID: "dev.test.developer-trusted"
        )

        XCTAssertEqual(consents, ["process.exec.v1"])
    }

    func testUnknownTrustFlagValueLeavesOverrideUntrusted() async throws {
        let consents = try await standingConsentContracts(
            environment: [
                "TENON_PLUGINS_DIR": "$INVENTORY_ROOT",
                "TENON_TRUST_PLUGIN_INVENTORY": "true",
            ],
            pluginID: "dev.test.unknown-trust-flag"
        )

        XCTAssertEqual(consents, [])
    }

    func testConstructionFailureDoesNotRecordRecentWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: inventoryRoot,
            withIntermediateDirectories: true
        )
        let paths = try AppStatePaths.resolve(
            environment: ["TENON_PLUGINS_DIR": inventoryRoot.path],
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: nil
        )
        try Data(#"{"legacy":true}"#.utf8).write(
            to: paths.pluginStateRoot.appendingPathComponent(
                ".settings.json"
            )
        )
        let recentWorkspaces = paths.workspaceStateRoot
            .appendingPathComponent(".recent-workspaces.json")

        XCTAssertThrowsError(try AppComposition(paths: paths))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recentWorkspaces.path)
        )
    }

    func testStartFailureDoesNotRecordRecentWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let invalidPlugin = inventoryRoot.appendingPathComponent(
            "invalid-plugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidPlugin,
            withIntermediateDirectories: true
        )
        try Data(#"{"id":"invalid"}"#.utf8).write(
            to: invalidPlugin.appendingPathComponent("manifest.json")
        )
        let paths = try AppStatePaths.resolve(
            environment: ["TENON_PLUGINS_DIR": inventoryRoot.path],
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: nil
        )
        let recentWorkspaces = paths.workspaceStateRoot
            .appendingPathComponent(".recent-workspaces.json")
        let composition = try AppComposition(paths: paths)

        await composition.start()

        XCTAssertFalse(composition.isStarted)
        XCTAssertNotNil(composition.startupError)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recentWorkspaces.path)
        )
    }

    private func standingConsentContracts(
        environment: [String: String],
        pluginID: String
    ) async throws -> Set<String> {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let pluginRoot = inventoryRoot.appendingPathComponent(
            "plugin",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: pluginRoot,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "\(pluginID)",
          "name": "\(pluginID)",
          "version": "1",
          "permissions": ["process.exec"],
          "intents": {
            "uses": ["process.exec.v1"],
            "provides": []
          }
        }
        """.write(
            to: pluginRoot.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "tenon.log('ready')".write(
            to: pluginRoot.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let resolvedEnvironment = environment.mapValues {
            $0 == "$INVENTORY_ROOT" ? inventoryRoot.path : $0
        }
        let paths = try AppStatePaths.resolve(
            environment: resolvedEnvironment,
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: inventoryRoot
        )
        let composition = try AppComposition(paths: paths)

        await composition.start()
        let started = composition.isStarted
        let startupError = composition.startupError
        let policy = await composition.intentRuntime.kernel.policy.snapshot()
        await composition.stop()

        guard started else {
            XCTFail("AppComposition failed to start: \(startupError ?? "unknown")")
            return ["__startup_failed__"]
        }
        return Set(
            policy.callerConsents.compactMap { consent in
                guard consent.callerID.hasPrefix("plugin:\(pluginID):") else {
                    return nil
                }
                return consent.contract.rawValue
            }
        )
    }
}
