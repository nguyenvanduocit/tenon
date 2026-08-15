// @domain: plugin-host, plugin-contributions
import Foundation
import os
import TenonCore
import TenonIntentCore

/// The compiled implementation side of a manifest-backed plugin.
///
/// This value is intentionally package-internal. The manifest remains the source of plugin
/// identity and authority; a program supplies only code already linked into this Tenon build.
struct BundledPluginProgram {
    typealias Activate = @Sendable (
        BundledPluginContext
    ) async throws -> BundledPluginContribution
    typealias ReceiveEvent = @Sendable (
        String,
        IntentValue,
        BundledPluginContext
    ) async throws -> BundledPluginContribution?
    typealias InvokeIntent = @Sendable (
        IntentEnvelope,
        IntentProviderContext,
        BundledPluginContext
    ) async throws -> IntentProviderReply
    typealias LegacyInvokeIntent = @Sendable (
        IntentEnvelope,
        IntentProviderContext
    ) async throws -> IntentProviderReply

    let id: PluginID
    let subscribedEvents: Set<String>
    let providedIntents: Set<IntentID>
    /// Owner-scoped view callbacks, keyed by the view id the program publishes.
    ///
    /// Presence is the routing contract: the host's `invokeViewSelect/Submit` answer is
    /// "a handler is registered for this view id", exactly like the JavaScript bootstrap's
    /// per-view handler map, and the handler itself runs later on the plugin's own bounded
    /// callback pump, ordered with event delivery.
    let viewCallbacks: [String: BundledPluginViewCallbacks]
    let activate: Activate
    let receiveEvent: ReceiveEvent
    let invokeIntent: InvokeIntent

    init(
        id: PluginID,
        subscribedEvents: Set<String>,
        providedIntents: Set<IntentID>,
        viewCallbacks: [String: BundledPluginViewCallbacks] = [:],
        activate: @escaping Activate,
        receiveEvent: @escaping ReceiveEvent,
        invokeIntent: @escaping InvokeIntent
    ) {
        self.id = id
        self.subscribedEvents = subscribedEvents
        self.providedIntents = providedIntents
        self.viewCallbacks = viewCallbacks
        self.activate = activate
        self.receiveEvent = receiveEvent
        self.invokeIntent = invokeIntent
    }

    /// Keeps the no-context form source-compatible for compiled programs that do not publish
    /// from an intent handler. Programs that need to update their CONTRIBUTION use the primary
    /// initializer and receive the generation context as its third argument.
    init(
        id: PluginID,
        subscribedEvents: Set<String>,
        providedIntents: Set<IntentID>,
        viewCallbacks: [String: BundledPluginViewCallbacks] = [:],
        activate: @escaping Activate,
        receiveEvent: @escaping ReceiveEvent,
        invokeIntent: @escaping LegacyInvokeIntent
    ) {
        self.init(
            id: id,
            subscribedEvents: subscribedEvents,
            providedIntents: providedIntents,
            viewCallbacks: viewCallbacks,
            activate: activate,
            receiveEvent: receiveEvent,
            invokeIntent: { envelope, providerContext, _ in
                try await invokeIntent(envelope, providerContext)
            }
        )
    }
}

// MARK: - View registration and body state  @domain: plugin-contributions

/// Static metadata that admits a view into the host's contribution projection.
struct BundledPluginViewRegistration: Sendable, Equatable {
    let viewID: String
    let title: String
    let instanced: Bool

    init(viewID: String, title: String, instanced: Bool) {
        self.viewID = viewID
        self.title = title
        self.instanced = instanced
    }
}

/// One body published for a registered view. Instance identity belongs to the body, so a
/// timer or intent can replace one pane without re-declaring the view's static registration.
struct BundledPluginViewBody: Sendable, Equatable {
    let viewID: String
    let instanceID: String?
    let items: [TreeRowItem]
    let body: PluginViewNode?
    let header: PaneHeader
    let modal: PluginViewModal?

    init(
        viewID: String,
        instanceID: String?,
        items: [TreeRowItem] = [],
        body: PluginViewNode? = nil,
        header: PaneHeader = .empty,
        modal: PluginViewModal? = nil
    ) {
        self.viewID = viewID
        self.instanceID = instanceID
        self.items = items
        self.body = body
        self.header = header
        self.modal = modal
    }
}

// MARK: - Generation-owned facilities  @domain: plugin-host

