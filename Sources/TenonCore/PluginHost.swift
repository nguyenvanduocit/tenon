// @domain: plugin-host, plugin-events
//
// The coordinator itself: identity, activation, hot reload, contribution and event routing.
// Its vocabulary lives in `PluginHostModels.swift`, its durable stores in
// `PluginHostPersistence.swift`, and its pure rules in `PluginHostPolicy.swift` — what is left
// here is the part that has to happen in an order.
import Foundation
import Observation
import os
import TenonIntentCore

// MARK: - Host state  @domain: plugin-host

/// Main-actor coordinator for plugin identity, lifecycle, contributions, and events.
///
/// Every invocation enters the shared `IntentDispatcher`. This type never implements
/// command semantics and never gives JavaScript a direct callback into the app shell.
@MainActor
@Observable
public final class PluginHost {
    public typealias InvocationScopeProvider = @Sendable () async -> InvocationScope

    public private(set) var plugins: [PluginSnapshot] = []
    public private(set) var loadFailures: [PluginLoadFailure] = []
    public private(set) var statusItems: [StatusItem] = []
    public private(set) var pluginViews: [PluginViewSection] = []
    public private(set) var intentPresentations: [PluginIntentPresentation] = []
    public private(set) var keyBindingIndex = KeyBindingIndex(
        requests: [],
        reserved: KeyBindingIndex.shellReserved
    )
    public private(set) var commandIndex = CommandIndex()
    public private(set) var paletteSections: [PaletteProviderSection] = []
    public private(set) var paletteQueryRevision = 0
    public private(set) var log: [String] = []

    /// Every place plugins load from, ordered; the first is the primary one (T-062).
    @ObservationIgnored
    public let inventories: [PluginInventory]

    /// The primary inventory's root — what "the plugins folder" means when only one
    /// is configured, which is every test and the developer override.
    public var pluginsRoot: URL { inventories[0].root }

    /// Where a newly authored plugin may be written. Nil when every configured
    /// inventory is sealed, which is the honest answer for a signed app bundle: the
    /// caller must not invent a path.
    public var writableInventoryRoot: URL? {
        inventories.first(where: \.isWritable)?.root
    }

    @ObservationIgnored
    public let stateRoot: URL

    @ObservationIgnored
    public let kernel: IntentKernelComponents

    /// Direct same-owner lifecycle notification for app-owned resources that are
    /// scoped to a plugin installation. The callback runs only after `plugins`
    /// contains the new durable lifecycle snapshot.
    @ObservationIgnored
    public var onPluginLifecycleChanged: (([PluginSnapshot]) -> Void)?

    public let settings: SettingsStore

    @ObservationIgnored
    private let installations: PluginInstallationStore

    @ObservationIgnored
    private let storage: PluginStorage

    @ObservationIgnored
    private let secrets: SecretStore

    @ObservationIgnored
    private let coreCatalog: CoreIntentCatalog

    /// Which inventory currently holds an entry of this name. Falls back to the
    /// primary root so a name present in none resolves exactly where it used to —
    /// that path is how a vanished plugin is noticed and uninstalled.
    private func inventoryRoot(containingEntryNamed name: String) -> URL {
        for inventory in inventories
        where FileManager.default.fileExists(
            atPath: inventory.root.appendingPathComponent(name).path
        ) {
            return inventory.root
        }
        return pluginsRoot
    }

    /// Whether a discovered plugin belongs to the primary inventory. An unowned
    /// directory counts as primary: discovery cannot produce one, and if something ever
    /// does, the strict old behaviour is the safer answer.
    private func isPrimaryInventory(_ directory: URL) -> Bool {
        guard let owner = PluginInventoryResolution.inventory(
            for: directory,
            in: inventories
        ) else {
            return true
        }
        return owner.root.standardizedFileURL.path
            == inventories[0].root.standardizedFileURL.path
    }

    /// The authorization a plugin discovered at `directory` answers to — the one
    /// belonging to the inventory that owns it. Fail-closed: a directory no inventory
    /// claims is treated as untrusted rather than inheriting the primary's trust.
    private func authorization(
        forPluginAt directory: URL
    ) -> PluginHostAuthorization {
        PluginInventoryResolution.inventory(for: directory, in: inventories)?
            .authorization
            ?? PluginHostAuthorization(approvedOpenIntentIDs: { _, _ in [] })
    }

    @ObservationIgnored
    private let invocationScopeProvider: InvocationScopeProvider

    @ObservationIgnored
    private let runtimeFactory: PluginHostRuntimeFactory

    @ObservationIgnored
    private var sessions: [PluginID: ActiveSession] = [:]

    @ObservationIgnored
    private var manifests: [PluginID: ManifestRecord] = [:]

    @ObservationIgnored
    private var pluginIDByDirectory: [String: PluginID] = [:]

    @ObservationIgnored
    private var installationKeys: [PluginID: PluginInstallationKey] = [:]

    @ObservationIgnored
    private var lastErrors: [PluginID: String] = [:]

    @ObservationIgnored
    private var publishedKeyBindingDiagnostics: Set<KeyBindingDiagnostic> = []

    @ObservationIgnored
    private var registeredProviderIDs: Set<PluginID> = []

    @ObservationIgnored
    /// One watcher per inventory (T-062): a user plugin has to hot-reload exactly like
    /// a bundled one, and FSEvents watches a root, not a set of them.
    private var watchers: [PluginWatcher] = []

    @ObservationIgnored
    private var watcherReloadTask: Task<Void, Never>?

    @ObservationIgnored
    private var lastWorkspaceCatalog: WorkspaceCatalog?

    @ObservationIgnored
    private var isReconcilingViews = false

    @ObservationIgnored
    private var needsViewReconcile = false

    @ObservationIgnored
    private var lifecycle: Lifecycle = .running

    @ObservationIgnored
    private var shutdownTask: Task<Void, Never>?

    @ObservationIgnored
    private var activeLifecycleOperationCount = 0

    @ObservationIgnored
    private var lifecycleMutationIsOwned = false

    @ObservationIgnored
    private var lifecycleMutationWaiterOrder: [UUID] = []

    @ObservationIgnored
    private var lifecycleMutationWaiterStates: [
        UUID: LifecycleMutationWaiterState
    ] = [:]

    @ObservationIgnored
    private var lifecycleDrainWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    @ObservationIgnored
    public var maxLogLines = 500

    private enum Lifecycle {
        case running
        case shuttingDown
        case stopped
    }

    private enum LifecycleMutationWaitResult: Sendable {
        case acquired
        case cancelled
    }

    private enum LifecycleMutationWaiterState {
        case awaitingRegistration
        case cancelledBeforeRegistration
        case queued(
            CheckedContinuation<LifecycleMutationWaitResult, Never>
        )
    }

    private enum RetirementDisposition {
        case disabled
        case uninstalled
    }

    private struct ManifestRecord {
        let directoryName: String
        let directory: URL
        let manifest: PluginManifest
        var isEnabled: Bool
    }

    private struct PreparedPlugin {
        let record: ManifestRecord
        let installation: PluginInstallationKey?
        let declarations: [IntentContractDeclaration]
        let dispatchRules: [IntentDispatchRule]
        let openIntentReferences: Set<IntentID>
    }

    private struct DiscoveredManifest: Sendable {
        let directory: URL
        let manifest: PluginManifest
    }

    private struct ManifestDiscovery: Sendable {
        let decoded: [DiscoveredManifest]
        let failures: [PluginLoadFailure]
    }

    private struct ActiveSession {
        let identity: PluginSessionIdentity
        let directoryName: String
        let runtime: any PluginHostRuntime
        var snapshot: PluginRuntimeSnapshot
        let hasProvider: Bool
    }

    private struct RuntimeCandidate {
        let prepared: PreparedPlugin
        let identity: PluginSessionIdentity
        let principal: IntentPrincipal
        let runtime: any PluginHostRuntime
        let startResult: PluginRuntimeStartResult
        let providerID: ProviderID
        let authorization: PluginProviderActivationAuthorization
        let providerGeneration: ProviderGenerationCandidate?
    }

    /// One open instance of one registered view. Nested in the host because it means nothing
    /// outside it, and no longer `private` because the sorting rule that orders these lives
    /// with the host's other pure projections.
    struct ViewInstanceReference: Sendable, Hashable {
        let pluginID: PluginID
        let viewID: String
        let instanceID: String
    }

    public convenience init(
        pluginsRoot: URL,
        stateRoot: URL,
        kernel: IntentKernelComponents,
        authorization: PluginHostAuthorization = PluginHostAuthorization(
            approvedOpenIntentIDs: { _, _ in [] }
        ),
        invocationScopeProvider: @escaping InvocationScopeProvider = {
            InvocationScope()
        }
    ) throws {
        try self.init(
            pluginsRoot: pluginsRoot,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: authorization,
            invocationScopeProvider: invocationScopeProvider,
            runtimeFactory: .live
        )
    }

    /// One writable inventory — the shape every test and the developer override use.
    package convenience init(
        pluginsRoot: URL,
        stateRoot: URL,
        kernel: IntentKernelComponents,
        authorization: PluginHostAuthorization,
        invocationScopeProvider: @escaping InvocationScopeProvider,
        runtimeFactory: PluginHostRuntimeFactory
    ) throws {
        try self.init(
            inventories: [
                PluginInventory(
                    root: pluginsRoot,
                    authorization: authorization,
                    isWritable: true
                ),
            ],
            stateRoot: stateRoot,
            kernel: kernel,
            invocationScopeProvider: invocationScopeProvider,
            runtimeFactory: runtimeFactory
        )
    }

