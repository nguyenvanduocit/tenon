// @domain: plugin-host
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

/// What a row says at its trailing edge: one short token, tinted.
///
/// A status letter, a count, a unit — the thing a scanning eye reads down the right-hand
/// column without reading the labels. Bounded to a few characters because that column is
/// fixed-width by construction: a row that wants a sentence there wants `detail` instead,
/// which truncates, or a body view rather than a row list.
public struct RowAccessory: Sendable, Equatable {
    /// The longest an accessory may be. Four characters holds `M`, `??`, `+12` and `9.9k`;
    /// past that the accessory stops being a glance and starts squeezing the label.
    public static let maximumTextLength = 4

    public let text: String
    public let tint: ColorToken

    /// Returns nil for text that is empty or over the bound, so a malformed accessory costs
    /// its own column rather than the row it is attached to.
    public init?(text: String, tint: ColorToken = .default) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumTextLength else { return nil }
        self.text = trimmed
        self.tint = tint
    }
}

/// One row in a declarative row/tree contribution — the single vocabulary every indented
/// list in the product is drawn from, whether a plugin published it or a host-native pane
/// built it in Swift.
///
/// The name is deliberately about the SHAPE and not about who published it: the Changes pane
/// builds these in `TenonApp` and renders them through the same view a plugin's tree goes
/// through, and a reader who met a plugin-owned name here would go looking for a plugin that
/// does not exist. What keeps the boundary safe is not the name — it is that this is a
/// bounded value either side can mint, and that a plugin's rows reach it only through the
/// decoder, never as a native type crossing into JavaScript (invariants 2 and 6).
public struct TreeRowItem: Sendable, Equatable, Identifiable {
    /// Whether a row IS a row, or the heading that names the run of rows beneath it.
    ///
    /// A heading is a member of this vocabulary rather than a separate list-level concept
    /// because it has to interleave: `STAGED 3 … CHANGES 27 …` is one scroll of one list,
    /// and a list that took headings as a separate argument could not put them in order.
    /// A heading draws no chevron, no icon and no hover, and reports no selection.
    public enum Kind: String, Sendable, Equatable {
        case row, sectionHeader
    }

    public let kind: Kind
    public let id: String
    public let label: String
    /// Muted secondary text after the label — a containing directory, a timestamp, a hint.
    /// Truncated from the middle before the label gives up any of its own width.
    public let detail: String?
    public let depth: Int
    public let icon: String?
    public let expanded: Bool?
    public let menu: [RowMenuItem]
    public let editing: Bool
    public let placeholder: String?
    public let selected: Bool
    public let accessory: RowAccessory?
    public let path: String?

    public init(
        kind: Kind = .row,
        id: String,
        label: String,
        detail: String? = nil,
        depth: Int,
        icon: String?,
        expanded: Bool? = nil,
        menu: [RowMenuItem] = [],
        editing: Bool = false,
        placeholder: String? = nil,
        selected: Bool = false,
        accessory: RowAccessory? = nil,
        path: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.label = label
        self.detail = detail
        self.depth = depth
        self.icon = icon
        self.expanded = expanded
        self.menu = menu
        self.editing = editing
        self.placeholder = placeholder
        self.selected = selected
        self.accessory = accessory
        self.path = path
    }
}

/// A view's modal presentation: the same node vocabulary, shown over the whole shell
/// instead of inside the pane.
///
/// Presentation only, exactly like `header`. The plugin owns whether a modal exists
/// — it publishes one by setting this and takes it away by clearing it — and the host
/// owns how it looks and how it is dismissed. Escape, the backdrop, and the close control
/// all deliver `dismissAction` back through the view's `onSelect`, so the host never
/// mutates plugin state behind its back.
public struct PluginViewModal: Sendable, Equatable {
    /// Bounds the header (invariant 10); the body's nodes carry their own.
    public static let maximumTitleLength = 160
    /// The action id delivered on dismiss when the plugin names none.
    public static let defaultDismissAction = "modal.dismiss"

    public let title: String
    public let body: PluginViewNode?
    public let dismissAction: String

    public init(title: String, body: PluginViewNode?, dismissAction: String) {
        self.title = String(title.prefix(Self.maximumTitleLength))
        self.body = body
        self.dismissAction = dismissAction
    }
}

/// One immutable view contribution visible to the host.
public struct PluginViewInfo: Sendable, Equatable, Identifiable {
    public let viewID: String
    public let instanceID: String?
    public let instanced: Bool
    public let title: String
    /// What this view puts in the ONE chrome header its pane draws.
    ///
    /// It rides the view contribution rather than living in a host-side store, which is what
    /// makes a retired generation's chrome disappear with its contributions instead of needing
    /// to be swept (invariant 10). A view that publishes no `header` key publishes `.empty`,
    /// which is the bare chrome every pane starts with.
    public let header: PaneHeader
    public let items: [TreeRowItem]
    public let body: PluginViewNode?
    public let modal: PluginViewModal?

    public var id: String {
        instanceID.map { "\(viewID)#\($0)" } ?? viewID
    }

