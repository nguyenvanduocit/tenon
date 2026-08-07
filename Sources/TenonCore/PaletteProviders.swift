// @domain: command-surface, plugin-contributions
import Foundation
import TenonIntentCore

/// One secondary action on a dynamic palette result (the ⌘K submenu). An action is a
/// separate plugin-owned intent designation — never a closure riding the result object —
/// so invocation always enters the shared dispatcher as the palette principal.
public struct PaletteResultAction: Sendable, Equatable {
    public let title: String
    public let intentID: IntentID
    public let input: IntentValue

    public init(title: String, intentID: IntentID, input: IntentValue) {
        self.title = title
        self.intentID = intentID
        self.input = input
    }
}

/// One dynamic palette result a provider published for one query revision.
///
/// The row carries presentation plus a canonical intent designation owned by the
/// publishing plugin. Naming the intent grants nothing: the dispatcher's policy path
/// authorizes the invocation exactly as it does for a static palette row.
public struct PaletteResultItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: String?
    public let intentID: IntentID
    public let input: IntentValue
    public let actions: [PaletteResultAction]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        intentID: IntentID,
        input: IntentValue = .object([:]),
        actions: [PaletteResultAction] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.intentID = intentID
        self.input = input
        self.actions = actions
    }
}

/// Snapshot of one palette provider inside a runtime generation.
///
/// `deliveredRevision` is the newest query revision handed to the plugin's handler;
/// `publishedRevision` is the revision of the last accepted publication (0 = none).
/// The host compares these against its own current revision to derive the pending state,
/// so a slow provider can never block or reorder anything — it just stays behind.
public struct PaletteProviderInfo: Sendable, Equatable, Identifiable {
    public let providerID: String
    public let title: String
    public let deliveredRevision: Int
    public let publishedRevision: Int
    public let results: [PaletteResultItem]

    public var id: String { providerID }

    public init(
        providerID: String,
        title: String,
        deliveredRevision: Int,
        publishedRevision: Int,
        results: [PaletteResultItem]
    ) {
        self.providerID = providerID
        self.title = title
        self.deliveredRevision = deliveredRevision
        self.publishedRevision = publishedRevision
        self.results = results
    }
}

/// One host-published palette section: a provider's results for the current query
/// revision, or its pending marker while the answer is still in flight. Sections render
/// below the static ranked rows and never delay or reorder them.
public struct PaletteProviderSection: Sendable, Equatable, Identifiable {
    public let pluginID: PluginID
    public let providerID: String
    public let title: String
    public let isPending: Bool
    public let results: [PaletteResultItem]

    public var id: String { "\(pluginID.rawValue)#\(providerID)" }

    public init(
        pluginID: PluginID,
        providerID: String,
        title: String,
        isPending: Bool,
        results: [PaletteResultItem]
    ) {
        self.pluginID = pluginID
        self.providerID = providerID
        self.title = title
        self.isPending = isPending
        self.results = results
    }
}