    public convenience init(
        inventories: [PluginInventory],
        stateRoot: URL,
        kernel: IntentKernelComponents,
        invocationScopeProvider: @escaping InvocationScopeProvider = {
            InvocationScope()
        }
    ) throws {
        try self.init(
            inventories: inventories,
            stateRoot: stateRoot,
            kernel: kernel,
            invocationScopeProvider: invocationScopeProvider,
            runtimeFactory: .live
        )
    }

    package convenience init(
        inventories: [PluginInventory],
        stateRoot: URL,
        kernel: IntentKernelComponents,
        persistence: PluginHostPersistence,
        invocationScopeProvider: @escaping InvocationScopeProvider = {
            InvocationScope()
        },
        runtimeFactory: PluginHostRuntimeFactory = .live
    ) throws {
        try self.init(
            inventories: inventories,
            stateRoot: stateRoot,
            kernel: kernel,
            invocationScopeProvider: invocationScopeProvider,
            runtimeFactory: runtimeFactory,
            persistence: persistence
        )
    }

    init(
        inventories: [PluginInventory],
        stateRoot: URL,
        kernel: IntentKernelComponents,
        invocationScopeProvider: @escaping InvocationScopeProvider,
        runtimeFactory: PluginHostRuntimeFactory,
        persistence: PluginHostPersistence? = nil
    ) throws {
        guard !inventories.isEmpty else {
            throw PluginHostError.noInventoryConfigured
        }
        self.inventories = inventories
        self.stateRoot = stateRoot
        self.kernel = kernel
        self.invocationScopeProvider = invocationScopeProvider
        self.runtimeFactory = runtimeFactory
        let resolvedPersistence = try persistence
            ?? PluginHostPersistence(stateRoot: stateRoot)
        installations = resolvedPersistence.installations
        settings = resolvedPersistence.settings
        storage = resolvedPersistence.storage
        secrets = resolvedPersistence.secrets
        coreCatalog = CoreIntentCatalog(components: kernel)
    }

    // MARK: - Loading and hot reload  @domain: plugin-host

    /// Validates the complete manifest batch before constructing any runtime, then starts
    /// every enabled candidate before publishing any provider generation.
    public func loadAll() async throws {
        try await beginLifecycleOperation()
        defer {
            endLifecycleOperation()
        }
        do {
            let (prepared, manifestFailures) = try await prepareAllManifests()
            loadFailures = manifestFailures
            try await installStaticContracts(from: prepared)
            try await activate(
                prepared,
                replacingManifestInventory: true
            )
            if prepared.isEmpty {
                appendLog("host: no plugins found under \(pluginsRoot.path)")
            }
        } catch {
            recordLoadFailure(error)
            throw error
        }
    }

    /// Reloads one directory after re-validating the complete on-disk identity namespace.
    /// A failed candidate never replaces the active session.
    public func reload(directoryNamed directoryName: String) async throws {
        try await beginLifecycleOperation()
        defer {
            endLifecycleOperation()
        }
        try await reloadOperation(directoryName: directoryName)
    }

    private func reloadOperation(
        directoryName: String
    ) async throws {
        try Task.checkCancellation()

        let entry = inventoryRoot(
            containingEntryNamed: directoryName
        )
        .appendingPathComponent(directoryName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: entry.path,
            isDirectory: &isDirectory
        ) else {
            guard let pluginID = pluginIDByDirectory[directoryName] else {
                return
            }
            try await uninstallOperation(pluginID: pluginID)
            appendLog(
                "host: uninstalled \(pluginID.rawValue) because its entry disappeared"
            )
            return
        }

        if isDirectory.boolValue {
            guard FileManager.default.fileExists(
                atPath: entry.appendingPathComponent("manifest.json").path
            ) else {
                let error = PluginHostError.manifestInvalid(
                    directory: directoryName,
                    diagnostic: "manifest.json is missing"
                )
                recordLoadFailure(error)
                throw error
            }
        } else {
            // T-047: a plugin is a directory or one file, and reload has to admit the
            // same two shapes discovery does. Asking only "is it a directory?" drops a
            // `.js` written into the root after launch — the watcher reports it, this
            // path finds no prior installation for it, and it vanishes without a
            // diagnostic. The admission test is the one `PluginLoader.discover` uses.
            let source = try? String(contentsOf: entry, encoding: .utf8)
            guard PluginLoader.isSingleFilePlugin(entry),
                  let source,
                  PluginManifestHeader.hasHeader(source)
            else {
                // A file that never claimed to be a plugin is skipped, exactly as
                // discovery skips it. One that used to claim it and no longer does is
                // retired instead — its header is how it asked to be loaded at all.
                guard let pluginID = pluginIDByDirectory[directoryName] else {
                    return
                }
                try await uninstallOperation(pluginID: pluginID)
                appendLog(
                    "host: uninstalled \(pluginID.rawValue) because its manifest header is gone"
                )
                return
            }
        }

        do {
            let (allPrepared, manifestFailures) = try await prepareAllManifests()
            // Reloading the broken plugin itself still reports its own manifest error,
            // rather than the misleading "directory missing" its absence would produce.
            if let failure = manifestFailures.first(
                where: { $0.directoryName == directoryName }
            ) {
                throw PluginHostError.manifestInvalid(
                    directory: failure.directoryName,
                    diagnostic: failure.diagnostic
                )
            }
            guard let prepared = allPrepared.first(where: {
                $0.record.directoryName == directoryName
            }) else {
                throw PluginHostError.pluginDirectoryMissing(directoryName)
            }
            try await installStaticContracts(from: [prepared])
            try await activate(
                [prepared],
                replacingManifestInventory: false
            )
            loadFailures.removeAll { $0.directoryName == directoryName }
            // A sibling that would not decode is still broken after this reload; keep
            // its diagnostic visible instead of letting an unrelated reload erase it.
            for failure in manifestFailures
            where !loadFailures.contains(where: {
                $0.directoryName == failure.directoryName
            }) {
                loadFailures.append(failure)
            }
            appendLog("host: reloaded \(prepared.record.manifest.id.rawValue)")
        } catch {
            recordLoadFailure(error, fallbackDirectory: directoryName)
            throw error
        }
    }

    /// Decodes every discovered manifest, and says which ones would not decode.
    ///
    /// A manifest failure in the **primary** inventory still throws: that inventory
    /// ships with the app or stands in for it, so an unreadable manifest there is a
    /// build error and hiding it would be worse than failing. A failure in any other
    /// inventory is recorded and skipped — plugins there are written by the user or by
    /// an agent working with them, and one of those must never stop Tenon or its other
    /// plugins from starting (invariant 4, which until now was only honoured on the
    /// hot-reload path).
    private func prepareAllManifests() async throws -> (
        plugins: [PreparedPlugin],
        failures: [PluginLoadFailure]
    ) {
        _ = try await coreCatalog.install()

        let discovery = try await Self.discoverManifests(in: inventories)
        var decoded = discovery.decoded.map {
            (directory: $0.directory, manifest: $0.manifest)
        }
        var failures = discovery.failures

        let admitted = admitByInventoryPrecedence(decoded)
        failures.append(contentsOf: admitted.failures)
        decoded = admitted.accepted
        try validatePluginIdentities(decoded)

        let catalogSnapshot = await kernel.catalog.snapshot
        let dispatcherSnapshot = await kernel.dispatcher.snapshot()
        let scratchCatalog = ContractCatalog()
        var result: [PreparedPlugin] = []
        result.reserveCapacity(decoded.count)

        for item in decoded {
            do {
                result.append(
                    try await prepare(
                        item,
                        against: catalogSnapshot,
                        dispatcherSnapshot: dispatcherSnapshot,
                        scratchCatalog: scratchCatalog
                    )
                )
            } catch {
                // Same rule as an undecodable manifest, for the rest of the ways a
                // plugin can be wrong — an intent it declares clashing with one already
                // owned, a `provides` entry naming no contract at all. Every one of them
                // is a plausible mistake in a plugin someone just wrote, and none of them
                // is a reason for Tenon to start with no plugins (invariant 4).
                let recoverableBundledFailure: Bool = {
                    guard item.manifest.runtime == .bundledSwift else { return false }
                    if let hostError = error as? PluginHostError,
                       case .bundledSwiftRuntimeRequiresBundledInventory = hostError
                    {
                        return true
                    }
                    return false
                }()
                guard !isPrimaryInventory(item.directory) || recoverableBundledFailure else {
                    throw error
                }
                failures.append(
                    PluginLoadFailure(
                        directoryName: item.directory.lastPathComponent,
                        diagnostic: Self.diagnostic(for: error)
                    )
                )
            }
        }

        return (
            plugins: result.sorted {
                $0.record.manifest.id.rawValue
                    < $1.record.manifest.id.rawValue
            },
            failures: failures.sorted {
                $0.directoryName < $1.directoryName
            }
        )
    }

    /// Directory enumeration and manifest decoding are filesystem work. Keep them out of
    /// the main-actor coordinator; only the resulting immutable values cross back for
    /// identity admission and contribution publication.
    @concurrent
    private static func discoverManifests(
        in inventories: [PluginInventory]
    ) async throws -> ManifestDiscovery {
        let directories = PluginLoader.discover(
            in: inventories.map(\.root)
        )
        var decoded: [DiscoveredManifest] = []
        var failures: [PluginLoadFailure] = []
        decoded.reserveCapacity(directories.count)

        for directory in directories {
            do {
                decoded.append(
                    DiscoveredManifest(
                        directory: directory,
                        manifest: try PluginLoader.loadManifest(at: directory)
                    )
                )
            } catch {
                let diagnostic = Self.diagnostic(for: error)
                let belongsToPrimary = PluginInventoryResolution.inventory(
                    for: directory,
                    in: inventories
                )?.root.standardizedFileURL.path
                    == inventories[0].root.standardizedFileURL.path
                guard !belongsToPrimary else {
                    throw PluginHostError.manifestInvalid(
                        directory: directory.lastPathComponent,
                        diagnostic: diagnostic
                    )
                }
                failures.append(
                    PluginLoadFailure(
                        directoryName: directory.lastPathComponent,
                        diagnostic: diagnostic
                    )
                )
            }
        }
        return ManifestDiscovery(decoded: decoded, failures: failures)
    }

