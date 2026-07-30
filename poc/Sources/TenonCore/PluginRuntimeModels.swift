import Foundation
import TenonIntentCore

/// Closed compile-time allowlist for same-installation local facilities.
///
/// Adding a case is an architecture change: the facility must remain
/// installation-scoped, single-provider, non-routable, non-discoverable,
/// capability-free, bounded, and tied to the plugin runtime lifecycle.
public enum PluginScopedFacility: String, Sendable, CaseIterable {
    case settings = "tenon.settings"
    case storage = "tenon.storage"
    case log = "tenon.log"
}

/// One entry of a declarative row's native context menu.
public struct RowMenuItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let destructive: Bool
    public let separatorBefore: Bool

    public init(
        id: String,
        label: String,
        destructive: Bool = false,
        separatorBefore: Bool = false
    ) {
        self.id = id
        self.label = label
        self.destructive = destructive
        self.separatorBefore = separatorBefore
    }
}

/// One row in a plugin's declarative row/tree contribution.
public struct PluginRowItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let depth: Int
    public let icon: String?
    public let expanded: Bool?
    public let menu: [RowMenuItem]
    public let editing: Bool
    public let placeholder: String?
    public let selected: Bool
    public let path: String?

    public init(
        id: String,
        label: String,
        depth: Int,
        icon: String?,
        expanded: Bool? = nil,
        menu: [RowMenuItem] = [],
        editing: Bool = false,
        placeholder: String? = nil,
        selected: Bool = false,
        path: String? = nil
    ) {
        self.id = id
        self.label = label
        self.depth = depth
        self.icon = icon
        self.expanded = expanded
        self.menu = menu
        self.editing = editing
        self.placeholder = placeholder
        self.selected = selected
        self.path = path
    }
}

/// A native action in a plugin view's header strip.
public struct ViewAction: Sendable, Equatable, Identifiable {
    public let id: String
    public let icon: String
    public let tooltip: String?

    public init(id: String, icon: String, tooltip: String? = nil) {
        self.id = id
        self.icon = icon
        self.tooltip = tooltip
    }
}

/// One immutable view contribution visible to the host.
public struct PluginViewInfo: Sendable, Equatable, Identifiable {
    public let viewID: String
    public let instanceID: String?
    public let instanced: Bool
    public let title: String
    public let subtitle: String?
    public let actions: [ViewAction]
    public let items: [PluginRowItem]
    public let body: PluginViewNode?

    public var id: String {
        instanceID.map { "\(viewID)#\($0)" } ?? viewID
    }

    public init(
        viewID: String,
        instanceID: String?,
        instanced: Bool,
        title: String,
        subtitle: String?,
        actions: [ViewAction],
        items: [PluginRowItem],
        body: PluginViewNode?
    ) {
        self.viewID = viewID
        self.instanceID = instanceID
        self.instanced = instanced
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.items = items
        self.body = body
    }
}

/// The only caller-controlled fields accepted by the JavaScript intent adapter.
///
/// Identity and causal fields deliberately do not appear here. The host binds the plugin
/// principal for top-level sends; nested sends are minted from `IntentProviderContext`.
public struct PluginIntentSendRequest: Sendable, Equatable {
    public let intentID: IntentID
    public let input: IntentValue
    public let target: ProviderID?
    public let idempotencyKey: String?
    public let requestedTimeout: Duration?
    public let scopeOverride: InvocationScopeOverride?

    public init(
        intentID: IntentID,
        input: IntentValue,
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil,
        scopeOverride: InvocationScopeOverride? = nil
    ) {
        self.intentID = intentID
        self.input = input
        self.target = target
        self.idempotencyKey = idempotencyKey
        self.requestedTimeout = requestedTimeout
        self.scopeOverride = scopeOverride
    }
}

/// Host-owned intent entry points for ordinary plugin calls and policy-filtered discovery.
public struct PluginRuntimeIntentBridge: Sendable {
    public typealias Send = @Sendable (PluginIntentSendRequest) async -> IntentResult
    public typealias List = @Sendable () async -> IntentValue

    public let send: Send
    public let list: List

    public init(
        send: @escaping Send,
        list: @escaping List
    ) {
        self.send = send
        self.list = list
    }
}

/// Owned local values injected before JavaScript staging starts.
public struct PluginRuntimeLocalState: Sendable, Equatable {
    public let settings: [String: IntentValue]
    public let storage: [String: IntentValue]

    public init(
        settings: [String: IntentValue] = [:],
        storage: [String: IntentValue] = [:]
    ) {
        self.settings = settings
        self.storage = storage
    }
}

/// Runtime dependencies. Every closure crosses isolation with owned `Sendable` values.
public struct PluginRuntimeConfiguration: Sendable {
    public typealias Log = @Sendable (String) async -> Void
    public typealias PersistStorage = @Sendable (String, IntentValue) async throws -> Void
    public typealias StateChange = @Sendable (PluginRuntimeSnapshot) async -> Void

    public let manifest: PluginManifest
    public let directory: URL
    public let intents: PluginRuntimeIntentBridge
    public let local: PluginRuntimeLocalState
    public let log: Log
    public let persistStorage: PersistStorage
    public let onStateChange: StateChange
    public let startupTimeout: TimeInterval

