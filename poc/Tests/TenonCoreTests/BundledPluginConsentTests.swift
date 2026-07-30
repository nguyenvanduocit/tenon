import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// Plugins that ship with the app are *seeded*, never *exempted*.
///
/// The rules are identical for every plugin — same public surface, same principal, same
/// fail-closed policy path. Only the seed differs, and the decision to seed lives in
/// `PluginHostAuthorization`, which no manifest can reach.
final class BundledPluginConsentTests: XCTestCase {
    /// Seeding covers exactly the contracts that consult standing consent — the `.policy`
    /// ones. `.never` needs no consent to skip, and `.always` must keep asking: recording
    /// authority for either would be state nothing reads, or a silent erosion of the one
    /// mode whose entire purpose is to ask every time.
    @MainActor
    func testBundledPluginIsSeededForPolicyContractsAndNothingElse() async throws {
        let fixture = try makeFixture(
            manifest: manifest(
                id: "dev.test.bundled",
                uses: [
                    "process.exec.v1", // .policy — seeded
                    "terminal.write.v1", // .policy — seeded
                    "workspace.state.v1", // .never  — nothing to consent to
                    "secrets.delete.v1", // .always — must keep asking
                ]
            ),
            authorization: .bundledInventory
        )

        try await fixture.host.loadAll()

        let consents = await fixture.consents(for: "dev.test.bundled")
        XCTAssertEqual(
            Set(consents.map(\.contract.rawValue)),
            ["process.exec.v1", "terminal.write.v1"],
            "seed the .policy contracts, and only those"
        )
        await fixture.host.shutdown()
    }

    /// The complement of the test above — without it, "seeded" and "always allowed" would
    /// be indistinguishable.
    @MainActor
    func testPluginOutsideTheBundledInventoryGetsNoStandingConsent() async throws {
        let fixture = try makeFixture(
            manifest: manifest(
                id: "dev.test.sideloaded",
                uses: ["process.exec.v1"]
            ),
            authorization: PluginHostAuthorization(
                approvedOpenIntentIDs: { _, _ in [] },
                grantsStandingConsent: { _, _ in false }
            )
        )

        try await fixture.host.loadAll()

        let consents = await fixture.consents(for: "dev.test.sideloaded")
        XCTAssertTrue(
            consents.isEmpty,
            "an unseeded plugin is asked once and remembered, never pre-approved"
        )
        await fixture.host.shutdown()
    }

    @MainActor
    func testPluginHostDefaultsToUntrustedInventory() async throws {
        let fixture = try makeFixture(
            manifest: manifest(
                id: "dev.test.default-untrusted",
                uses: ["process.exec.v1"]
            )
        )

        try await fixture.host.loadAll()

        let consents = await fixture.consents(
            for: "dev.test.default-untrusted"
        )
        XCTAssertTrue(
            consents.isEmpty,
            "omitting inventory provenance must never seed standing consent"
        )
        await fixture.host.shutdown()
    }

    /// A manifest is plugin-authored input. If it could claim to be bundled, every plugin
    /// would.
    @MainActor
    func testManifestCannotClaimBundledStatusForItself() async throws {
        let fixture = try makeFixture(
            manifest: """
            {
              "id": "dev.test.self-promoter",
              "name": "dev.test.self-promoter",
              "version": "1",
              "bundled": true,
              "builtin": true,
              "trusted": true,
              "permissions": [],
              "intents": {
                "uses": ["workspace.state.v1"],
                "provides": []
              }
            }
            """,
            authorization: PluginHostAuthorization(
                approvedOpenIntentIDs: { _, _ in [] },
                grantsStandingConsent: { _, _ in false }
            )
        )

        try await fixture.host.loadAll()

        let consents = await fixture.consents(for: "dev.test.self-promoter")
        XCTAssertTrue(
            consents.isEmpty,
            "standing consent is host-owned; a manifest claiming it must buy nothing"
        )
        await fixture.host.shutdown()
    }

    /// Hot reload activates the new generation and *then* retires the old one. Both share a
    /// caller id, because consent belongs to the installation rather than the generation —
    /// so retirement must not take the consent the new generation just seeded with it.
    /// Getting this wrong makes a bundled plugin prompt again after its first reload.
    @MainActor
    func testHotReloadKeepsTheConsentTheNewGenerationSeeded() async throws {
        let fixture = try makeFixture(
            manifest: manifest(
                id: "dev.test.reload-keeps-consent",
                uses: ["process.exec.v1"]
            ),
            authorization: .bundledInventory
        )
        try await fixture.host.loadAll()
        let seeded = await fixture.consents(for: "dev.test.reload-keeps-consent")
        XCTAssertFalse(seeded.isEmpty)

        try await fixture.host.reload(directoryNamed: "plugin")

        let afterReload = await fixture.consents(
            for: "dev.test.reload-keeps-consent"
        )
        XCTAssertEqual(
            Set(afterReload.map(\.contract.rawValue)),
            ["process.exec.v1"],
            "retiring the previous generation must not revoke the live one's consent"
        )
        await fixture.host.shutdown()
    }

    /// Disabling is the user withdrawing the plugin, not a generation swap: that one does
    /// drop consent.
    @MainActor
    func testDisablingABundledPluginDropsItsStandingConsent() async throws {
        let pluginID: PluginID = "dev.test.disable-drops-consent"
        let fixture = try makeFixture(
            manifest: manifest(
                id: pluginID.rawValue,
                uses: ["process.exec.v1"]
            ),
            authorization: .bundledInventory
        )
        try await fixture.host.loadAll()
        let seeded = await fixture.consents(for: pluginID.rawValue)
        XCTAssertFalse(seeded.isEmpty)

        try await fixture.host.setEnabled(false, pluginID: pluginID)

        let remaining = await fixture.consents(for: pluginID.rawValue)
        XCTAssertTrue(
            remaining.isEmpty,
            "a disabled plugin keeps no standing authority"
        )
        await fixture.host.shutdown()
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
        let kernel: IntentKernelComponents

        func consents(
            for pluginID: String
        ) async -> [CallerConsentKey] {
            let snapshot = await kernel.policy.snapshot()
            return snapshot.callerConsents
                .filter { $0.callerID.hasPrefix("plugin:\(pluginID):") }
        }
    }

    @MainActor
    private func makeFixture(
        manifest: String,
        authorization: PluginHostAuthorization? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-bundled-consent-\(UUID().uuidString)",
                isDirectory: true
            )
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let pluginsRoot = root.appendingPathComponent(
            "plugins",
            isDirectory: true
        )
        let directory = pluginsRoot.appendingPathComponent(
            "plugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try manifest.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "tenon.log('ready')".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host: PluginHost
        if let authorization {
            host = try PluginHost(
                pluginsRoot: pluginsRoot,
                stateRoot: stateRoot,
                kernel: kernel,
                authorization: authorization,
                invocationScopeProvider: { InvocationScope() }
            )
        } else {
            host = try PluginHost(
                pluginsRoot: pluginsRoot,
                stateRoot: stateRoot,
                kernel: kernel,
                invocationScopeProvider: { InvocationScope() }
            )
        }
        return Fixture(host: host, kernel: kernel)
    }

    private func manifest(id: String, uses: [String]) -> String {
        let usesList = uses.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "id": "\(id)",
          "name": "\(id)",
          "version": "1",
          "permissions": ["process.exec", "terminal.write", "secrets"],
          "intents": {
            "uses": [\(usesList)],
            "provides": []
          }
        }
        """
    }
}