    /// Everything one plugin must satisfy on its own before a runtime is built for it.
    ///
    /// `scratchCatalog` accumulates across the batch so two plugins cannot claim one
    /// contract. A plugin rejected part-way leaves its earlier declarations in there,
    /// which changes nothing: a declared contract must sit under its owner's id
    /// (`PluginIntentProvision.validate(owner:)`), and by here no two candidates share an
    /// id or an overlapping namespace, so nobody else can name them.
    private func prepare(
        _ item: (directory: URL, manifest: PluginManifest),
        against catalogSnapshot: ContractCatalogSnapshot,
        dispatcherSnapshot: IntentDispatcherSnapshot,
        scratchCatalog: ContractCatalog
    ) async throws -> PreparedPlugin {
        let inventory = PluginInventoryResolution.inventory(
            for: item.directory,
            in: inventories
        )
        if item.manifest.runtime == .bundledSwift,
           inventory?.authorization.inventoryTrust != .bundledStandingConsent
        {
            throw PluginHostError.bundledSwiftRuntimeRequiresBundledInventory(
                item.manifest.id
            )
        }

        var declarations: [IntentContractDeclaration] = []
        var rules: [IntentDispatchRule] = []
        var openReferences: Set<IntentID> = []

        for provision in item.manifest.intents.provides {
            if let declaration = try provision.declaration(
                owner: item.manifest.id
            ) {
                _ = try await scratchCatalog.register(declaration)
                let scratchSnapshot = await scratchCatalog.snapshot
                guard let candidate = scratchSnapshot.contract(
                    named: declaration.name
                ) else {
                    throw PluginHostError.contractConflict(
                        pluginID: item.manifest.id,
                        intentID: declaration.name
                    )
                }
                if let existing = catalogSnapshot.contract(
                    named: declaration.name
                ), existing != candidate {
                    throw PluginHostError.contractConflict(
                        pluginID: item.manifest.id,
                        intentID: declaration.name
                    )
                }

                let rule = try Self.pluginDispatchRule(
                    declaration: declaration,
                    providerID: ProviderID(item.manifest.id.rawValue)
                )
                if let existingRule = dispatcherSnapshot.rules[declaration.name],
                   existingRule != rule
                {
                    throw PluginHostError.dispatchRuleConflict(
                        pluginID: item.manifest.id,
                        intentID: declaration.name
                    )
                }
                declarations.append(declaration)
                rules.append(rule)
            } else {
                guard let contract = catalogSnapshot.contract(
                    named: provision.name
                ) else {
                    throw PluginHostError.unknownContractReference(
                        pluginID: item.manifest.id,
                        intentID: provision.name
                    )
                }
                guard contract.contractClass == .open,
                      contract.owner == .core
                else {
                    throw PluginHostError.nonOpenContractReference(
                        pluginID: item.manifest.id,
                        intentID: provision.name
                    )
                }
                openReferences.insert(provision.name)
            }
        }

        let disposition = try await installations.reconcileInventoryTrust(
            for: item.manifest.id,
            inventoryTrust: inventory?.authorization.inventoryTrust
                ?? .explicitEnablement,
            enablesNewPluginsByDefault: inventory?.enablesNewPluginsByDefault
                ?? false
        )
        return PreparedPlugin(
            record: ManifestRecord(
                directoryName: item.directory.lastPathComponent,
                directory: item.directory,
                manifest: item.manifest,
                isEnabled: disposition.isEnabled
            ),
            installation: disposition.installation,
            declarations: declarations.sorted {
                $0.name.rawValue < $1.name.rawValue
            },
            dispatchRules: rules.sorted {
                $0.intentID.rawValue < $1.intentID.rawValue
            },
            openIntentReferences: openReferences
        )
    }

    /// Resolves identity clashes between inventories by yielding to the earlier one,
    /// so a plugin the user wrote can lose a name without taking Tenon with it (T-062).
    ///
    /// Discovery is ordered by inventory, so "first claim wins" is exactly "the bundled
    /// inventory wins" — the rule `docs/design-automations.md` states. Only a plugin
    /// outside the primary inventory can be dropped this way; whatever survives goes to
    /// `validatePluginIdentities` untouched, where a surviving clash can only be
    /// primary-on-primary and still throws. That asymmetry is the point: the primary
    /// inventory ships with the app, so a clash there is a build error worth stopping
    /// for, while a clash in writable user content is Tuesday.
    ///
    /// A **directory name** is an identity here as much as a plugin id is: it keys hot
    /// reload, uninstall-on-delete, and every load failure, and two inventories can hold
    /// the same one. Left alone it built `pluginIDByDirectory` from duplicate keys and
    /// trapped the process — the loudest possible version of the incident this task
    /// exists to prevent.
    private func admitByInventoryPrecedence(
        _ decoded: [(directory: URL, manifest: PluginManifest)]
    ) -> (
        accepted: [(directory: URL, manifest: PluginManifest)],
        failures: [PluginLoadFailure]
    ) {
        var accepted: [(directory: URL, manifest: PluginManifest)] = []
        var failures: [PluginLoadFailure] = []
        var claimedIDs: [PluginID: String] = [:]
        var claimedDirectoryNames: Set<String> = []

        for item in decoded {
            let pluginID = item.manifest.id
            let directoryName = item.directory.lastPathComponent
            var refusal: String?

            if pluginID.rawValue == CoreIntentCatalog.trustedProviderIDRawValue
                || pluginID.rawValue.hasPrefix(
                    CoreIntentCatalog.trustedProviderIDRawValue + "."
                )
            {
                refusal = "plugin id \(pluginID.rawValue) is reserved for the host's own provider"
            } else if let owner = claimedIDs[pluginID] {
                refusal = "plugin id \(pluginID.rawValue) is already loaded from \(owner)"
            } else if claimedDirectoryNames.contains(directoryName) {
                refusal = "a plugin directory named \(directoryName) is already loaded "
                    + "from an earlier inventory; rename this one"
            } else if let overlapping = claimedIDs.keys.first(where: {
                pluginID.rawValue.hasPrefix($0.rawValue + ".")
                    || $0.rawValue.hasPrefix(pluginID.rawValue + ".")
            }) {
                refusal = "plugin id \(pluginID.rawValue) overlaps the namespace of "
                    + "\(overlapping.rawValue), which is already loaded"
            } else if let expected = pluginIDByDirectory[directoryName],
                      expected != pluginID
            {
                refusal = "directory \(directoryName) previously held "
                    + "\(expected.rawValue) and now declares \(pluginID.rawValue)"
            }

            if let refusal, !isPrimaryInventory(item.directory) {
                failures.append(
                    PluginLoadFailure(
                        directoryName: directoryName,
                        diagnostic: refusal
                    )
                )
                continue
            }

            accepted.append(item)
            claimedIDs[pluginID] = directoryName
            claimedDirectoryNames.insert(directoryName)
        }

        return (accepted, failures)
    }

    private func validatePluginIdentities(
        _ decoded: [(directory: URL, manifest: PluginManifest)]
    ) throws {
        var directoriesByID: [PluginID: [String]] = [:]
        for item in decoded {
            let pluginID = item.manifest.id
            let directoryName = item.directory.lastPathComponent
            directoriesByID[pluginID, default: []].append(directoryName)

            if pluginID.rawValue == CoreIntentCatalog.trustedProviderIDRawValue
                || pluginID.rawValue.hasPrefix(
                    CoreIntentCatalog.trustedProviderIDRawValue + "."
                )
            {
                throw PluginHostError.reservedPluginID(pluginID)
            }

            if let expected = pluginIDByDirectory[directoryName],
               expected != pluginID
            {
                throw PluginHostError.directoryIdentityChanged(
                    directory: directoryName,
                    expected: expected,
                    actual: pluginID
                )
            }
        }

        if let duplicate = directoriesByID.first(where: {
            $0.value.count > 1
        }) {
            throw PluginHostError.duplicatePluginID(
                pluginID: duplicate.key,
                directories: duplicate.value.sorted()
            )
        }

        let orderedIDs = directoriesByID.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for firstIndex in orderedIDs.indices {
            for secondIndex in orderedIDs.index(
                after: firstIndex
            ) ..< orderedIDs.endIndex {
                let first = orderedIDs[firstIndex]
                let second = orderedIDs[secondIndex]
                if second.rawValue.hasPrefix(first.rawValue + ".") {
                    throw PluginHostError.overlappingPluginNamespaces(
                        first: first,
                        second: second
                    )
                }
            }
        }
    }

    private func installStaticContracts(
        from prepared: [PreparedPlugin]
    ) async throws {
        for plugin in prepared {
            for declaration in plugin.declarations {
                try await kernel.catalog.register(declaration)
            }
        }
        for plugin in prepared {
            for rule in plugin.dispatchRules {
                try await kernel.dispatcher.registerRule(rule)
            }
        }
    }

