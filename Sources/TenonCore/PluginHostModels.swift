// @domain: plugin-host, plugin-contributions, intent-bus
//
// The vocabulary `PluginHost` coordinates in: what an installation looks like from outside,
// what a live generation may put on screen, how its intents are presented, what can go wrong,
// what the host will vouch for, and the runtime boundary it drives. These are values and one
// protocol — no coordination happens here, which is why they read on their own.
import Foundation
import Observation
import TenonIntentCore

// MARK: - Installation snapshots  @domain: plugin-host

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

// MARK: - Contribution projections  @domain: plugin-contributions

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
    /// What this view puts in its pane's ONE chrome header. Rebuilt from live sessions with
    /// the rest of the section, so a retired generation leaves no chrome behind.
    public let header: PaneHeader
    public let items: [TreeRowItem]
    public let body: PluginViewNode?
    /// Set while this view wants a modal over the whole shell; nil otherwise.
    public let modal: PluginViewModal?

    public var id: String {
        instanceID.map {
            "\(pluginID.rawValue).\(viewID)#\($0)"
        } ?? "\(pluginID.rawValue).\(viewID)"
    }

    public init(
        pluginID: PluginID,
        viewID: String,
        instanceID: String?,
        instanced: Bool,
        title: String,
        items: [TreeRowItem],
        body: PluginViewNode?,
        header: PaneHeader = .empty,
        modal: PluginViewModal? = nil
    ) {
        self.pluginID = pluginID
        self.viewID = viewID
        self.instanceID = instanceID
        self.instanced = instanced
        self.title = title
        self.header = header
        self.items = items
        self.body = body
        self.modal = modal
    }
}

// MARK: - Intent presentation projection  @domain: intent-bus, plugin-contributions

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
    public let fillsPane: Bool

    public var id: IntentID {
        intentID
    }
}

// MARK: - Host errors  @domain: plugin-host

public enum PluginHostError: Error, Sendable, Equatable, CustomStringConvertible {
    case stopped
    case noInventoryConfigured
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
    case bundledSwiftRuntimeRequiresBundledInventory(PluginID)
    case runtimeFailed(pluginID: PluginID, diagnostic: String)
    case providerActivationFailed(pluginID: PluginID, diagnostic: String)

    public var description: String {
        switch self {
        case .stopped:
            "plugin host has stopped"
        case .noInventoryConfigured:
            "the plugin host needs at least one inventory to load from"
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
        case let .bundledSwiftRuntimeRequiresBundledInventory(pluginID):
            "plugin \(pluginID.rawValue) requests bundled Swift code from an untrusted inventory"
        case let .runtimeFailed(pluginID, diagnostic):
            "plugin runtime \(pluginID.rawValue) failed: \(diagnostic)"
        case let .providerActivationFailed(pluginID, diagnostic):
            "plugin provider \(pluginID.rawValue) failed activation: \(diagnostic)"
        }
    }
}

// MARK: - Host-owned authorization  @domain: plugin-host, intent-bus

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
        grantsStandingConsent: { _, _ in true },
        inventoryTrust: .bundledStandingConsent
    )

    let approvedOpenIntentIDs: OpenIntentApprovals
    let grantsStandingConsent: StandingConsentDecision
    let inventoryTrust: PluginInventoryTrust

    /// Standing consent defaults to `false` while `.bundledInventory` is `true`: a caller
    /// that forgets to decide gets prompts, never silent authority.
    public init(
        approvedOpenIntentIDs: @escaping OpenIntentApprovals,
        grantsStandingConsent: @escaping StandingConsentDecision = { _, _ in false },
        inventoryTrust: PluginInventoryTrust = .explicitEnablement
    ) {
        self.approvedOpenIntentIDs = approvedOpenIntentIDs
        self.grantsStandingConsent = grantsStandingConsent
        self.inventoryTrust = inventoryTrust
    }
}

// MARK: - Runtime boundary  @domain: plugin-host

package protocol PluginHostRuntime: AnyObject, Sendable {
    var manifest: PluginManifest { get }
    var directory: URL { get }

    func start() async throws -> PluginRuntimeStartResult
    func snapshot() async -> PluginRuntimeSnapshot
    func handles(event: String) async -> Bool
    func isViewInstanced(_ viewID: String) async -> Bool
    /// Takes a fact for delivery without waiting for the generation's JavaScript to run it.
    /// `false` means this generation cannot take it: retiring, failed, or over its queue depth.
    func acceptEvent(event: String, payload: IntentValue) -> Bool
    /// Delivers a host-owned fact into this generation without consulting its subscription
    /// table — the channel is one the host addresses directly, such as `settings.changed`,
    /// whose owned local values the runtime refreshes before the plugin's handler observes it.
    ///
    /// This is delivery, host → plugin. A plugin publishing a fact of its own travels the
    /// opposite way, through the runtime's own plugin-facing surface and out to
    /// `PluginRuntimeConfiguration.publishEvent`; the two never share a name.
    func deliverEvent(event: String, payload: IntentValue) async throws
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        itemID: String,
        value: IntentValue?
    ) async throws -> Bool
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        action: PluginNodeAction,
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

extension PluginHostRuntime {
    /// Compatibility for callers whose select has no menu payload. The structured route
    /// remains the protocol requirement; a missing menu value is simply nil.
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        itemID: String
    ) async throws -> Bool {
        try await invokeViewSelect(
            viewID: viewID,
            instanceID: instanceID,
            itemID: itemID,
            value: nil
        )
    }

    /// Compatibility for test doubles and runtimes that only implement the historic string
    /// route. Real runtimes override this to preserve structured action values.
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        action: PluginNodeAction,
        value: IntentValue?
    ) async throws -> Bool {
        guard let itemID = action.stringValue else { return false }
        return try await invokeViewSelect(
            viewID: viewID,
            instanceID: instanceID,
            itemID: itemID,
            value: value
        )
    }
}

extension PluginRuntime: PluginHostRuntime {}

package struct PluginHostRuntimeFactory: Sendable {
    package typealias Make = @Sendable (
        PluginRuntimeConfiguration
    ) async throws -> any PluginHostRuntime

    package static let live = PluginHostRuntimeFactory { configuration in
        // Runtime construction waits for a dedicated pinned thread to start. It owns no UI
        // state, so this work must not occupy MainActor during app launch or reload.
        try await Task.detached(priority: .userInitiated) {
            try PluginRuntime(configuration: configuration)
        }.value
    }

    package let make: Make

    package init(make: @escaping Make) {
        self.make = make
    }
}

extension PluginIntentPresentation {
    /// The palette-visible provisions of one manifest, in a stable order.
    ///
    /// It lives with the type it produces rather than on the coordinator that happened to call
    /// it: what a plugin's declared intent looks like in a palette is a property of the
    /// declaration, not of the host's publish cycle.
    static func projected(
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
                launcher: palette.launcher,
                fillsPane: palette.fillsPane
            )
        }.sorted {
            $0.intentID.rawValue < $1.intentID.rawValue
        }
    }
}