/// A generation's own settings and plugin-private storage, live for as long as the generation.
///
/// It is a reference with its own lock rather than a value the program is handed once: a
/// program reads these across `await` boundaries — `git` re-reads its repository path after a
/// `rev-parse` returns, precisely so a slow command cannot answer for a path the operator has
/// since changed — and a value captured at activation would answer with the world as it was
/// when the plugin started. Reads stay synchronous, matching `tenon.settings.get` and
/// `tenon.storage.get`, so a handler never has to suspend to ask what it is configured with.
final class BundledPluginLocalState: Sendable {
    private struct Values: Sendable {
        var settings: [String: IntentValue]
        var storage: [String: IntentValue]
    }

    private let values: OSAllocatedUnfairLock<Values>

    init(_ initial: PluginRuntimeLocalState) {
        values = OSAllocatedUnfairLock(
            initialState: Values(
                settings: initial.settings,
                storage: initial.storage
            )
        )
    }

    func setting(_ key: String) -> IntentValue? {
        values.withLock { $0.settings[key] }
    }

    func storageValue(_ key: String) -> IntentValue? {
        values.withLock { $0.storage[key] }
    }

    /// The host told this generation a declared setting changed.
    func applySetting(_ key: String, _ value: IntentValue) {
        values.withLock { $0.settings[key] = value }
    }

    /// The host confirmed a storage write. Only a confirmed write lands here, so a refused
    /// one leaves the previous committed value readable rather than a value nobody persisted.
    func commitStorage(_ key: String, _ value: IntentValue) {
        values.withLock { $0.storage[key] = value }
    }
}

// MARK: - Timers and filesystem watches  @domain: plugin-host

/// A generation-owned timer handle. Cancellation is idempotent and remains valid after the
/// callback that created it has returned; the runtime decides whether the generation or a view
/// instance still owns the underlying task.
struct BundledPluginTimerHandle: Sendable {
    let id: Int
    private let cancelOperation: @Sendable () async -> Void

    init(id: Int, cancel: @escaping @Sendable () async -> Void) {
        self.id = id
        cancelOperation = cancel
    }

    func cancel() async {
        await cancelOperation()
    }
}

/// The compiled equivalent of `tenon.timers.after/every/cancel`.
struct BundledPluginTimers: Sendable {
    typealias Handler = @Sendable () async -> Void
    struct Callback: Sendable {
        let operation: Handler

        init(_ operation: @escaping Handler) {
            self.operation = operation
        }
    }

    typealias Schedule = @Sendable (Double, Bool, String?, Callback) async throws -> Int
    typealias Cancel = @Sendable (Int) async -> Void

    private let schedule: Schedule
    private let cancel: Cancel

    init(
        schedule: @escaping Schedule,
        cancel: @escaping Cancel
    ) {
        self.schedule = schedule
        self.cancel = cancel
    }

    func after(
        _ milliseconds: Double,
        ownedBy instanceID: String? = nil,
        handler: @escaping Handler
    ) async throws -> BundledPluginTimerHandle {
        let id = try await schedule(
            milliseconds,
            false,
            instanceID,
            Callback(handler)
        )
        return BundledPluginTimerHandle(id: id, cancel: cancelOperation(for: id))
    }

    func every(
        _ milliseconds: Double,
        ownedBy instanceID: String? = nil,
        handler: @escaping Handler
    ) async throws -> BundledPluginTimerHandle {
        let id = try await schedule(
            milliseconds,
            true,
            instanceID,
            Callback(handler)
        )
        return BundledPluginTimerHandle(id: id, cancel: cancelOperation(for: id))
    }

    func cancel(_ timer: BundledPluginTimerHandle) async {
        await cancel(timer.id)
    }

    private func cancelOperation(for id: Int) -> @Sendable () async -> Void {
        let cancel = self.cancel
        return { await cancel(id) }
    }
}

/// A generation-owned filesystem watch handle.
struct BundledPluginWatchHandle: Sendable {
    let id: Int
    private let cancelOperation: @Sendable () async -> Void

    init(id: Int, cancel: @escaping @Sendable () async -> Void) {
        self.id = id
        cancelOperation = cancel
    }

    func cancel() async {
        await cancelOperation()
    }
}

/// The compiled equivalent of `tenon.fs.watch`. A refused watch returns nil and records the
/// same permission/resource diagnostic the JavaScript backend exposes in its snapshot.
struct BundledPluginFileSystem: Sendable {
    typealias WatchHandler = @Sendable ([String]) async -> Void
    struct Callback: Sendable {
        let operation: WatchHandler