    private func activate(
        _ prepared: [PreparedPlugin],
        replacingManifestInventory: Bool
    ) async throws {
        var candidates: [RuntimeCandidate] = []
        var candidateFailures: [(PreparedPlugin, any Error)] = []
        for plugin in prepared where plugin.record.isEnabled {
            do {
                try Task.checkCancellation()
                candidates.append(try await makeRuntimeCandidate(plugin))
            } catch is CancellationError {
                await discard(candidates)
                throw CancellationError()
            } catch {
                // A bad compiled implementation is one plugin's failure, not a reason to
                // discard otherwise valid candidates from the same inventory. The failure is
                // recorded after commit so the directory-to-plugin map is authoritative.
                candidateFailures.append((plugin, error))
            }
        }

        // A targeted reload is an atomic replacement of one live session. Unlike a
        // full inventory load, it must not commit the manifest or retire the active
        // session when its staged candidate fails.
        if !replacingManifestInventory, let (plugin, error) = candidateFailures.first {
            await discard(candidates)
            throw PluginHostError.runtimeFailed(
                pluginID: plugin.record.manifest.id,
                diagnostic: Self.diagnostic(for: error)
            )
        }

        var stagedProviderIndices: [Int] = []
        do {
            for index in candidates.indices {
                guard let generation = candidates[index].providerGeneration else {
                    continue
                }
                try await kernel.providerActivation.stagePlugin(
                    generation,
                    authorization: candidates[index].authorization
                )
                stagedProviderIndices.append(index)
            }
        } catch {
            for index in stagedProviderIndices {
                let candidate = candidates[index]
                try? await kernel.providerActivation.failStaging(
                    providerID: candidate.providerID,
                    generation: candidate.providerGeneration?.generation ?? 0,
                    diagnostic: Self.diagnostic(for: error)
                )
            }
            await discard(candidates)
            throw error
        }

        var activatedProviderIndices: Set<Int> = []
        do {
            for index in stagedProviderIndices {
                let candidate = candidates[index]
                guard let generation = candidate.providerGeneration else {
                    continue
                }
                try await kernel.providerActivation.activate(
                    providerID: candidate.providerID,
                    generation: generation.generation
                )
                registeredProviderIDs.insert(
                    candidate.prepared.record.manifest.id
                )
                activatedProviderIndices.insert(index)
            }
        } catch {
            for index in stagedProviderIndices
            where !activatedProviderIndices.contains(index) {
                let candidate = candidates[index]
                try? await kernel.providerActivation.failStaging(
                    providerID: candidate.providerID,
                    generation: candidate.providerGeneration?.generation ?? 0,
                    diagnostic: Self.diagnostic(for: error)
                )
            }
            await discard(
                candidates.enumerated().compactMap {
                    activatedProviderIndices.contains($0.offset)
                        ? nil
                        : $0.element
                }
            )
            let failedIndex = stagedProviderIndices.first {
                !activatedProviderIndices.contains($0)
            }
            let pluginID = failedIndex.map {
                candidates[$0].prepared.record.manifest.id
            } ?? candidates.first?.prepared.record.manifest.id
            if let pluginID {
                throw PluginHostError.providerActivationFailed(
                    pluginID: pluginID,
                    diagnostic: Self.diagnostic(for: error)
                )
            }
            throw error
        }

        try await commit(
            candidates: candidates,
            prepared: prepared,
            replacingManifestInventory: replacingManifestInventory
        )

        for (plugin, error) in candidateFailures {
            recordLoadFailure(
                PluginHostError.runtimeFailed(
                    pluginID: plugin.record.manifest.id,
                    diagnostic: Self.diagnostic(for: error)
                ),
                fallbackDirectory: plugin.record.directoryName
            )
        }
    }

    private func makeRuntimeCandidate(
        _ prepared: PreparedPlugin
    ) async throws -> RuntimeCandidate {
        let manifest = prepared.record.manifest
        let identity = try await installations.beginSession(
            for: manifest.id
        )
        installationKeys[manifest.id] = identity.installation

        let owner = IntentProviderOwner.plugin(
            id: manifest.id,
            installationID: identity.installationID
        )
        let principal = owner.principal(
            sessionRevision: identity.sessionRevision
        )
        var runtime: (any PluginHostRuntime)?

        do {
            let approvedOpenIntentIDs = try await authorization(
                forPluginAt: prepared.record.directory
            )
            .approvedOpenIntentIDs(identity.installation, manifest)
            guard approvedOpenIntentIDs.isSubset(
                of: prepared.openIntentReferences
            ) else {
                guard let invalid = approvedOpenIntentIDs.subtracting(
                    prepared.openIntentReferences
                ).sorted(by: {
                    $0.rawValue < $1.rawValue
                }).first else {
                    throw PluginHostError.providerActivationFailed(
                        pluginID: manifest.id,
                        diagnostic: "open-intent approval set is inconsistent"
                    )
                }
                throw PluginHostError.nonOpenContractReference(
                    pluginID: manifest.id,
                    intentID: invalid
                )
            }

            let declaredUses = Set(manifest.intents.uses).union(
                prepared.declarations.map(\.name)
            )
            try await kernel.policy.replaceDeclaredUses(
                declaredUses,
                for: principal
            )
            try await kernel.policy.replaceGrants(
                try Self.capabilityGrants(for: manifest),
                for: principal
            )

            let policyFingerprint = try Self.policyFingerprint(
                manifest: manifest,
                installation: identity.installation,
                approvedOpenIntentIDs: approvedOpenIntentIDs
            )
            let providerID = try ProviderID(manifest.id.rawValue)
            for intentID in approvedOpenIntentIDs {
                try await kernel.policy.recordProviderConsent(
                    .allow,
                    for: ProviderConsentKey(
                        contract: intentID,
                        providerID: providerID,
                        policyFingerprint: policyFingerprint
                    )
                )
            }

            // A plugin that shipped with the app was accepted when the user installed
            // Tenon; re-asking per call would be theatre. This is a seed through the same
            // API the confirmation dialog writes to, not a bypass — every invocation still
            // clears declared use, audience, capability, and scope. Re-seeding on each
            // activation keeps consent in step with the grants replaced just above.
            if await authorization(
                forPluginAt: prepared.record.directory
            ).grantsStandingConsent(
                identity.installation,
                manifest
            ) {
                let contracts = await kernel.catalog.snapshot
                for intentID in declaredUses {
                    // Only `.policy` consults standing consent. Seeding `.always` would
                    // record authority nothing reads and quietly weaken a mode whose whole
                    // point is asking every time; seeding an unknown contract would record
                    // it for something that may never exist.
                    guard let contract = contracts.contract(named: intentID),
                          contract.effects.confirmation == .policy
                    else {
                        continue
                    }
                    try await kernel.policy.grantStandingConsent(
                        contract: intentID,
                        caller: principal
                    )
                }
            }

            let settingValues = try await localSettingValues(
                manifest: manifest,
                installation: identity.installation
            )
            let storageValues = try await storage.values(
                for: identity.installation
            )
            let bridge = makeIntentBridge(
                principal: principal
            )
            let installation = identity.installation
            let storage = storage
            let configuration = PluginRuntimeConfiguration(
                manifest: manifest,
                directory: prepared.record.directory,
                intents: bridge,
                local: PluginRuntimeLocalState(
                    settings: settingValues,
                    storage: storageValues
                ),
                log: { [weak self] line in
                    await self?.appendLog(line)
                },
                persistStorage: { key, value in
                    try await storage.setValue(
                        value,
                        forKey: key,
                        installation: installation
                    )
                },
                onStateChange: { [weak self] snapshot in
                    await self?.accept(
                        snapshot,
                        identity: identity
                    )
                },
                publishEvent: { [weak self] local, payload in
                    await self?.publish(
                        local: local,
                        payload: payload,
                        from: manifest.id
                    )
                }
            )

            let createdRuntime = try await runtimeFactory.make(
                configuration
            )
            runtime = createdRuntime
            let startResult: PluginRuntimeStartResult
            do {
                startResult = try await createdRuntime.start()
            } catch {
                throw PluginHostError.runtimeFailed(
                    pluginID: manifest.id,
                    diagnostic: Self.diagnostic(for: error)
                )
            }

            let activationAuthorization =
                PluginProviderActivationAuthorization(
                    pluginID: manifest.id,
                    installationID: identity.installationID,
                    manifestProvidedIntentIDs: Set(
                        manifest.intents.provides.map(\.name)
                    ),
                    approvedOpenIntentIDs: approvedOpenIntentIDs
                )

            let providerGeneration: ProviderGenerationCandidate?
            if startResult.bindings.isEmpty {
                providerGeneration = nil
            } else {
                let generation = try await kernel.providerActivation
                    .nextGeneration(for: providerID)
                let mailbox = IntentMailbox(
                    limits: try IntentMailboxLimits()
                )
                let policy = kernel.policy
                providerGeneration = try ProviderGenerationCandidate(
                    providerID: providerID,
                    owner: owner,
                    principal: principal,
                    generation: generation,
                    bindings: startResult.bindings,
                    policyFingerprint: policyFingerprint,
                    mailbox: mailbox,
                    shutdown: { _ in
                        _ = await createdRuntime.shutdown(timeout: 2)
                        try? await policy.removePrincipal(principal)
                    }
                )
            }

            return RuntimeCandidate(
                prepared: prepared,
                identity: identity,
                principal: principal,
                runtime: createdRuntime,
                startResult: startResult,
                providerID: providerID,
                authorization: activationAuthorization,
                providerGeneration: providerGeneration
            )
        } catch {
            if let runtime {
                _ = await runtime.shutdown(timeout: 2)
            }
            try? await kernel.policy.removePrincipal(principal)
            throw error
        }
    }

