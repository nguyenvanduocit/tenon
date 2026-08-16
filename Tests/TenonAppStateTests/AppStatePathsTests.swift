import Foundation
import XCTest
@testable import TenonApp

@MainActor
final class AppStatePathsTests: XCTestCase {
    func testStagingCannotReplaceTheProductionGlobalCLI() {
        XCTAssertFalse(CLICommandInstaller.canInstall(in: .staging))
        XCTAssertThrowsError(try CLICommandInstaller.install(in: .staging)) { error in
            guard case .productionOnly? = error as? CLICommandInstaller.InstallError else {
                return XCTFail("expected productionOnly, got \(error)")
            }
        }
    }

    func testProductionAndStagingResolveDistinctDurableStateRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent("plugins", isDirectory: true)
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: inventoryRoot,
            withIntermediateDirectories: true
        )

        let production = try AppStatePaths.resolve(
            instanceChannel: .production,
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: inventoryRoot
        )
        let staging = try AppStatePaths.resolve(
            instanceChannel: .staging,
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: inventoryRoot
        )

        XCTAssertEqual(
            production.stateRoot,
            applicationSupport
                .appendingPathComponent("Tenon", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        )
        XCTAssertEqual(
            staging.stateRoot,
            applicationSupport
                .appendingPathComponent("Tenon Staging", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        )
        XCTAssertNotEqual(production.stateRoot, staging.stateRoot)
        XCTAssertNotEqual(production.commandFrecencyFile, staging.commandFrecencyFile)
    }

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

    func testConstructionFailureDoesNotRecordRecentWorkspace() async throws {
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

        do {
            _ = try await AppComposition.make(paths: paths)
            XCTFail("expected malformed plugin persistence to fail construction")
        } catch {
            // Expected: construction fails without recording the launch as recent.
        }
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
        let composition = try await AppComposition.make(paths: paths)

        await composition.start()

        XCTAssertFalse(composition.isStarted)
        XCTAssertNotNil(composition.startupError)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recentWorkspaces.path)
        )
    }

    // MARK: - T-062: authoring never writes into the app bundle

    /// The incident this pins: an agent was handed the bundle's own plugins folder,
    /// wrote a plugin there, and the write broke the app's code signature.
    func testBundledInventoryIsSealedAndAuthoringGoesToTheUserInventory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundledRoot = root
            .appendingPathComponent("Tenon.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )

        let paths = try AppStatePaths.resolve(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundledPluginsRoot: bundledRoot
        )

        XCTAssertFalse(
            paths.pluginInventoryIsWritable,
            "the app bundle is sealed; a write there invalidates its signature"
        )
        XCTAssertFalse(
            paths.userPluginInventoryRoot.path.contains(".app/"),
            "the authoring inventory must live outside any app bundle"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.userPluginInventoryRoot.path
            ),
            "the user inventory is created up front so authoring never has to invent it"
        )
    }

    func testDeveloperOverrideInventoryStaysWritable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "source-plugins",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: inventoryRoot,
            withIntermediateDirectories: true
        )

        let paths = try AppStatePaths.resolve(
            environment: ["TENON_PLUGINS_DIR": inventoryRoot.path],
            applicationSupportDirectory: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            bundledPluginsRoot: nil
        )

        XCTAssertTrue(
            paths.pluginInventoryIsWritable,
            "a developer root is an ordinary directory, so authoring may land there"
        )
    }

    /// End to end through the real composition: whatever the authoring flow is handed
    /// is writable and outside the bundle.
    func testCompositionOffersAWritableInventoryOutsideTheBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundledRoot = root
            .appendingPathComponent("Tenon.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )
        let paths = try AppStatePaths.resolve(
            environment: [:],
            applicationSupportDirectory: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            bundledPluginsRoot: bundledRoot
        )

        let composition = try await AppComposition.make(paths: paths)
        let writable = composition.host.writableInventoryRoot

        XCTAssertEqual(writable, paths.userPluginInventoryRoot)
        XCTAssertNotEqual(
            writable,
            bundledRoot,
            "the sealed bundle must never be offered as a place to write a plugin"
        )
    }

    /// A user workflow starts in the active workspace. It does not need the plugin inventory
    /// because the dynamic harness is owned by the agent session, not a Tenon plugin.
    @MainActor
    func testCreateWorkflowStartsTheAgentInTheActiveWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundledRoot = root
            .appendingPathComponent("Tenon.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: bundledRoot,
            withIntermediateDirectories: true
        )
        let paths = try AppStatePaths.resolve(
            environment: [:],
            applicationSupportDirectory: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            ),
            bundledPluginsRoot: bundledRoot
        )
        let composition = try await AppComposition.make(paths: paths)

        composition.openAutomationAuthoringPane()

        let paneID = try XCTUnwrap(
            composition.store.catalog.activeSlotID,
            "the flow opens a terminal pane to author in"
        )
        let startsIn = try XCTUnwrap(
            composition.terminalSurfaces.paneDirectory(for: paneID)?.cwd
        )
        let workspacePath = try XCTUnwrap(composition.store.catalog.activeWorkspace?.path)
        XCTAssertEqual(startsIn.standardizedFileURL, workspacePath.standardizedFileURL)
        XCTAssertFalse(
            startsIn.path.contains(".app/"),
            "no path inside an app bundle may ever be handed to the authoring agent"
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
        let composition = try await AppComposition.make(paths: paths)

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
