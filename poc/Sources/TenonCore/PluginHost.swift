import Foundation
import Observation
import TenonIntentCore

/// Static and runtime state for one verified plugin installation.
public struct PluginSnapshot: Sendable, Equatable, Identifiable {
    public let id: PluginID
    public let installationID: UUID?
    public let name: String
    public let version: String
    public let permissions: [String]
    public let unknownPermissions: [String]
    public let settingSpecs: [PluginSettingSpec]
    public let icon: String?
    public let displayName: String?
    public let isLoaded: Bool
    public let isEnabled: Bool
    public let permissionViolations: [String]
    public let error: String?
    /// Manifest-declared automation schedules (T-046). Part of the Equatable lifecycle
    /// snapshot on purpose: a reload that changes a schedule fires
    /// `onPluginLifecycleChanged`, which is the scheduler's reconcile trigger.
    public let automationSchedules: [AutomationScheduleSpec]

    public init(
        id: PluginID,
        installationID: UUID?,
        name: String,
        version: String,
        permissions: [String],
        unknownPermissions: [String],
        settingSpecs: [PluginSettingSpec],
        icon: String?,
        displayName: String?,
        isLoaded: Bool,
        isEnabled: Bool,
        permissionViolations: [String],
        error: String?,
        automationSchedules: [AutomationScheduleSpec] = []
    ) {
        self.id = id
        self.installationID = installationID
        self.name = name
        self.version = version
        self.permissions = permissions
        self.unknownPermissions = unknownPermissions
        self.settingSpecs = settingSpecs
        self.icon = icon
        self.displayName = displayName
        self.isLoaded = isLoaded
        self.isEnabled = isEnabled
        self.permissionViolations = permissionViolations
        self.error = error
        self.automationSchedules = automationSchedules
    }

    public var settingsTitle: String {
        displayName ?? name
    }
}

/// A manifest or lifecycle failure that cannot be assigned a valid plugin identity.
public struct PluginLoadFailure: Sendable, Equatable, Identifiable {
    public let directoryName: String
    public let diagnostic: String

    public var id: String {
        directoryName
    }

    public init(directoryName: String, diagnostic: String) {
        self.directoryName = directoryName
        self.diagnostic = diagnostic
    }
}

/// A status-bar contribution from one immutable plugin identity.
public struct StatusItem: Sendable, Equatable, Identifiable {
    public let pluginID: PluginID
    public let text: String

    public var id: PluginID {
        pluginID
    }
}

/// One plugin-contributed native view.
public struct PluginViewSection: Sendable, Equatable, Identifiable {
    public let pluginID: PluginID
    public let viewID: String
    public let instanceID: String?
    public let instanced: Bool
    public let title: String
    public let subtitle: String?
    public let actions: [ViewAction]
    public let items: [PluginRowItem]
    public let body: PluginViewNode?

    public var id: String {
        instanceID.map {
            "\(pluginID.rawValue).\(viewID)#\($0)"
        } ?? "\(pluginID.rawValue).\(viewID)"
    }
}

/// Static palette metadata projected from a manifest-backed intent declaration.
///
/// Invocation stays on the shared dispatcher; this value is only a presentation read model.
public struct PluginIntentPresentation: Sendable, Equatable, Identifiable {
    public let pluginID: PluginID
    public let intentID: IntentID
    public let title: String
    public let description: String?
    public let category: String?
    public let icon: String?
    public let keywords: [String]
    public let key: String?
    public let when: String?
    public let launcher: Bool

    public var id: IntentID {
        intentID
    }
}

public enum PluginHostError: Error, Sendable, Equatable, CustomStringConvertible {
    case stopped
    case manifestInvalid(directory: String, diagnostic: String)
    case duplicatePluginID(pluginID: PluginID, directories: [String])
    case overlappingPluginNamespaces(first: PluginID, second: PluginID)
    case reservedPluginID(PluginID)
    case directoryIdentityChanged(
        directory: String,
        expected: PluginID,
        actual: PluginID
    )
    case unknownContractReference(pluginID: PluginID, intentID: IntentID)
    case nonOpenContractReference(pluginID: PluginID, intentID: IntentID)
    case contractConflict(pluginID: PluginID, intentID: IntentID)
    case dispatchRuleConflict(pluginID: PluginID, intentID: IntentID)
    case pluginNotFound(PluginID)
    case pluginDirectoryMissing(String)
    case installationMissing(PluginID)
    case settingNotDeclared(pluginID: PluginID, key: String)
    case invalidSettingValue(pluginID: PluginID, key: String)
    case runtimeFailed(pluginID: PluginID, diagnostic: String)
    case providerActivationFailed(pluginID: PluginID, diagnostic: String)