    private func commit(
        candidates: [RuntimeCandidate],
        prepared: [PreparedPlugin],
        replacingManifestInventory: Bool
    ) async throws {
        let candidatePluginIDs = Set(
            candidates.map { $0.prepared.record.manifest.id }
        )

        for candidate in candidates {
            let pluginID = candidate.prepared.record.manifest.id
            if let previous = sessions[pluginID] {
                if candidate.providerGeneration != nil {
                    if !previous.hasProvider {
                        await shutdownRuntime(previous)
                    }
                } else if previous.hasProvider {
                    try await kernel.providerActivation.disable(
                        candidate.providerID
                    )
                    await shutdownRuntime(previous)
                } else {
                    await shutdownRuntime(previous)
                }
            }

            let latestSnapshot = await candidate.runtime.snapshot()
            sessions[pluginID] = ActiveSession(
                identity: candidate.identity,
                directoryName: candidate.prepared.record.directoryName,
                runtime: candidate.runtime,
                snapshot: latestSnapshot,
                hasProvider: candidate.providerGeneration != nil
            )
            installationKeys[pluginID] = candidate.identity.installation
            lastErrors[pluginID] = nil
            appendLog(
                "host: activated \(pluginID.rawValue) "
                    + "session \(candidate.identity.sessionRevision)"
            )
        }

        for plugin in prepared where !plugin.record.isEnabled {
            let pluginID = plugin.record.manifest.id
            guard let current = sessions[pluginID],
                  !candidatePluginIDs.contains(pluginID)
            else {
                continue
            }
            try await retire(
                current,
                pluginID: pluginID,
                disposition: .disabled
            )
            sessions[pluginID] = nil
        }

        if replacingManifestInventory {
            let discoveredIDs = Set(
                prepared.map { $0.record.manifest.id }
            )
            let removedIDs = Set(manifests.keys).subtracting(
                discoveredIDs
            )
            for pluginID in removedIDs {
                try await uninstallOperation(pluginID: pluginID)
            }

            manifests = Dictionary(
                uniqueKeysWithValues: prepared.map {
                    ($0.record.manifest.id, $0.record)
                }
            )
            pluginIDByDirectory = Dictionary(
                uniqueKeysWithValues: prepared.map {
                    ($0.record.directoryName, $0.record.manifest.id)
                }
            )
            for plugin in prepared {
                if let installation = plugin.installation {
                    installationKeys[plugin.record.manifest.id] = installation
                }
            }
        } else {
            for plugin in prepared {
                let pluginID = plugin.record.manifest.id
                if let old = manifests[pluginID],
                   old.directoryName != plugin.record.directoryName
                {
                    pluginIDByDirectory[old.directoryName] = nil
                }
                manifests[pluginID] = plugin.record
                pluginIDByDirectory[plugin.record.directoryName] = pluginID
                if let installation = plugin.installation {
                    installationKeys[pluginID] = installation
                }
            }
        }

        publish()
        if let lastWorkspaceCatalog {
            await reconcileViewInstances(from: lastWorkspaceCatalog)
        }
    }

    // MARK: - Settings and installation lifecycle  @domain: plugin-settings

    public func setSetting(
        _ value: IntentValue,
        forKey key: String,
        pluginID: PluginID
    ) async throws {
        try requireRunning()
        guard let record = manifests[pluginID] else {
            throw PluginHostError.pluginNotFound(pluginID)
        }
        guard let specification = record.manifest.settings.first(
            where: { $0.key == key }
        ) else {
            throw PluginHostError.settingNotDeclared(
                pluginID: pluginID,
                key: key
            )
        }
        guard Self.isValidSettingValue(value, for: specification) else {
            throw PluginHostError.invalidSettingValue(
                pluginID: pluginID,
                key: key
            )
        }
        let persistedInstallation = try await installations.installation(
            for: pluginID
        )
        guard let installation = installationKeys[pluginID]
            ?? persistedInstallation
        else {
            throw PluginHostError.installationMissing(pluginID)
        }

        try await settings.setValue(
            value,
            forKey: key,
            installation: installation
        )
        guard let session = sessions[pluginID] else {
            return
        }
        do {
            try await session.runtime.deliverEvent(
                event: "settings.changed",
                payload: .object([
                    "key": .string(key),
                    "value": value,
                ])
            )
        } catch {
            appendLog(
                "host: settings.changed failed for \(pluginID.rawValue): "
                    + Self.diagnostic(for: error)
            )
        }
    }

    public func settingValue(
        forKey key: String,
        pluginID: PluginID
    ) async throws -> IntentValue? {
        let persistedInstallation = try await installations.installation(
            for: pluginID
        )
        guard let installation = installationKeys[pluginID]
            ?? persistedInstallation
        else {
            throw PluginHostError.installationMissing(pluginID)
        }
        return try await settings.value(
            for: key,
            installation: installation
        )
    }

    public func setEnabled(
        _ enabled: Bool,
        pluginID: PluginID
    ) async throws {
        try await beginLifecycleOperation()
        defer {
            endLifecycleOperation()
        }
        guard var record = manifests[pluginID] else {
            throw PluginHostError.pluginNotFound(pluginID)
        }
        if record.isEnabled == enabled {
            if enabled, sessions[pluginID] == nil {
                try await reloadOperation(
                    directoryName: record.directoryName
                )
            }
            return
        }

        try await installations.setEnabled(
            enabled,
            for: pluginID
        )
        record.isEnabled = enabled
        manifests[pluginID] = record
        if let installation = try await installations.installation(
            for: pluginID
        ) {
            installationKeys[pluginID] = installation
        }

        if enabled {
            do {
                try await reloadOperation(
                    directoryName: record.directoryName
                )
            } catch {
                do {
                    try await installations.setEnabled(
                        false,
                        for: pluginID
                    )
                } catch {
                    appendLog(
                        "host: failed to restore disabled state for "
                            + "\(pluginID.rawValue): "
                            + Self.diagnostic(for: error)
                    )
                }
                record.isEnabled = false
                manifests[pluginID] = record
                publish()
                throw error
            }
        } else if let session = sessions[pluginID] {
            do {
                try await retire(
                    session,
                    pluginID: pluginID,
                    disposition: .disabled
                )
                if sessions[pluginID]?.identity == session.identity {
                    sessions[pluginID] = nil
                }
            } catch {
                do {
                    try await installations.setEnabled(
                        true,
                        for: pluginID
                    )
                } catch {
                    appendLog(
                        "host: failed to restore enabled state for "
                            + "\(pluginID.rawValue): "
                            + Self.diagnostic(for: error)
                    )
                }
                record.isEnabled = true
                manifests[pluginID] = record
                publish()
                throw error
            }
            appendLog("host: disabled \(pluginID.rawValue)")
            publish()
        } else {
            publish()
        }
    }

    /// Retires runtime/provider authority and removes durable installation-scoped state.
    ///
    /// Keychain values stay cryptographically isolated under the retired installation UUID;
    /// `SecretStore` intentionally exposes no unbounded namespace enumeration operation.
    public func uninstall(pluginID: PluginID) async throws {
        try await beginLifecycleOperation()
        defer {
            endLifecycleOperation()
        }
        try await uninstallOperation(pluginID: pluginID)
    }

    private func uninstallOperation(
        pluginID: PluginID
    ) async throws {
        let session = sessions[pluginID]
        if let session {
            try await retire(
                session,
                pluginID: pluginID,
                disposition: .uninstalled
            )
            if sessions[pluginID]?.identity == session.identity {
                sessions[pluginID] = nil
            }
        } else if registeredProviderIDs.contains(pluginID) {
            let providerID = try ProviderID(pluginID.rawValue)
            do {
                try await kernel.providerActivation.uninstall(providerID)
            } catch ProviderRegistryError.providerNotFound {
                // The current kernel has already forgotten this provider.
            }
        }
        registeredProviderIDs.remove(pluginID)
        publish()

        let persistedInstallation = try await installations.installation(
            for: pluginID
        )
        let installation = installationKeys[pluginID]
            ?? persistedInstallation
        if let installation {
            _ = try await settings.removeInstallation(installation)
            _ = try await storage.removeInstallation(installation)
        }
        _ = try await installations.removeInstallation(for: pluginID)
        installationKeys[pluginID] = nil

        if let record = manifests.removeValue(forKey: pluginID) {
            pluginIDByDirectory[record.directoryName] = nil
        }
        lastErrors[pluginID] = nil
        publish()
    }

    // MARK: - Contributions and events  @domain: plugin-contributions, plugin-events

    /// One keystroke of the palette query. Bumps the host-owned monotonic revision —
    /// instantly invalidating every in-flight answer — republishes sections (now
    /// pending), and fans the query fact out to provider generations without awaiting
    /// any of them. This is synchronous host state mutation: ranking the static list
    /// never waits on a plugin.
    public func setPaletteQuery(_ text: String) {
        paletteQueryRevision += 1
        let revision = paletteQueryRevision
        for session in sessions.values {
            let runtime = session.runtime
            Task {
                await runtime.deliverPaletteQuery(text: text, revision: revision)
            }
        }
        publish()
    }

    /// Closing the palette withdraws the question: the revision advances so every
    /// in-flight answer is stale on arrival, and no new query is delivered to anyone.
    public func invalidatePaletteQuery() {
        paletteQueryRevision += 1
        publish()
    }