    public init(
        manifest: PluginManifest,
        directory: URL,
        intents: PluginRuntimeIntentBridge,
        local: PluginRuntimeLocalState = PluginRuntimeLocalState(),
        log: @escaping Log = { _ in },
        persistStorage: @escaping PersistStorage = { _, _ in },
        onStateChange: @escaping StateChange = { _ in },
        startupTimeout: TimeInterval = 2
    ) {
        self.manifest = manifest
        self.directory = directory
        self.intents = intents
        self.local = local
        self.log = log
        self.persistStorage = persistStorage
        self.onStateChange = onStateChange
        self.startupTimeout = startupTimeout
    }
}

public enum PluginRuntimePhase: String, Sendable, Equatable {
    case initialized
    case staging
    case active
    case stopping
    case stopped
    case failed
}

/// Host-facing runtime state. It contains no JavaScriptCore or Foundation resource object.
public struct PluginRuntimeSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let manifest: PluginManifest
    public let phase: PluginRuntimePhase
    public let statusBarText: String?
    public let views: [PluginViewInfo]
    public let openViewInstances: [PluginViewInstanceKey]
    public let permissionViolations: [String]
    public let runtimeThreadIdentifier: UInt64?
    public let pendingNestedIntentCount: Int
    public let lateProviderReplyCount: Int

    public init(
        revision: UInt64,
        manifest: PluginManifest,
        phase: PluginRuntimePhase,
        statusBarText: String?,
        views: [PluginViewInfo],
        openViewInstances: [PluginViewInstanceKey],
        permissionViolations: [String],
        runtimeThreadIdentifier: UInt64?,
        pendingNestedIntentCount: Int,
        lateProviderReplyCount: Int
    ) {
        self.revision = revision
        self.manifest = manifest
        self.phase = phase
        self.statusBarText = statusBarText
        self.views = views
        self.openViewInstances = openViewInstances
        self.permissionViolations = permissionViolations
        self.runtimeThreadIdentifier = runtimeThreadIdentifier
        self.pendingNestedIntentCount = pendingNestedIntentCount
        self.lateProviderReplyCount = lateProviderReplyCount
    }
}

public struct PluginViewInstanceKey: Sendable, Equatable, Hashable {
    public let viewID: String
    public let instanceID: String

    public init(viewID: String, instanceID: String) {
        self.viewID = viewID
        self.instanceID = instanceID
    }
}

public struct PluginRuntimeStartResult: Sendable {
    public let bindings: [IntentProviderBinding]
    public let snapshot: PluginRuntimeSnapshot

    public init(bindings: [IntentProviderBinding], snapshot: PluginRuntimeSnapshot) {
        self.bindings = bindings
        self.snapshot = snapshot
    }
}

public struct PluginRuntimeShutdownReport: Sendable, Equatable {
    public let executorResult: PinnedThreadExecutor.ShutdownResult
    public let createdThreadIdentifier: UInt64?
    public let destroyedThreadIdentifier: UInt64?
    public let cancelledProviderCalls: Int
    public let lateProviderReplyCount: Int

    public init(
        executorResult: PinnedThreadExecutor.ShutdownResult,
        createdThreadIdentifier: UInt64?,
        destroyedThreadIdentifier: UInt64?,
        cancelledProviderCalls: Int,
        lateProviderReplyCount: Int
    ) {
        self.executorResult = executorResult
        self.createdThreadIdentifier = createdThreadIdentifier
        self.destroyedThreadIdentifier = destroyedThreadIdentifier
        self.cancelledProviderCalls = cancelledProviderCalls
        self.lateProviderReplyCount = lateProviderReplyCount
    }
}

public enum PluginRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidLifecycle(expected: PluginRuntimePhase, actual: PluginRuntimePhase)
    case javascriptContextUnavailable
    case javascriptException(String)
    case bridgeProtocolViolation(String)
    case undeclaredIntentHandler(IntentID)
    case missingIntentHandlers([IntentID])
    case duplicateIntentHandler(IntentID)
    case runtimeStopped
    case providerHandlerUnavailable(IntentID)
    case providerHandlerFailed(String)
    case invalidProviderReply
    case resourceLimitExceeded(String)

    public var description: String {
        switch self {
        case let .invalidLifecycle(expected, actual):
            "runtime lifecycle expected \(expected.rawValue), got \(actual.rawValue)"
        case .javascriptContextUnavailable:
            "could not create the JavaScriptCore context"
        case let .javascriptException(message):
            "JavaScript exception: \(message)"
        case let .bridgeProtocolViolation(message):
            "JavaScript bridge protocol violation: \(message)"
        case let .undeclaredIntentHandler(intentID):
            "handler for undeclared intent \(intentID.rawValue)"
        case let .missingIntentHandlers(intentIDs):
            "missing handlers: \(intentIDs.map(\.rawValue).sorted().joined(separator: ", "))"
        case let .duplicateIntentHandler(intentID):
            "duplicate handler for \(intentID.rawValue)"
        case .runtimeStopped:
            "plugin runtime is stopped"
        case let .providerHandlerUnavailable(intentID):
            "provider handler unavailable for \(intentID.rawValue)"
        case let .providerHandlerFailed(message):
            "provider handler failed: \(message)"
        case .invalidProviderReply:
            "provider returned an invalid reply"
        case let .resourceLimitExceeded(resource):
            "runtime resource limit exceeded: \(resource)"
        }
    }
}