    public var description: String {
        switch self {
        case .stopped:
            "plugin host has stopped"
        case let .manifestInvalid(directory, diagnostic):
            "plugin manifest in \(directory) is invalid: \(diagnostic)"
        case let .duplicatePluginID(pluginID, directories):
            "plugin ID \(pluginID.rawValue) is duplicated by \(directories.joined(separator: ", "))"
        case let .overlappingPluginNamespaces(first, second):
            "plugin namespaces overlap: \(first.rawValue) and \(second.rawValue)"
        case let .reservedPluginID(pluginID):
            "plugin ID \(pluginID.rawValue) is reserved for the core provider"
        case let .directoryIdentityChanged(directory, expected, actual):
            "plugin directory \(directory) changed identity from "
                + "\(expected.rawValue) to \(actual.rawValue)"
        case let .unknownContractReference(pluginID, intentID):
            "\(pluginID.rawValue) references unknown intent \(intentID.rawValue)"
        case let .nonOpenContractReference(pluginID, intentID):
            "\(pluginID.rawValue) cannot provide non-open core intent \(intentID.rawValue)"
        case let .contractConflict(pluginID, intentID):
            "\(pluginID.rawValue) conflicts with canonical contract \(intentID.rawValue)"
        case let .dispatchRuleConflict(pluginID, intentID):
            "\(pluginID.rawValue) conflicts with canonical dispatch rule \(intentID.rawValue)"
        case let .pluginNotFound(pluginID):
            "plugin \(pluginID.rawValue) was not discovered"
        case let .pluginDirectoryMissing(directory):
            "plugin directory \(directory) is unavailable"
        case let .installationMissing(pluginID):
            "plugin \(pluginID.rawValue) has no installation identity"
        case let .settingNotDeclared(pluginID, key):
            "plugin \(pluginID.rawValue) does not declare setting \(key)"
        case let .invalidSettingValue(pluginID, key):
            "setting \(key) for \(pluginID.rawValue) has the wrong value type"
        case let .runtimeFailed(pluginID, diagnostic):
            "plugin runtime \(pluginID.rawValue) failed: \(diagnostic)"
        case let .providerActivationFailed(pluginID, diagnostic):
            "plugin provider \(pluginID.rawValue) failed activation: \(diagnostic)"
        }
    }
}

/// Host-owned authorization decisions that cannot come from a plugin manifest.
public struct PluginHostAuthorization: Sendable {
    public typealias OpenIntentApprovals = @Sendable (
        PluginInstallationKey,
        PluginManifest
    ) async throws -> Set<IntentID>

    /// Whether this installation's declared intents carry standing consent without asking.
    ///
    /// True for plugins that shipped with the app: installing Tenon is the acceptance, and
    /// a first launch has nothing left to prompt about. The decision is host-owned on
    /// purpose — were it a manifest field, any plugin could declare itself bundled.
    public typealias StandingConsentDecision = @Sendable (
        PluginInstallationKey,
        PluginManifest
    ) async -> Bool

    /// For a plugin inventory the host itself controls — the app bundle, or the developer
    /// root standing in for it. Everything inside shipped with the app, so the user
    /// accepted it by installing Tenon. A user-installed plugin directory must never be
    /// authorized through this value.
    public static let bundledInventory = PluginHostAuthorization(
        approvedOpenIntentIDs: { _, _ in [] },
        grantsStandingConsent: { _, _ in true }
    )

    let approvedOpenIntentIDs: OpenIntentApprovals
    let grantsStandingConsent: StandingConsentDecision

    /// Standing consent defaults to `false` while `.bundledInventory` is `true`: a caller
    /// that forgets to decide gets prompts, never silent authority.
    public init(
        approvedOpenIntentIDs: @escaping OpenIntentApprovals,
        grantsStandingConsent: @escaping StandingConsentDecision = { _, _ in false }
    ) {
        self.approvedOpenIntentIDs = approvedOpenIntentIDs
        self.grantsStandingConsent = grantsStandingConsent
    }
}

protocol PluginHostRuntime: AnyObject, Sendable {
    var manifest: PluginManifest { get }
    var directory: URL { get }