    public func emit(
        event: String,
        payload: IntentValue
    ) async {
        let current = sessions
        for (pluginID, session) in current {
            guard PluginEventRouting.permits(
                event: event,
                manifest: session.snapshot.manifest
            ) else {
                continue
            }
            guard await session.runtime.handles(event: event) else {
                continue
            }
            guard session.runtime.acceptEvent(event: event, payload: payload) else {
                appendLog(
                    "host: event \(event) was refused by \(pluginID.rawValue)"
                )
                continue
            }
        }
    }

    /// Delivers an event to exactly one active plugin.
    ///
    /// Caller-owned resources such as browser surfaces must never use the broadcast
    /// channel: their URLs and titles belong to one installation. The app shell checks
    /// the installation identity before calling this method; the host then resolves the
    /// current session by its stable manifest ID.
    /// Returns whether a live, subscribed generation accepted the event for delivery. The
    /// outcome is host state (T-060's run history reads it); plugin-facing `publish`
    /// keeps ignoring it, so a publisher still never learns who listened (T-049).
    ///
    /// Acceptance is the honest answer available to a publisher: the observer's JavaScript runs
    /// on the observer's own thread, afterwards, in the order this generation accepted things.
    @discardableResult
    public func emit(
        event: String,
        payload: IntentValue,
        to pluginID: PluginID
    ) async -> Bool {
        guard let session = sessions[pluginID] else {
            return false
        }
        guard PluginEventRouting.permits(
            event: event,
            manifest: session.snapshot.manifest
        ) else {
            return false
        }
        guard await session.runtime.handles(event: event) else {
            return false
        }
        guard session.runtime.acceptEvent(event: event, payload: payload) else {
            appendLog(
                "host: event \(event) was refused by \(pluginID.rawValue)"
            )
            return false
        }
        return true
    }

    /// A plugin published a fact on one of its own channels (T-049).
    ///
    /// EVENT, fanned out to the plugins that declared the channel in `events.observes` and
    /// to nobody else. Two properties are worth stating because they are what keep this an
    /// event rather than a broadcast command:
    ///
    /// - **The publisher cannot name the channel.** Only the local half crosses from the
    ///   runtime; the owning prefix is added here, from the identity the host already holds.
    ///   So `automation.fired` and another plugin's channels are unreachable by
    ///   construction, not by a check that could be forgotten.
    /// - **The publisher never learns who listened.** There is no reply and no count. A
    ///   fact with nobody observing it is delivered nowhere and succeeds, which is what
    ///   makes a publisher independent of its consumers.
    ///
    /// Delivery goes through the same targeted `emit` every other event uses — one site,
    /// so a retired or disabled session drops silently there rather than needing a second
    /// rule here.
    public func publish(
        local: String,
        payload: IntentValue,
        from publisher: PluginID
    ) async {
        guard let session = sessions[publisher],
              PluginEventRouting.mayPublish(
                  local: local,
                  manifest: session.snapshot.manifest
              )
        else {
            return
        }
        let qualified = PluginEventManifest.qualified(
            local: local,
            owner: publisher
        )
        let observers = PluginEventRouting.observers(
            of: qualified,
            among: sessions.mapValues(\.snapshot.manifest)
        )
        for observerID in observers {
            await emit(event: qualified, payload: payload, to: observerID)
        }
    }

    /// A declared automation schedule came due (T-046).
    ///
    /// EVENT (boundary law step 2), delivered owner-scoped through the targeted
    /// channel: a schedule is the owning plugin's own manifest declaration, so its
    /// firing is never broadcast and needs no permission gate. A firing for a plugin
    /// whose session is gone (mid-retirement, disabled) drops silently in `emit`.
    @discardableResult
    public func automationFired(
        _ firing: AutomationScheduler.Firing
    ) async -> Bool {
        await emit(
            event: "automation.fired",
            payload: .object([
                "scheduleId": .string(firing.scheduleID),
                "scheduledFor": .string(
                    firing.scheduledFor.formatted(.iso8601)
                ),
                "late": .bool(firing.late),
                "trigger": .string(firing.trigger.rawValue),
            ]),
            to: firing.pluginID
        )
    }

    public func terminalTitleChanged(
        _ title: String,
        slotID: UUID? = nil
    ) async {
        var payload: [String: IntentValue] = [
            "title": .string(title),
        ]
        if let slotID {
            payload["slotId"] = .string(slotID.uuidString)
        }
        await emit(
            event: "terminal.title-changed",
            payload: .object(payload)
        )
    }

    /// A pane's directories changed: its shell moved, or a human pinned the pane's root.
    ///
    /// EVENT rather than INTENT (boundary law step 2): a fact that already happened on a
    /// host-owned channel whose producer — the surface — exists whether or not any plugin
    /// observes it. No reply, no deadline, no authorization decision.
    ///
    /// Named `pane.*` and NOT `terminal.*` deliberately: `emit` gates every `terminal.`
    /// event behind the `terminal.read` permission, and a plugin must not have to request
    /// permission to read terminal *contents* merely to learn which directory to show.
    /// A pane's directory is a pane fact, in the same class as the workspace paths already
    /// broadcast to every plugin through `workspace.selected`.
    public func paneCwdChanged(
        _ directory: ProjectRoot.PaneDirectory,
        slotID: UUID
    ) async {
        var payload: [String: IntentValue] = [
            "slotId": .string(slotID.uuidString),
            "cwd": .string(directory.cwd.path),
        ]
        if let root = directory.projectRoot {
            payload["projectRoot"] = .string(root.path)
        }
        await emit(
            event: "pane.cwd-changed",
            payload: .object(payload)
        )
    }

    @discardableResult
    public func invokeViewSelect(
        pluginID: PluginID,
        viewID: String,
        instanceID: String? = nil,
        itemID: String,
        value: IntentValue? = nil
    ) async -> Bool {
        guard let session = sessions[pluginID] else {
            appendLog("host: plugin \(pluginID.rawValue) is not active")
            return false
        }
        do {
            return try await session.runtime.invokeViewSelect(
                viewID: viewID,
                instanceID: instanceID,
                itemID: itemID,
                value: value
            )
        } catch {
            appendLog(
                "host: view action failed for \(pluginID.rawValue): "
                    + Self.diagnostic(for: error)
            )
            return false
        }
    }

    @discardableResult
    public func invokeViewSelect(
        pluginID: PluginID,
        viewID: String,
        instanceID: String? = nil,
        action: PluginNodeAction,
        value: IntentValue? = nil
    ) async -> Bool {
        guard let session = sessions[pluginID] else {
            appendLog("host: plugin \(pluginID.rawValue) is not active")
            return false
        }
        do {
            return try await session.runtime.invokeViewSelect(
                viewID: viewID,
                instanceID: instanceID,
                action: action,
                value: value
            )
        } catch {
            appendLog(
                "host: view action failed for \(pluginID.rawValue): "
                    + Self.diagnostic(for: error)
            )
            return false
        }
    }

    @discardableResult
    public func invokeViewSubmit(
        pluginID: PluginID,
        viewID: String,
        instanceID: String? = nil,
        itemID: String,
        text: String
    ) async -> Bool {
        guard let session = sessions[pluginID] else {
            appendLog("host: plugin \(pluginID.rawValue) is not active")
            return false
        }
        do {
            return try await session.runtime.invokeViewSubmit(
                viewID: viewID,
                instanceID: instanceID,
                itemID: itemID,
                text: text
            )
        } catch {
            appendLog(
                "host: view submission failed for \(pluginID.rawValue): "
                    + Self.diagnostic(for: error)
            )
            return false
        }
    }

    public func reconcileViewInstances(
        from catalog: WorkspaceCatalog
    ) async {
        lastWorkspaceCatalog = catalog
        needsViewReconcile = true
        guard !isReconcilingViews else {
            return
        }
        isReconcilingViews = true
        defer {
            isReconcilingViews = false
        }

        repeat {
            needsViewReconcile = false
            guard let latestCatalog = lastWorkspaceCatalog else {
                return
            }
            await performViewInstanceReconcile(from: latestCatalog)
        } while needsViewReconcile
    }

    private func performViewInstanceReconcile(
        from catalog: WorkspaceCatalog
    ) async {
        var desired: Set<ViewInstanceReference> = []
        for slot in catalog.pluginViewSlots {
            guard let session = sessions[slot.pluginID],
                  await session.runtime.isViewInstanced(slot.viewID)
            else {
                continue
            }
            desired.insert(
                ViewInstanceReference(
                    pluginID: slot.pluginID,
                    viewID: slot.viewID,
                    instanceID: slot.slotID.uuidString
                )
            )
        }

        var current: Set<ViewInstanceReference> = []
        for (pluginID, session) in sessions {
            current.formUnion(
                session.snapshot.openViewInstances.map {
                    ViewInstanceReference(
                        pluginID: pluginID,
                        viewID: $0.viewID,
                        instanceID: $0.instanceID
                    )
                }
            )
        }

        let closed = current.subtracting(desired).sorted(
            by: Self.sortViewReferences
        )
        let opened = desired.subtracting(current).sorted(
            by: Self.sortViewReferences
        )
        var changedPluginIDs: Set<PluginID> = []

        for reference in closed {
            guard let session = sessions[reference.pluginID] else {
                continue
            }
            do {
                try await session.runtime.closeViewInstance(
                    viewID: reference.viewID,
                    instanceID: reference.instanceID
                )
                changedPluginIDs.insert(reference.pluginID)
            } catch {
                appendLog(
                    "host: close view failed for "
                        + "\(reference.pluginID.rawValue): "
                        + Self.diagnostic(for: error)
                )
            }
        }
        for reference in opened {
            guard let session = sessions[reference.pluginID] else {
                continue
            }
            do {
                try await session.runtime.openViewInstance(
                    viewID: reference.viewID,
                    instanceID: reference.instanceID
                )
                changedPluginIDs.insert(reference.pluginID)
            } catch {
                appendLog(
                    "host: open view failed for "
                        + "\(reference.pluginID.rawValue): "
                        + Self.diagnostic(for: error)
                )
            }
        }

        for pluginID in changedPluginIDs {
            await refreshSnapshot(for: pluginID)
        }
        publish()
    }

