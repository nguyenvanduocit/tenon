// @domain: plugin-host, plugin-contributions
import Foundation
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
}

struct BundledPluginContext {
    let local: PluginRuntimeLocalState
    let intents: PluginRuntimeIntentBridge
    let log: PluginRuntimeConfiguration.Log
    let persistStorage: PluginRuntimeConfiguration.PersistStorage
}

struct BundledPluginContribution {
    static let empty = BundledPluginContribution()

    let statusBarText: String?
    let views: [PluginViewInfo]

    init(
        statusBarText: String? = nil,
        views: [PluginViewInfo] = []
    ) {
        self.statusBarText = statusBarText
        self.views = views
    }
}

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
    let itemID: String
    let value: IntentValue?
}

struct BundledPluginViewSubmit: Sendable {
    let viewID: String
    let instanceID: String?
    let itemID: String
    let text: String
}