    public init(
        viewID: String,
        instanceID: String?,
        instanced: Bool,
        title: String,
        items: [TreeRowItem],
        body: PluginViewNode?,
        header: PaneHeader = .empty,
        modal: PluginViewModal? = nil
    ) {
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
    /// A fact this plugin published (T-049). The runtime hands the host the *local*
    /// channel name; only the host knows who is publishing, so only the host can qualify
    /// it — which is what makes forging another plugin's channel unavailable rather than
    /// merely refused.
    public typealias PublishEvent = @Sendable (String, IntentValue) async -> Void

    public let manifest: PluginManifest
    public let directory: URL
    public let intents: PluginRuntimeIntentBridge
    public let local: PluginRuntimeLocalState
    public let log: Log
    public let persistStorage: PersistStorage
    public let onStateChange: StateChange
    public let publishEvent: PublishEvent
    public let startupTimeout: TimeInterval
    /// The ceiling on one compiled program's callback — event, view select/submit/open/close —
    /// run on the generation's single serial pump. A handler stuck past this bound fails the
    /// generation instead of holding every later pane's callback behind it forever.
    public let callbackTimeout: TimeInterval

    public init(
        manifest: PluginManifest,
        directory: URL,
        intents: PluginRuntimeIntentBridge,
        local: PluginRuntimeLocalState = PluginRuntimeLocalState(),
        log: @escaping Log = { _ in },
        persistStorage: @escaping PersistStorage = { _, _ in },
        onStateChange: @escaping StateChange = { _ in },
        publishEvent: @escaping PublishEvent = { _, _ in },
        startupTimeout: TimeInterval = 2,
        callbackTimeout: TimeInterval = 10
    ) {
        self.manifest = manifest
        self.directory = directory
        self.intents = intents
        self.local = local
        self.log = log
        self.persistStorage = persistStorage
        self.onStateChange = onStateChange
        self.publishEvent = publishEvent
        self.startupTimeout = startupTimeout
        self.callbackTimeout = callbackTimeout
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
    public let paletteProviders: [PaletteProviderInfo]
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
        paletteProviders: [PaletteProviderInfo] = [],
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
        self.paletteProviders = paletteProviders
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
    /// The step that was still running when the shutdown deadline passed.
    ///
    /// Every one of these can be held open by the plugin's own JavaScript, which is why the
    /// deadline covers them rather than only the executor stop at the end. A named phase is
    /// what turns "quit took two seconds" into "this plugin's teardown never returned".
    public enum StalledPhase: String, Sendable, Equatable {
        /// `__tenonShutdown` and the JavaScript teardown around it.
        case javaScriptTeardown
        /// The callback pump, still delivering into a context that will not drain.
        case callbackPump
        /// Provider calls this generation accepted and has not settled.
        case providerCalls
        /// The final state publication.
        case stateEmitter
    }

    public let executorResult: PinnedThreadExecutor.ShutdownResult
    public let createdThreadIdentifier: UInt64?
    public let destroyedThreadIdentifier: UInt64?
    public let cancelledProviderCalls: Int
    public let lateProviderReplyCount: Int
    /// `nil` when every phase finished inside the deadline.
    public let stalledPhase: StalledPhase?

    public init(
        executorResult: PinnedThreadExecutor.ShutdownResult,
        createdThreadIdentifier: UInt64?,
        destroyedThreadIdentifier: UInt64?,
        cancelledProviderCalls: Int,
        lateProviderReplyCount: Int,
        stalledPhase: StalledPhase? = nil
    ) {
        self.executorResult = executorResult
        self.createdThreadIdentifier = createdThreadIdentifier
        self.destroyedThreadIdentifier = destroyedThreadIdentifier
        self.cancelledProviderCalls = cancelledProviderCalls
        self.lateProviderReplyCount = lateProviderReplyCount
        self.stalledPhase = stalledPhase
    }
}

public enum PluginRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidLifecycle(expected: PluginRuntimePhase, actual: PluginRuntimePhase)
    case javascriptContextUnavailable
    case javascriptException(String)
    case bridgeProtocolViolation(String)
    case undeclaredIntentHandler(IntentID)
    case undeclaredEventPublication(String)
    case missingIntentHandlers([IntentID])
    case duplicateIntentHandler(IntentID)
    case bundledSwiftImplementationUnavailable(PluginID)
    case invalidStartupTimeout(TimeInterval)
    case startupTimedOut(TimeInterval)
    case callbackTimedOut(kind: String, timeout: TimeInterval)
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
        case let .undeclaredEventPublication(name):
            "published undeclared event \(name)"
        case let .undeclaredIntentHandler(intentID):
            "handler for undeclared intent \(intentID.rawValue)"
        case let .missingIntentHandlers(intentIDs):
            "missing handlers: \(intentIDs.map(\.rawValue).sorted().joined(separator: ", "))"
        case let .duplicateIntentHandler(intentID):
            "duplicate handler for \(intentID.rawValue)"
        case let .bundledSwiftImplementationUnavailable(pluginID):
            "no bundled Swift implementation was compiled for \(pluginID.rawValue)"
        case let .invalidStartupTimeout(timeout):
            "invalid plugin startup timeout: \(timeout)"
        case let .startupTimedOut(timeout):
            "plugin activation exceeded startup timeout: \(timeout)s"
        case let .callbackTimedOut(kind, timeout):
            "compiled \(kind) callback exceeded callback timeout: \(timeout)s"
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