    // MARK: - Watching and shutdown  @domain: plugin-host

    public func startWatching() throws {
        try requireRunning()
        guard watchers.isEmpty else {
            return
        }
        for inventory in inventories {
            startWatching(inventory.root)
        }
        appendLog(
            "host: watching "
                + inventories.map(\.root.path).joined(separator: ", ")
        )
    }

    private func startWatching(_ root: URL) {
        let watcher = PluginWatcher(
            root: root
        ) { [weak self] changedDirectories in
            guard let self else {
                return
            }
            let previous = self.watcherReloadTask
            self.watcherReloadTask = Task { @MainActor [weak self] in
                if let previous {
                    await previous.value
                }
                guard let self, !Task.isCancelled else {
                    return
                }
                for directoryName in changedDirectories.sorted() {
                    guard !Task.isCancelled else {
                        return
                    }
                    do {
                        try await self.reload(
                            directoryNamed: directoryName
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        self.appendLog(
                            "host: reload failed for \(directoryName): "
                                + Self.diagnostic(for: error)
                        )
                    }
                }
            }
        }
        watcher.start()
        watchers.append(watcher)
    }

    public func stopWatching() {
        watchers.forEach { $0.stop() }
        watchers = []
        watcherReloadTask?.cancel()
        watcherReloadTask = nil
    }

    /// Idempotent explicit teardown. Concurrent callers join the same task.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard lifecycle == .running else {
            return
        }

        lifecycle = .shuttingDown
        stopWatching()

        let task = Task { @MainActor [self] in
            await waitForLifecycleOperations()
            let activeSessions = Array(sessions.values)
            sessions.removeAll()
            publish()
            let activation = kernel.providerActivation
            let policy = kernel.policy

            for session in activeSessions {
                if session.hasProvider,
                   let providerID = try? ProviderID(
                       session.identity.pluginID.rawValue
                   )
                {
                    try? await activation.disable(providerID)
                }
                _ = await session.runtime.shutdown(timeout: 2)
                let owner = IntentProviderOwner.plugin(
                    id: session.identity.pluginID,
                    installationID: session.identity.installationID
                )
                try? await policy.removePrincipal(
                    owner.principal(
                        sessionRevision: session.identity.sessionRevision
                    )
                )
            }
            lifecycle = .stopped
        }
        shutdownTask = task
        await task.value
    }

    // MARK: - Diagnostics  @domain: plugin-host

    /// `TenonCore` cannot reach `TenonApp.TenonLog` (wrong import direction), so this is its
    /// own logger under the same subsystem — `log show`/Console filtering by
    /// `dev.tenon.app` still catches it. Before this, every line here (mailbox overflow, a
    /// failed callback handler, a rejected watcher/timer) lived only in the in-memory `log`
    /// array below, which nothing reads: T-182's "Plugin view unavailable" root cause
    /// (`compiled callback mailbox exceeded 256 entries`) was invisible on a real install —
    /// diagnosing it took a purpose-built test harness capturing this exact sink.
    private static let diagnosticsLogger = Logger(
        subsystem: "dev.tenon.app",
        category: "plugin-host"
    )

    public func appendLog(_ line: String) {
        log.append(line)
        if log.count > maxLogLines {
            log.removeFirst(log.count - maxLogLines)
        }
        Self.diagnosticsLogger.notice("\(line, privacy: .public)")
    }

    public func sessionIdentity(
        for pluginID: PluginID
    ) -> PluginSessionIdentity? {
        sessions[pluginID]?.identity
    }

    public func runtimeSnapshot(
        for pluginID: PluginID
    ) -> PluginRuntimeSnapshot? {
        sessions[pluginID]?.snapshot
    }

    public var loadedPluginIDs: [PluginID] {
        sessions.keys.sorted {
            $0.rawValue < $1.rawValue
        }
    }

    public func intentPresentation(
        for target: KeyBindingTarget
    ) -> PluginIntentPresentation? {
        intentPresentations.first {
            $0.pluginID == target.pluginID
                && $0.intentID == target.intentID
        }
    }
}

// MARK: - Private lifecycle helpers  @domain: plugin-host

private extension PluginHost {
    func makeIntentBridge(
        principal: IntentPrincipal
    ) -> PluginRuntimeIntentBridge {
        let dispatcher = kernel.dispatcher
        let scopeProvider = invocationScopeProvider
        return PluginRuntimeIntentBridge(
            send: { request in
                let inheritedScope = await scopeProvider()
                let scope = request.scopeOverride?.applying(to: inheritedScope)
                    ?? inheritedScope
                return await dispatcher.send(
                    IntentDispatchRequest(
                        intentID: request.intentID,
                        input: request.input,
                        caller: principal,
                        scope: scope,
                        target: request.target,
                        idempotencyKey: request.idempotencyKey,
                        requestedTimeout: request.requestedTimeout
                    )
                )
            },
            list: {
                let snapshot = await dispatcher.discover(
                    for: principal,
                    projection: .callable
                )
                return Self.intentDiscoveryValue(snapshot)
            }
        )
    }

    func localSettingValues(
        manifest: PluginManifest,
        installation: PluginInstallationKey
    ) async throws -> [String: IntentValue] {
        var result: [String: IntentValue] = [:]
        for specification in manifest.settings {
            if let defaultValue = specification.defaultValue {
                result[specification.key] = defaultValue.intentValue
            }
        }
        let overrides = try await settings.values(for: installation)
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    func accept(
        _ snapshot: PluginRuntimeSnapshot,
        identity: PluginSessionIdentity
    ) async {
        let pluginID = identity.pluginID
        guard var session = sessions[pluginID],
              session.identity == identity,
              snapshot.manifest.id == pluginID,
              snapshot.revision >= session.snapshot.revision
        else {
            return
        }
        if snapshot.phase == .failed {
            sessions[pluginID] = nil
            let diagnostic = "runtime entered failed phase"
            lastErrors[pluginID] = diagnostic
            appendLog(
                "host: \(pluginID.rawValue) failed: \(diagnostic)"
            )
            publish()

            // Returning from the state callback before runtime shutdown avoids
            // waiting for the state emitter from inside that same emitter.
            Task { @MainActor [self] in
                await retireFailedSession(
                    session,
                    pluginID: pluginID
                )
            }
            return
        }
        session.snapshot = snapshot
        sessions[pluginID] = session
        publish()
        if let lastWorkspaceCatalog {
            await reconcileViewInstances(from: lastWorkspaceCatalog)
        }
    }

    func refreshSnapshot(for pluginID: PluginID) async {
        guard var session = sessions[pluginID] else {
            return
        }
        let snapshot = await session.runtime.snapshot()
        guard sessions[pluginID]?.identity == session.identity else {
            return
        }
        session.snapshot = snapshot
        sessions[pluginID] = session
    }

    private func retire(
        _ session: ActiveSession,
        pluginID: PluginID,
        disposition: RetirementDisposition
    ) async throws {
        if session.hasProvider {
            let providerID = try ProviderID(pluginID.rawValue)
            switch disposition {
            case .disabled:
                try await kernel.providerActivation.disable(providerID)
            case .uninstalled:
                try await kernel.providerActivation.uninstall(providerID)
                registeredProviderIDs.remove(pluginID)
            }
        }
        await shutdownRuntime(session)

        // Disabling or uninstalling is the user withdrawing the plugin, so its standing
        // consent goes with it. Generation turnover during hot reload does not come
        // through here, which is why the live generation keeps the consent it just seeded.
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: session.identity.installationID
        )
        do {
            try await kernel.policy.revokeStandingConsents(
                for: owner.principal(
                    sessionRevision: session.identity.sessionRevision
                )
            )
        } catch {
            appendLog(
                "host: \(pluginID.rawValue) failed to revoke standing consent: "
                    + Self.diagnostic(for: error)
            )
        }
    }