        init(_ operation: @escaping WatchHandler) {
            self.operation = operation
        }
    }

    typealias Start = @Sendable (String, Bool, String?, Callback) async -> Int?
    typealias Cancel = @Sendable (Int) async -> Void

    private let start: Start
    private let cancel: Cancel

    init(
        start: @escaping Start,
        cancel: @escaping Cancel
    ) {
        self.start = start
        self.cancel = cancel
    }

    func watch(
        _ path: String,
        recursive: Bool = false,
        ownedBy instanceID: String? = nil,
        handler: @escaping WatchHandler
    ) async -> BundledPluginWatchHandle? {
        guard let id = await start(
            path,
            recursive,
            instanceID,
            Callback(handler)
        ) else { return nil }
        let cancel = self.cancel
        return BundledPluginWatchHandle(id: id) {
            await cancel(id)
        }
    }
}

// MARK: - Compiled program context  @domain: plugin-host

/// Everything a compiled program may reach outside its own code.
struct BundledPluginContext: Sendable {
    /// The publish half of EVENT, supplied by the owning generation: it holds the phase gate
    /// and the manifest's `events.publishes` declaration, which is where authority belongs.
    typealias PublishEvent = @Sendable (String, IntentValue) async throws -> Void
    typealias PublishContribution = @Sendable (BundledPluginContribution) async -> Void

    private let state: BundledPluginLocalState
    let intents: PluginRuntimeIntentBridge
    let log: PluginRuntimeConfiguration.Log
    let timers: BundledPluginTimers
    let fs: BundledPluginFileSystem
    private let persistStorage: PluginRuntimeConfiguration.PersistStorage
    private let publishEvent: PublishEvent
    private let publishContribution: PublishContribution

    init(
        state: BundledPluginLocalState,
        intents: PluginRuntimeIntentBridge,
        log: @escaping PluginRuntimeConfiguration.Log,
        timers: BundledPluginTimers,
        fs: BundledPluginFileSystem,
        persistStorage: @escaping PluginRuntimeConfiguration.PersistStorage,
        publishEvent: @escaping PublishEvent,
        publishContribution: @escaping PublishContribution
    ) {
        self.state = state
        self.intents = intents
        self.log = log
        self.timers = timers
        self.fs = fs
        self.persistStorage = persistStorage
        self.publishEvent = publishEvent
        self.publishContribution = publishContribution
    }

    /// The current value of a declared setting, including one the host changed after this
    /// generation activated.
    func setting(_ key: String) -> IntentValue? {
        state.setting(key)
    }

    /// The last value the host committed for this key.
    func storageValue(_ key: String) -> IntentValue? {
        state.storageValue(key)
    }

    /// Writes through the host and adopts the value locally only once the host confirms it.
    /// A refused write throws and changes nothing a later read can see.
    func setStorageValue(_ key: String, _ value: IntentValue) async throws {
        try await persistStorage(key, value)
        state.commitStorage(key, value)
    }

    /// Publishes a fact on one of this plugin's own declared channels.
    func emit(event: String, payload: IntentValue) async throws {
        try await publishEvent(event, payload)
    }

    /// Pushes a new immutable CONTRIBUTION through the generation's bounded pump. This is the
    /// route for work whose initial reply is not a contribution, such as a provided intent or a
    /// future timer callback; it keeps publication ordered with host-delivered events and view
    /// callbacks.
    func publishContribution(_ contribution: BundledPluginContribution) async {
        await publishContribution(contribution)
    }
}

// MARK: - Contribution projection  @domain: plugin-contributions

struct BundledPluginContribution: Sendable, Equatable {
    static let empty = BundledPluginContribution()

    let statusBarText: String?
    let viewRegistrations: [BundledPluginViewRegistration]
    let viewBodies: [BundledPluginViewBody]

