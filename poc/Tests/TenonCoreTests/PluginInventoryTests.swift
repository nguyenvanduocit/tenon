import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-062: plugins load from more than one place, and where a plugin came from decides
/// what it is trusted with.
///
/// The incident behind this: the authoring flow handed an agent the app bundle's own
/// plugins folder, the agent wrote a file there, and the write broke the bundle's code
/// signature so the app failed to start. Writable user content needs a writable home,
/// and a writable home must not inherit the bundle's standing consent.
final class PluginInventoryTests: XCTestCase {
    // MARK: - Which inventory owns a plugin (pure)

    func testResolutionPlacesEachPluginInItsOwningInventory() {
        let bundled = inventory("/tmp/app/Contents/Resources/plugins", writable: false)
        let user = inventory("/tmp/home/user-plugins", writable: true)

        XCTAssertEqual(
            PluginInventoryResolution.inventory(
                for: URL(fileURLWithPath: "/tmp/home/user-plugins/mine.js"),
                in: [bundled, user]
            )?.root,
            user.root
        )
        XCTAssertEqual(
            PluginInventoryResolution.inventory(
                for: URL(fileURLWithPath: "/tmp/app/Contents/Resources/plugins/clock"),
                in: [bundled, user]
            )?.root,
            bundled.root
        )
    }

    func testADirectoryNoInventoryOwnsResolvesToNothing() {
        let bundled = inventory("/tmp/app/Contents/Resources/plugins", writable: false)

        XCTAssertNil(
            PluginInventoryResolution.inventory(
                for: URL(fileURLWithPath: "/tmp/elsewhere/rogue"),
                in: [bundled]
            ),
            "an unowned path must not resolve to an inventory — the caller treats nil as untrusted"
        )
        XCTAssertNil(
            PluginInventoryResolution.inventory(
                for: URL(fileURLWithPath: "/tmp/app/Contents/Resources/plugins/deep/nested"),
                in: [bundled]
            ),
            "discovery yields direct children only; a grandchild is not this inventory's plugin"
        )
    }

    // MARK: - Discovery across inventories