    func start() async throws -> PluginRuntimeStartResult
    func snapshot() async -> PluginRuntimeSnapshot
    func handles(event: String) async -> Bool
    func isViewInstanced(_ viewID: String) async -> Bool
    func emit(event: String, payload: IntentValue) async throws
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        itemID: String,
        value: IntentValue?
    ) async throws -> Bool
    func invokeViewSubmit(
        viewID: String,
        instanceID: String?,
        itemID: String,
        text: String
    ) async throws -> Bool
    func openViewInstance(viewID: String, instanceID: String) async throws
    func closeViewInstance(viewID: String, instanceID: String) async throws
    func deliverPaletteQuery(text: String, revision: Int) async
    func shutdown(timeout: TimeInterval) async -> PluginRuntimeShutdownReport
}

extension PluginRuntime: PluginHostRuntime {}

struct PluginHostRuntimeFactory: Sendable {
    typealias Make = @Sendable (
        PluginRuntimeConfiguration
    ) async throws -> any PluginHostRuntime

    static let live = PluginHostRuntimeFactory { configuration in
        // Runtime construction waits for a dedicated pinned thread to start. It owns no UI
        // state, so this work must not occupy MainActor during app launch or reload.
        try await Task.detached(priority: .userInitiated) {
            try PluginRuntime(configuration: configuration)
        }.value
    }

    let make: Make