    private func retireFailedSession(
        _ session: ActiveSession,
        pluginID: PluginID
    ) async {
        if session.hasProvider {
            do {
                try await kernel.providerActivation.disable(
                    try ProviderID(pluginID.rawValue)
                )
            } catch {
                appendLog(
                    "host: \(pluginID.rawValue) failed to disable provider: "
                        + Self.diagnostic(for: error)
                )
            }
        }

        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: session.identity.installationID
        )
        do {
            try await kernel.policy.removePrincipal(
                owner.principal(
                    sessionRevision: session.identity.sessionRevision
                )
            )
        } catch {
            appendLog(
                "host: \(pluginID.rawValue) failed to revoke principal: "
                    + Self.diagnostic(for: error)
            )
        }
        _ = await session.runtime.shutdown(timeout: 2)
    }

    private func shutdownRuntime(_ session: ActiveSession) async {
        _ = await session.runtime.shutdown(timeout: 2)
        let owner = IntentProviderOwner.plugin(
            id: session.identity.pluginID,
            installationID: session.identity.installationID
        )
        try? await kernel.policy.removePrincipal(
            owner.principal(
                sessionRevision: session.identity.sessionRevision
            )
        )
    }

    private func discard(_ candidates: [RuntimeCandidate]) async {
        for candidate in candidates {
            _ = await candidate.runtime.shutdown(timeout: 2)
            try? await kernel.policy.removePrincipal(
                candidate.principal
            )
        }
    }

    /// Admits lifecycle mutations in call order, then grants one mutation lease at a time.
    ///
    /// The fence is intentionally host-wide: manifest inventory, provider generations,
    /// durable enablement, and contribution publication form one coupled state machine.
    /// Parallel runtime execution remains unrestricted after activation.
    func beginLifecycleOperation() async throws {
        try requireRunning()
        activeLifecycleOperationCount += 1

        let waitResult: LifecycleMutationWaitResult
        if lifecycleMutationIsOwned {
            let waiterID = UUID()
            lifecycleMutationWaiterStates[waiterID] =
                .awaitingRegistration
            waitResult = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    registerLifecycleMutationWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelLifecycleMutationWaiter(id: waiterID)
                }
            }
        } else {
            lifecycleMutationIsOwned = true
            waitResult = .acquired
        }

        switch waitResult {
        case .cancelled:
            withdrawLifecycleOperation()
            throw CancellationError()

        case .acquired:
            break
        }

        if Task.isCancelled {
            endLifecycleOperation()
            throw CancellationError()
        }
    }

    func endLifecycleOperation() {
        precondition(
            activeLifecycleOperationCount > 0
                && lifecycleMutationIsOwned
        )
        activeLifecycleOperationCount -= 1
        if let next = popNextLifecycleMutationWaiter() {
            next.resume(returning: .acquired)
        } else {
            lifecycleMutationIsOwned = false
        }
        resumeLifecycleDrainIfIdle()
    }

    private func registerLifecycleMutationWaiter(
        id: UUID,
        continuation: CheckedContinuation<
            LifecycleMutationWaitResult,
            Never
        >
    ) {
        guard let state = lifecycleMutationWaiterStates[id] else {
            continuation.resume(returning: .cancelled)
            return
        }

        switch state {
        case .awaitingRegistration:
            if Task.isCancelled {
                lifecycleMutationWaiterStates[id] = nil
                continuation.resume(returning: .cancelled)
            } else {
                lifecycleMutationWaiterStates[id] = .queued(
                    continuation
                )
                lifecycleMutationWaiterOrder.append(id)
            }

        case .cancelledBeforeRegistration:
            lifecycleMutationWaiterStates[id] = nil
            continuation.resume(returning: .cancelled)

        case .queued:
            preconditionFailure(
                "lifecycle mutation waiter registered twice"
            )
        }
    }

    func cancelLifecycleMutationWaiter(id: UUID) {
        guard let state = lifecycleMutationWaiterStates[id] else {
            return
        }

        switch state {
        case .awaitingRegistration:
            lifecycleMutationWaiterStates[id] =
                .cancelledBeforeRegistration

        case .cancelledBeforeRegistration:
            return

        case let .queued(continuation):
            guard let index = lifecycleMutationWaiterOrder.firstIndex(
                of: id
            ) else {
                preconditionFailure(
                    "queued lifecycle mutation waiter has no FIFO entry"
                )
            }
            lifecycleMutationWaiterOrder.remove(at: index)
            lifecycleMutationWaiterStates[id] = nil
            continuation.resume(returning: .cancelled)
        }
    }

    private func popNextLifecycleMutationWaiter() -> CheckedContinuation<
        LifecycleMutationWaitResult,
        Never
    >? {
        while !lifecycleMutationWaiterOrder.isEmpty {
            let id = lifecycleMutationWaiterOrder.removeFirst()
            guard let state = lifecycleMutationWaiterStates
                .removeValue(forKey: id)
            else {
                continue
            }
            guard case let .queued(continuation) = state else {
                preconditionFailure(
                    "non-queued lifecycle mutation waiter entered FIFO"
                )
            }
            return continuation
        }
        return nil
    }

    func withdrawLifecycleOperation() {
        precondition(activeLifecycleOperationCount > 0)
        activeLifecycleOperationCount -= 1
        resumeLifecycleDrainIfIdle()
    }

    func resumeLifecycleDrainIfIdle() {
        guard activeLifecycleOperationCount == 0 else {
            return
        }
        precondition(
            lifecycleMutationWaiterOrder.isEmpty
                && lifecycleMutationWaiterStates.isEmpty
                && !lifecycleMutationIsOwned
        )
        let waiters = lifecycleDrainWaiters
        lifecycleDrainWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForLifecycleOperations() async {
        guard activeLifecycleOperationCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleDrainWaiters.append(continuation)
        }
    }

    func requireRunning() throws {
        guard lifecycle == .running else {
            throw PluginHostError.stopped
        }
    }

    func recordLoadFailure(
        _ error: any Error,
        fallbackDirectory: String? = nil
    ) {
        let failure: PluginLoadFailure
        switch error {
        case let PluginHostError.manifestInvalid(directory, diagnostic):
            failure = PluginLoadFailure(
                directoryName: directory,
                diagnostic: diagnostic
            )
        case let PluginHostError.duplicatePluginID(_, directories):
            failure = PluginLoadFailure(
                directoryName: directories.first ?? fallbackDirectory ?? "plugins",
                diagnostic: Self.diagnostic(for: error)
            )
        case let PluginHostError.directoryIdentityChanged(
            directory,
            _,
            _
        ):
            failure = PluginLoadFailure(
                directoryName: directory,
                diagnostic: Self.diagnostic(for: error)
            )
        default:
            failure = PluginLoadFailure(
                directoryName: fallbackDirectory ?? "plugins",
                diagnostic: Self.diagnostic(for: error)
            )
        }
        loadFailures.removeAll {
            $0.directoryName == failure.directoryName
        }
        loadFailures.append(failure)
        loadFailures.sort {
            $0.directoryName < $1.directoryName
        }

        if let pluginID = pluginIDByDirectory[failure.directoryName] {
            lastErrors[pluginID] = failure.diagnostic
        }
        appendLog(
            "host: \(failure.directoryName) failed: \(failure.diagnostic)"
        )
        publish()
    }

    func publish() {
        let orderedSessions = sessions.sorted {
            $0.key.rawValue < $1.key.rawValue
        }

        // What the live generations put on screen is one projection over their snapshots,
        // and it is computed by `PluginContributionProjection` rather than here: the host's job
        // in this method is to decide the order, then publish what comes back.
        let contributions = PluginContributionProjection.make(
            orderedSnapshots: orderedSessions.map { ($0.key, $0.value.snapshot) },
            paletteQueryRevision: paletteQueryRevision
        )
        let nextKeyBindingIndex = contributions.keyBindingIndex

        let newKeyBindingDiagnostics =
            nextKeyBindingIndex.diagnostics.filter {
                !publishedKeyBindingDiagnostics.contains($0)
            }

        let nextPlugins = manifests.values.map { record in
            let pluginID = record.manifest.id
            let session = sessions[pluginID]
            return PluginSnapshot(
                id: pluginID,
                installationID: session?.identity.installationID
                    ?? installationKeys[pluginID]?.installationID,
                name: record.manifest.name,
                version: record.manifest.version,
                permissions: record.manifest.permissions,
                unknownPermissions: record.manifest.unknownPermissions,
                settingSpecs: record.manifest.settings,
                icon: record.manifest.icon,
                displayName: record.manifest.displayName,
                isLoaded: session?.snapshot.phase == .active,
                isEnabled: record.isEnabled,
                permissionViolations: session?.snapshot.permissionViolations
                    ?? [],
                error: lastErrors[pluginID],
                automationSchedules: record.manifest.automation?.schedules
                    ?? []
            )
        }.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let lifecycleChanged = nextPlugins != plugins

        statusItems = contributions.statusItems
        pluginViews = contributions.views
        intentPresentations = contributions.intentPresentations
        keyBindingIndex = contributions.keyBindingIndex
        commandIndex = contributions.commandIndex
        paletteSections = contributions.paletteSections
        plugins = nextPlugins
        publishedKeyBindingDiagnostics = Set(
            nextKeyBindingIndex.diagnostics
        )
        for diagnostic in newKeyBindingDiagnostics {
            appendLog(Self.keyBindingDiagnostic(diagnostic))
        }
        if lifecycleChanged {
            onPluginLifecycleChanged?(plugins)
        }
    }


    private static func keyBindingDiagnostic(
        _ diagnostic: KeyBindingDiagnostic
    ) -> String {
        switch diagnostic {
        case .invalid(let request, let error):
            return "keybinding: \(request.target.pluginID.rawValue)."
                + "\(request.target.intentID.rawValue) rejected "
                + "\(request.rawKey): \(keyChordParseError(error))"
        case .reserved(let request, let chord):
            return "keybinding: \(request.target.pluginID.rawValue)."
                + "\(request.target.intentID.rawValue) rejected "
                + "\(chord.display): reserved by shell"
        case .conflict(let request, let winner, let chord):
            return "keybinding: \(request.target.pluginID.rawValue)."
                + "\(request.target.intentID.rawValue) rejected "
                + "\(chord.display): assigned to "
                + "\(winner.pluginID.rawValue).\(winner.intentID.rawValue)"
        }
    }

    private static func keyChordParseError(
        _ error: KeyChord.ParseError
    ) -> String {
        switch error {
        case .empty:
            return "empty key"
        case .modifierOnly:
            return "modifier-only key"
        case .multipleKeys(let keys):
            return "multiple keys \(keys.joined(separator: ", "))"
        case .duplicateModifier(let modifier):
            return "duplicate modifier \(modifier)"
        case .unknownToken(let token):
            return "unknown token \(token)"
        case .barePrintable(let key):
            return "bare printable key \(key)"
        case .invalidFunctionKey(let key):
            return "invalid function key \(key)"
        }
    }
}