    func testDiscoveryReturnsEveryInventoryWithThePrimaryFirst() throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "zulu", in: bundled, id: "dev.test.zulu")
        try writeDirectoryPlugin(named: "alpha", in: user, id: "dev.test.alpha")

        let found = PluginLoader.discover(in: [bundled, user])

        XCTAssertEqual(
            found.map(\.lastPathComponent),
            ["zulu", "alpha"],
            "inventory order outranks name order, so the primary inventory wins identity clashes"
        )
    }

    func testAnAbsentInventoryRootContributesNothingInsteadOfFailing() throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try writeDirectoryPlugin(named: "clock", in: bundled, id: "dev.test.clock")
        let neverCreated = root.appendingPathComponent("user", isDirectory: true)

        XCTAssertEqual(
            PluginLoader.discover(in: [bundled, neverCreated])
                .map(\.lastPathComponent),
            ["clock"],
            "the user inventory is empty until someone writes their first plugin"
        )
    }

    // MARK: - Trust follows the inventory

    /// The security rule this whole task exists for: two byte-identical plugins, one in
    /// the host-controlled inventory and one in the user's, must not end up with the
    /// same authority.
    @MainActor
    func testOnlyTheHostControlledInventoryGrantsStandingConsent() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(
            named: "shipped",
            in: bundled,
            id: "dev.test.shipped",
            uses: ["process.exec.v1"]
        )
        try writeDirectoryPlugin(
            named: "authored",
            in: user,
            id: "dev.test.authored",
            uses: ["process.exec.v1"]
        )

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try makeHost(
            bundled: bundled,
            user: user,
            stateIn: root,
            kernel: kernel
        )
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        let snapshot = await kernel.policy.snapshot()
        func consentCount(_ pluginID: String) -> Int {
            snapshot.callerConsents
                .filter { $0.callerID.hasPrefix("plugin:\(pluginID):") }
                .count
        }

        XCTAssertEqual(
            consentCount("dev.test.shipped"),
            1,
            "a plugin that shipped with the app keeps its standing consent"
        )
        XCTAssertEqual(
            consentCount("dev.test.authored"),
            0,
            "a plugin the user wrote is asked; putting a file in a folder must not grant authority"
        )
        XCTAssertEqual(
            host.plugins.count,
            2,
            "both inventories load — this is not consent by exclusion"
        )
    }

    @MainActor
    func testWritableInventoryRootNamesNoSealedInventory() throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundled,
            withIntermediateDirectories: true
        )

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)

        XCTAssertEqual(host.pluginsRoot, bundled, "the primary inventory is still the first one")
        XCTAssertEqual(
            host.writableInventoryRoot,
            user,
            "authoring must be sent to the writable inventory, never the sealed bundle"
        )
    }

    // MARK: - A broken plugin fails alone

    /// Invariant 4 — "a broken plugin never takes down the host" — has always been
    /// tested for hot reload. At launch it did not hold: `prepareAllManifests` threw on
    /// the first unreadable manifest, so one bad file in a user inventory took every
    /// other plugin down with it. That is the shape of the reported incident.
    @MainActor
    func testOneUnreadableManifestDoesNotStopTheOtherPluginsLoading() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "healthy", in: bundled, id: "dev.test.healthy")
        let broken = user.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(
            at: broken,
            withIntermediateDirectories: true
        )
        try #"{ "id": "dev.test.broken", "name": "#.write(
            to: broken.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)

        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(
            host.plugins.map(\.id),
            ["dev.test.healthy"],
            "the healthy plugin must load even though a sibling manifest is unreadable"
        )
        XCTAssertEqual(
            host.loadFailures.map(\.directoryName),
            ["broken"],
            "the broken one is reported by name so the author can fix it"
        )
        XCTAssertFalse(
            host.loadFailures.first?.diagnostic.isEmpty ?? true,
            "a diagnostic with no text tells the author nothing"
        )
    }

    // MARK: - A user inventory can never take the whole host down with it

    /// The promise `docs/design-automations.md` makes — "the earlier inventory wins any
    /// identity clash; a user plugin cannot displace a bundled one by reusing its id" —
    /// is worth nothing if the clash instead fails the whole load. Reusing an id is one
    /// copy-paste away for a person or an agent writing their first plugin, and the cost
    /// of it must be that plugin, never Tenon.
    @MainActor
    func testAUserPluginReusingABundledIDLosesAloneInsteadOfFailingEveryPlugin() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "clock", in: bundled, id: "dev.test.clock")
        try writeDirectoryPlugin(named: "my-clock", in: user, id: "dev.test.clock")

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(
            host.plugins.map(\.name),
            ["clock"],
            "the bundled copy keeps the id; the later inventory yields it"
        )
        XCTAssertEqual(
            host.loadFailures.map(\.directoryName),
            ["my-clock"],
            "the rejected plugin is named, so its author can see why it never appeared"
        )
        XCTAssertTrue(
            host.loadFailures.first?.diagnostic.contains("dev.test.clock") ?? false,
            "the diagnostic must name the id that clashed, not just say no"
        )
    }

    /// A directory name is an identity here too: it keys hot reload, uninstall-on-delete
    /// and every load failure. Two inventories can hold the same name, and before this
    /// task nothing stopped them — a change to the user's `clock` reloaded the bundled
    /// one instead, and deleting it uninstalled nothing, both in silence.
    @MainActor
    func testAUserPluginReusingABundledDirectoryNameIsRejectedAlone() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "clock", in: bundled, id: "dev.test.clock")
        try writeDirectoryPlugin(named: "clock", in: user, id: "dev.local.clock")

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(
            host.plugins.map(\.id),
            ["dev.test.clock"],
            "a name the reload path cannot tell apart must resolve to exactly one plugin"
        )
        XCTAssertEqual(host.loadFailures.count, 1)
        XCTAssertTrue(
            host.loadFailures.first?.diagnostic.contains("clock") ?? false,
            "the diagnostic must name the directory the author has to rename"
        )
    }

    /// `dev.test.core` and `dev.test.core.extra` overlap, and the host refuses
    /// overlapping namespaces because an id prefix is how ownership is decided. The
    /// refusal is right; refusing by taking every other plugin with it is not.
    @MainActor
    func testAUserPluginOverlappingABundledNamespaceIsRejectedAlone() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "core", in: bundled, id: "dev.test.core")
        try writeDirectoryPlugin(named: "extra", in: user, id: "dev.test.core.extra")

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(host.plugins.map(\.id), ["dev.test.core"])
        XCTAssertEqual(host.loadFailures.map(\.directoryName), ["extra"])
    }

    /// The reserved namespace belongs to the host's own trusted provider. A user plugin
    /// claiming it is refused — alone, and by name.
    @MainActor
    func testAUserPluginClaimingTheReservedNamespaceIsRejectedAlone() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "clock", in: bundled, id: "dev.test.clock")
        try writeDirectoryPlugin(
            named: "impostor",
            in: user,
            id: CoreIntentCatalog.trustedProviderIDRawValue + ".impostor"
        )

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(host.plugins.map(\.id), ["dev.test.clock"])
        XCTAssertEqual(host.loadFailures.map(\.directoryName), ["impostor"])
    }

    /// Not every way a plugin can be wrong is an identity clash. This one is a plausible
    /// agent mistake — naming an intent in `provides` that no contract defines — and it
    /// used to throw straight out of preparation, which is the same fatal shape.
    @MainActor
    func testAUserPluginProvidingAnUnknownContractIsRejectedAlone() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "clock", in: bundled, id: "dev.test.clock")
        try writeDirectoryPlugin(
            named: "typo",
            in: user,
            id: "dev.local.typo",
            provides: ["dev.local.typo.no.such.contract.v1"]
        )

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        XCTAssertEqual(host.plugins.map(\.id), ["dev.test.clock"])
        XCTAssertEqual(host.loadFailures.map(\.directoryName), ["typo"])
        XCTAssertFalse(
            host.loadFailures.first?.diagnostic.isEmpty ?? true,
            "a rejection with no diagnostic leaves the author guessing"
        )
    }

    /// The other half of the rule, so tolerance stops exactly where it should: two
    /// clashing plugins **inside the primary inventory** still fail the load. That
    /// inventory ships with the app, so a clash there is a build error, and a build error
    /// that loads four plugins out of five and says nothing is worse than one that stops.
    @MainActor
    func testAnIdentityClashInsideThePrimaryInventoryStillFailsTheLoad() async throws {
        let root = try makeTemporaryDirectory()
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeDirectoryPlugin(named: "first", in: bundled, id: "dev.test.twin")
        try writeDirectoryPlugin(named: "second", in: bundled, id: "dev.test.twin")

        let host = try makeHost(bundled: bundled, user: user, stateIn: root)
        addTeardownBlock { await host.shutdown() }

        do {
            try await host.loadAll()
            XCTFail("a duplicate id inside the shipped inventory must still fail the load")
        } catch {
            XCTAssertEqual(
                error as? PluginHostError,
                .duplicatePluginID(
                    pluginID: PluginID("dev.test.twin"),
                    directories: ["first", "second"]
                )
            )
        }
    }

    // MARK: - The manifest shape an agent is actually told to write

    /// The incident file declared `"intents": { "uses": [...] }` with no `provides` —
    /// the exact shape the authoring guide and the single-file docs show. If that does
    /// not decode, every agent-written plugin is born broken.
    func testAManifestThatDeclaresUsesWithoutProvidesDecodes() throws {
        let json = """
        {
          "id": "dev.local.git-auto-update",
          "name": "git-auto-update",
          "version": "1",
          "permissions": ["process.exec"],
          "intents": { "uses": ["process.exec.v1"] },
          "automation": { "schedules": [ { "id": "main", "every": "5m" } ] }
        }
        """

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(
            manifest.intents.uses,
            [try IntentID("process.exec.v1")]
        )
        XCTAssertEqual(
            manifest.intents.provides,
            [],
            "a plugin that provides nothing should not have to say so"
        )
    }

    /// The distinction an agent will trip over, stated in one place: the `intents`
    /// envelope is required — declaring what a plugin uses and provides is a deliberate
    /// act, even when both lists are empty
    /// (`testLoaderRejectsManifestWithoutCompleteIntentsEnvelope` owns that rule) — but
    /// the two halves inside it are not, because an absent list and an empty list grant
    /// exactly the same thing: nothing.
    func testTheIntentsEnvelopeIsRequiredEvenThoughItsHalvesAreNot() throws {
        let withEmptyEnvelope = """
        {
          "id": "dev.local.quiet",
          "name": "quiet",
          "version": "1",
          "intents": {}
        }
        """
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(withEmptyEnvelope.utf8)
        )
        XCTAssertEqual(manifest.intents.uses, [])
        XCTAssertEqual(manifest.intents.provides, [])

        let withNoEnvelope = """
        {
          "id": "dev.local.quiet",
          "name": "quiet",
          "version": "1"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PluginManifest.self,
                from: Data(withNoEnvelope.utf8)
            ),
            "omitting the envelope entirely stays a manifest error"
        )
    }

    // MARK: - Helpers

    private func inventory(_ path: String, writable: Bool) -> PluginInventory {
        PluginInventory(
            root: URL(fileURLWithPath: path, isDirectory: true),
            authorization: writable
                ? PluginHostAuthorization(approvedOpenIntentIDs: { _, _ in [] })
                : .bundledInventory,
            isWritable: writable
        )
    }

    /// The two-inventory host every test here needs: a sealed primary standing in for
    /// the app bundle, and a writable untrusted one standing in for the user's.
    @MainActor
    private func makeHost(
        bundled: URL,
        user: URL,
        stateIn root: URL,
        kernel: IntentKernelComponents? = nil
    ) throws -> PluginHost {
        try PluginHost(
            inventories: [
                PluginInventory(
                    root: bundled,
                    authorization: .bundledInventory,
                    isWritable: false
                ),
                PluginInventory(
                    root: user,
                    authorization: PluginHostAuthorization(
                        approvedOpenIntentIDs: { _, _ in [] }
                    ),
                    isWritable: true
                ),
            ],
            stateRoot: root.appendingPathComponent("state", isDirectory: true),
            kernel: try kernel ?? IntentKernelComponents(
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            ),
            invocationScopeProvider: { InvocationScope() }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-inventory-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeDirectoryPlugin(
        named name: String,
        in root: URL,
        id: String,
        uses: [String] = [],
        provides: [String] = []
    ) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let usesList = uses.map { "\"\($0)\"" }.joined(separator: ", ")
        let providesList = provides
            .map { "{ \"name\": \"\($0)\" }" }
            .joined(separator: ", ")
        let permissions = uses.isEmpty ? "" : "\"process.exec\""
        try """
        {
          "id": "\(id)",
          "name": "\(name)",
          "version": "1",
          "permissions": [\(permissions)],
          "intents": { "uses": [\(usesList)], "provides": [\(providesList)] }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "tenon.log('ready');".write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
    }
}