    init(make: @escaping Make) {
        self.make = make
    }
}

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

    @ObservationIgnored
    public let pluginsRoot: URL

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

    @ObservationIgnored
    private let authorization: PluginHostAuthorization

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
    private var watcher: PluginWatcher?

    @ObservationIgnored
    private var watcherReloadTask: Task<Void, Never>?

    @ObservationIgnored
    private var lastWorkspaceCatalog: WorkspaceCatalog?

    @ObservationIgnored
    private var isReconcilingViews = false

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

    private struct ViewInstanceReference: Sendable, Hashable {
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

    init(
        pluginsRoot: URL,
        stateRoot: URL,
        kernel: IntentKernelComponents,
        authorization: PluginHostAuthorization,
        invocationScopeProvider: @escaping InvocationScopeProvider,
        runtimeFactory: PluginHostRuntimeFactory
    ) throws {
        self.pluginsRoot = pluginsRoot
        self.stateRoot = stateRoot
        self.kernel = kernel
        self.authorization = authorization
        self.invocationScopeProvider = invocationScopeProvider
        self.runtimeFactory = runtimeFactory
        installations = try PluginInstallationStore(pluginsRoot: stateRoot)
        settings = try SettingsStore(pluginsRoot: stateRoot)
        storage = try PluginStorage(pluginsRoot: stateRoot)
        secrets = try SecretStore()
        coreCatalog = CoreIntentCatalog(components: kernel)
    }

    // MARK: - Loading and hot reload

    /// Validates the complete manifest batch before constructing any runtime, then starts
    /// every enabled candidate before publishing any provider generation.
    public func loadAll() async throws {
        try await beginLifecycleOperation()
        defer {
            endLifecycleOperation()
        }
        do {
            let prepared = try await prepareAllManifests()
            try await installStaticContracts(from: prepared)
            try await activate(
                prepared,
                replacingManifestInventory: true
            )
            loadFailures = []
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

        let directory = pluginsRoot.appendingPathComponent(directoryName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            guard let pluginID = pluginIDByDirectory[directoryName] else {
                return
            }
            try await uninstallOperation(pluginID: pluginID)
            appendLog(
                "host: uninstalled \(pluginID.rawValue) because its directory disappeared"
            )
            return
        }

        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("manifest.json").path
        ) else {
            let error = PluginHostError.manifestInvalid(
                directory: directoryName,
                diagnostic: "manifest.json is missing"
            )
            recordLoadFailure(error)
            throw error
        }

        do {
            let allPrepared = try await prepareAllManifests()
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
            appendLog("host: reloaded \(prepared.record.manifest.id.rawValue)")
        } catch {
            recordLoadFailure(error, fallbackDirectory: directoryName)
            throw error
        }
    }

    private func prepareAllManifests() async throws -> [PreparedPlugin] {
        _ = try await coreCatalog.install()

        let directories = PluginLoader.discover(in: pluginsRoot)
        var decoded: [(directory: URL, manifest: PluginManifest)] = []
        decoded.reserveCapacity(directories.count)
        for directory in directories {
            do {
                decoded.append(
                    (
                        directory,
                        try PluginLoader.loadManifest(at: directory)
                    )
                )
            } catch {
                throw PluginHostError.manifestInvalid(
                    directory: directory.lastPathComponent,
                    diagnostic: Self.diagnostic(for: error)
                )
            }
        }

        try validatePluginIdentities(decoded)

        let catalogSnapshot = await kernel.catalog.snapshot
        let dispatcherSnapshot = await kernel.dispatcher.snapshot()
        let scratchCatalog = ContractCatalog()
        var result: [PreparedPlugin] = []
        result.reserveCapacity(decoded.count)

        for item in decoded {
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

            let isEnabled = try await installations.isEnabled(
                for: item.manifest.id
            )
            let installation = try await installations.installation(
                for: item.manifest.id
            )
            result.append(
                PreparedPlugin(
                    record: ManifestRecord(
                        directoryName: item.directory.lastPathComponent,
                        directory: item.directory,
                        manifest: item.manifest,
                        isEnabled: isEnabled
                    ),
                    installation: installation,
                    declarations: declarations.sorted {
                        $0.name.rawValue < $1.name.rawValue
                    },
                    dispatchRules: rules.sorted {
                        $0.intentID.rawValue < $1.intentID.rawValue
                    },
                    openIntentReferences: openReferences
                )
            )
        }

        return result.sorted {
            $0.record.manifest.id.rawValue
                < $1.record.manifest.id.rawValue
        }
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
        do {
            for plugin in prepared where plugin.record.isEnabled {
                try Task.checkCancellation()
                candidates.append(try await makeRuntimeCandidate(plugin))
            }
        } catch {
            await discard(candidates)
            throw error
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
            let approvedOpenIntentIDs = try await authorization
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
            if await authorization.grantsStandingConsent(
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

    // MARK: - Settings and installation lifecycle

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
            try await session.runtime.emit(
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

    // MARK: - Contributions and events

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
            if event.hasPrefix("terminal."),
               !session.snapshot.manifest.permissions.contains(
                   "terminal.read"
               )
            {
                continue
            }
            guard await session.runtime.handles(event: event) else {
                continue
            }
            do {
                try await session.runtime.emit(
                    event: event,
                    payload: payload
                )
            } catch {
                appendLog(
                    "host: event \(event) failed for \(pluginID.rawValue): "
                        + Self.diagnostic(for: error)
                )
            }
        }
    }

    /// Delivers an event to exactly one active plugin.
    ///
    /// Caller-owned resources such as browser surfaces must never use the broadcast
    /// channel: their URLs and titles belong to one installation. The app shell checks
    /// the installation identity before calling this method; the host then resolves the
    /// current session by its stable manifest ID.
    /// Returns whether a live, subscribed generation actually took the event. The
    /// outcome is host state (T-060's run history reads it); plugin-facing `publish`
    /// keeps ignoring it, so a publisher still never learns who listened (T-049).
    @discardableResult
    public func emit(
        event: String,
        payload: IntentValue,
        to pluginID: PluginID
    ) async -> Bool {
        guard let session = sessions[pluginID] else {
            return false
        }
        if event.hasPrefix("terminal."),
           !session.snapshot.manifest.permissions.contains("terminal.read")
        {
            return false
        }
        guard await session.runtime.handles(event: event) else {
            return false
        }
        do {
            try await session.runtime.emit(
                event: event,
                payload: payload
            )
        } catch {
            appendLog(
                "host: event \(event) failed for \(pluginID.rawValue): "
                    + Self.diagnostic(for: error)
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
              session.snapshot.manifest.events?.publishes.contains(local) == true
        else {
            return
        }
        let qualified = PluginEventManifest.qualified(
            local: local,
            owner: publisher
        )
        for (observerID, observer) in sessions
        where observer.snapshot.manifest.events?.observes.contains(qualified) == true {
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
            "pinned": .bool(directory.source == .pinned),
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
        guard !isReconcilingViews else {
            return
        }
        isReconcilingViews = true
        defer {
            isReconcilingViews = false
        }

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

    // MARK: - Watching and shutdown

    public func startWatching() throws {
        try requireRunning()
        guard watcher == nil else {
            return
        }
        let watcher = PluginWatcher(
            root: pluginsRoot
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
        self.watcher = watcher
        appendLog("host: watching \(pluginsRoot.path)")
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
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

    // MARK: - Diagnostics

    public func appendLog(_ line: String) {
        log.append(line)
        if log.count > maxLogLines {
            log.removeFirst(log.count - maxLogLines)
        }
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

// MARK: - Private lifecycle helpers

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

        let nextStatusItems = orderedSessions.compactMap {
            pluginID,
            session in
            session.snapshot.statusBarText.map {
                StatusItem(pluginID: pluginID, text: $0)
            }
        }
        let nextPluginViews = orderedSessions.flatMap {
            pluginID,
            session in
            session.snapshot.views.map {
                PluginViewSection(
                    pluginID: pluginID,
                    viewID: $0.viewID,
                    instanceID: $0.instanceID,
                    instanced: $0.instanced,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    actions: $0.actions,
                    items: $0.items,
                    body: $0.body
                )
            }
        }
        let nextIntentPresentations = orderedSessions.flatMap {
            pluginID,
            session in
            Self.presentations(
                for: session.snapshot.manifest,
                pluginID: pluginID
            )
        }
        // Provider sections rebuild only from live sessions: a retired generation's
        // contributions vanish here, and `accept`'s identity guard already dropped its
        // late snapshots. Results are shown only when they answer the *current* query
        // revision; anything older renders as the provider's pending row instead.
        let currentPaletteRevision = paletteQueryRevision
        let nextPaletteSections = orderedSessions.flatMap {
            pluginID,
            session in
            session.snapshot.paletteProviders.map { provider in
                let isCurrent = provider.publishedRevision == currentPaletteRevision
                    && currentPaletteRevision > 0
                return PaletteProviderSection(
                    pluginID: pluginID,
                    providerID: provider.providerID,
                    title: provider.title,
                    isPending: !isCurrent && currentPaletteRevision > 0,
                    results: isCurrent ? provider.results : []
                )
            }
        }
        let keyBindingRequests = nextIntentPresentations.compactMap {
            presentation -> KeyBindingRequest? in
            guard let key = presentation.key else {
                return nil
            }
            return KeyBindingRequest(
                target: KeyBindingTarget(
                    pluginID: presentation.pluginID,
                    intentID: presentation.intentID
                ),
                rawKey: key
            )
        }
        let nextKeyBindingIndex = KeyBindingIndex(
            requests: keyBindingRequests,
            reserved: KeyBindingIndex.shellReserved
        )
        let nextCommandIndex = CommandIndex(
            nextIntentPresentations.map { presentation in
                let target = KeyBindingTarget(
                    pluginID: presentation.pluginID,
                    intentID: presentation.intentID
                )
                return presentation.command(
                    assignedKey: nextKeyBindingIndex.binding(
                        for: target
                    )?.chord
                )
            }
        )
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

        statusItems = nextStatusItems
        pluginViews = nextPluginViews
        intentPresentations = nextIntentPresentations
        keyBindingIndex = nextKeyBindingIndex
        commandIndex = nextCommandIndex
        paletteSections = nextPaletteSections
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

    static func presentations(
        for manifest: PluginManifest,
        pluginID: PluginID
    ) -> [PluginIntentPresentation] {
        manifest.intents.provides.compactMap { provision in
            guard let palette = provision.palette,
                  let title = provision.title
            else {
                return nil
            }
            return PluginIntentPresentation(
                pluginID: pluginID,
                intentID: provision.name,
                title: title,
                description: provision.description,
                category: palette.category
                    ?? manifest.displayName
                    ?? manifest.name,
                icon: palette.icon,
                keywords: palette.keywords,
                key: palette.key,
                when: palette.when,
                launcher: palette.launcher
            )
        }.sorted {
            $0.intentID.rawValue < $1.intentID.rawValue
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

// MARK: - Pure policy and projection helpers

extension PluginHost {
    nonisolated static func pluginDispatchRule(
        declaration: IntentContractDeclaration,
        providerID: ProviderID
    ) throws -> IntentDispatchRule {
        return try IntentDispatchRule(
            intentID: declaration.name,
            capabilityBindings: [],
            exposure: IntentExposure(
                discoverableBy: declaration.audiences,
                invocableBy: declaration.audiences
            ),
            trustedDefault: providerID,
            allowsAutomaticSelection: true,
            providerConsent: .never,
            admissionClass: declaration.audiences.contains(.palette)
                ? .interactive
                : .background,
            valueLimits: .default,
            maximumTimeout: .seconds(30)
        )
    }

    nonisolated static func capabilityGrants(
        for manifest: PluginManifest
    ) throws -> Set<CapabilityGrant> {
        // `terminal.read` used to be excluded here, and that was right when it existed
        // only to gate delivery of `terminal.*` EVENTs — a permission with no capability
        // behind it. It has since been bound as the capability for the three terminal read
        // intents (`CoreIntentCatalog.swift`: viewport read, scrollback read, wait), and
        // the exclusion was never revisited, so every one of them was ungrantable: a plugin
        // could declare the permission and the use, pass every other check, and still be
        // refused with `missing-capability`. Nothing is loosened by granting it — the event
        // gate reads `manifest.permissions` directly and is untouched, and a caller still
        // needs both the declared permission and the declared use.
        let capabilityPermissions = Set(
            manifest.permissions.filter(PluginManifest.knownPermissions.contains)
        )
        let networkPatterns = try Set(
            manifest.networkAllowlist.map(NetworkHostPattern.init)
        )

        return try Set(
            capabilityPermissions.map { permission in
                let filesystem: FilesystemGrantScope = [
                    "filesystem.read",
                    "filesystem.write",
                    "process.exec",
                    "shell.open",
                ].contains(permission) ? .all : .none
                let network: NetworkGrantScope
                switch permission {
                case "network":
                    network = .hosts(networkPatterns)
                case "web.view":
                    // A visible browser pane is an explicit all-network authority: the
                    // user can see its address and navigate links/redirects. Background
                    // `network.fetch` remains constrained to the manifest allowlist.
                    network = .all
                default:
                    network = .none
                }
                return CapabilityGrant(
                    capability: try CapabilityID(permission),
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: filesystem,
                        network: network
                    )
                )
            }
        )
    }

    nonisolated static func policyFingerprint(
        manifest: PluginManifest,
        installation: PluginInstallationKey,
        approvedOpenIntentIDs: Set<IntentID>
    ) throws -> PolicyFingerprint {
        try PolicyFingerprint(
            canonicalPolicy: .object([
                "pluginID": .string(manifest.id.rawValue),
                "installationID": .string(
                    installation.installationID.uuidString.lowercased()
                ),
                "permissions": .array(
                    manifest.permissions.sorted().map(IntentValue.string)
                ),
                "networkAllow": .array(
                    manifest.networkAllowlist.sorted().map(
                        IntentValue.string
                    )
                ),
                "provides": .array(
                    manifest.intents.provides.map(\.name.rawValue)
                        .sorted().map(IntentValue.string)
                ),
                "approvedOpenIntents": .array(
                    approvedOpenIntentIDs.map(\.rawValue)
                        .sorted().map(IntentValue.string)
                ),
            ])
        )
    }

    nonisolated static func isValidSettingValue(
        _ value: IntentValue,
        for specification: PluginSettingSpec
    ) -> Bool {
        switch (specification.type, value) {
        case (.string, .string), (.boolean, .bool),
             (.number, .number), (.number, .integer):
            return true
        case let (.select, .string(selected)):
            return specification.options?.contains {
                $0.value == selected
            } == true
        default:
            return false
        }
    }

    nonisolated static func intentDiscoveryValue(
        _ snapshot: IntentDiscoverySnapshot
    ) -> IntentValue {
        .object([
            "revision": .object([
                "catalog": .integer(Int64(snapshot.revision.catalog)),
                "rules": .integer(Int64(snapshot.revision.rules)),
                "policy": .integer(
                    Int64(snapshot.revision.policy.rawValue)
                ),
                "providers": .string(
                    Self.encodedProviderRevision(
                        snapshot.revision.providers
                    )
                ),
                "session": .integer(
                    Int64(snapshot.revision.principal.sessionRevision)
                ),
            ]),
            "items": .array(
                snapshot.items.map { item in
                    .object([
                        "name": .string(item.name.rawValue),
                        "title": item.title.map(IntentValue.string)
                            ?? .null,
                        "description": item.description.map(
                            IntentValue.string
                        ) ?? .null,
                        "deprecated": .bool(item.deprecated),
                        "inputSchema": item.inputSchema,
                        "outputSchema": item.outputSchema,
                        "providers": .array(
                            item.activeProviders.map {
                                .string($0.rawValue)
                            }
                        ),
                    ])
                }
            ),
        ])
    }

    private nonisolated static func sortViewReferences(
        _ lhs: ViewInstanceReference,
        _ rhs: ViewInstanceReference
    ) -> Bool {
        (
            lhs.pluginID.rawValue,
            lhs.viewID,
            lhs.instanceID
        ) < (
            rhs.pluginID.rawValue,
            rhs.viewID,
            rhs.instanceID
        )
    }

    nonisolated static func diagnostic(for error: any Error) -> String {
        return String(describing: error)
    }

    nonisolated static func encodedProviderRevision(
        _ revision: ProviderRegistryRevision
    ) -> String {
        guard let data = try? JSONEncoder().encode(revision),
              let value = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return value
    }
}