    /// Materializes the separate registration/body state into the host-facing projection.
    var views: [PluginViewInfo] {
        var result: [PluginViewInfo] = []
        for registration in viewRegistrations {
            let bodies = viewBodies.filter { $0.viewID == registration.viewID }
            if registration.instanced {
                // Registration is retained separately for routing and reconciliation. The
                // host-facing projection mirrors the JavaScript runtime: an instanced view
                // contributes only its open instance bodies, never a nil-instance placeholder
                // that could shadow a real pane when host projections select the first match.
                result.append(contentsOf: bodies.compactMap { body in
                    guard let instanceID = body.instanceID else { return nil }
                    return PluginViewInfo(
                        viewID: registration.viewID,
                        instanceID: instanceID,
                        instanced: true,
                        title: registration.title,
                        items: body.items,
                        body: body.body,
                        header: body.header,
                        modal: body.modal
                    )
                })
            } else {
                let body = bodies.first(where: { $0.instanceID == nil })
                result.append(
                    PluginViewInfo(
                        viewID: registration.viewID,
                        instanceID: nil,
                        instanced: false,
                        title: registration.title,
                        items: body?.items ?? [],
                        body: body?.body,
                        header: body?.header ?? .empty,
                        modal: body?.modal
                    )
                )
            }
        }
        return result.sorted {
            ($0.viewID, $0.instanceID ?? "") < ($1.viewID, $1.instanceID ?? "")
        }
    }

    init(
        statusBarText: String? = nil,
        views: [PluginViewInfo] = []
    ) {
        self.statusBarText = statusBarText
        var registrations: [BundledPluginViewRegistration] = []
        var registeredIDs = Set<String>()
        var bodies: [BundledPluginViewBody] = []
        for view in views {
            if registeredIDs.insert(view.viewID).inserted {
                registrations.append(
                    BundledPluginViewRegistration(
                        viewID: view.viewID,
                        title: view.title,
                        instanced: view.instanced
                    )
                )
            }
            if view.instanced || view.body != nil || !view.items.isEmpty
                || view.header != .empty || view.modal != nil
            {
                bodies.append(
                    BundledPluginViewBody(
                        viewID: view.viewID,
                        instanceID: view.instanceID,
                        items: view.items,
                        body: view.body,
                        header: view.header,
                        modal: view.modal
                    )
                )
            }
        }
        self.viewRegistrations = registrations
        self.viewBodies = bodies
    }

    init(
        statusBarText: String? = nil,
        viewRegistrations: [BundledPluginViewRegistration],
        viewBodies: [BundledPluginViewBody] = []
    ) {
        self.statusBarText = statusBarText
        self.viewRegistrations = viewRegistrations
        self.viewBodies = viewBodies
    }

    func removingBody(viewID: String, instanceID: String) -> BundledPluginContribution {
        BundledPluginContribution(
            statusBarText: statusBarText,
            viewRegistrations: viewRegistrations,
            viewBodies: viewBodies.filter {
                !($0.viewID == viewID && $0.instanceID == instanceID)
            }
        )
    }
}

// MARK: - View callbacks  @domain: plugin-contributions

/// One published view's owner-scoped callbacks. Every member is optional: a view that
/// declares no `select` reports select unhandled, mirroring an unregistered `onSelect`.
struct BundledPluginViewCallbacks {
    typealias HandleSelect = @Sendable (
        BundledPluginViewSelect,
        BundledPluginContext
    ) async throws -> BundledPluginContribution?
    typealias HandleSubmit = @Sendable (
        BundledPluginViewSubmit,
        BundledPluginContext
    ) async throws -> BundledPluginContribution?
    typealias HandleLifecycle = @Sendable (
        String,
        BundledPluginContext
    ) async throws -> BundledPluginContribution?

    let select: HandleSelect?
    let submit: HandleSubmit?
    let open: HandleLifecycle?
    let close: HandleLifecycle?

    init(
        select: HandleSelect? = nil,
        submit: HandleSubmit? = nil,
        open: HandleLifecycle? = nil,
        close: HandleLifecycle? = nil
    ) {
        self.select = select
        self.submit = submit
        self.open = open
        self.close = close
    }
}

struct BundledPluginViewSelect: Sendable {
    let viewID: String
    let instanceID: String?
    let action: PluginNodeAction
    let value: IntentValue?

    var itemID: String { action.stringValue ?? action.description }

    init(
        viewID: String,
        instanceID: String?,
        itemID: String,
        value: IntentValue?
    ) {
        self.init(
            viewID: viewID,
            instanceID: instanceID,
            action: .string(itemID),
            value: value
        )
    }

    init(
        viewID: String,
        instanceID: String?,
        action: PluginNodeAction,
        value: IntentValue?
    ) {
        self.viewID = viewID
        self.instanceID = instanceID
        self.action = action
        self.value = value
    }
}

struct BundledPluginViewSubmit: Sendable {
    let viewID: String
    let instanceID: String?
    let itemID: String
    let text: String
}
