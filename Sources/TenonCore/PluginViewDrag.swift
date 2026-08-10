// @domain: plugin-contributions
import Foundation
import TenonIntentCore

/// The one view instance a drag is allowed to travel inside: one plugin, one registered
/// view, one open instance of it (T-012).
///
/// A drag is a pointer gesture the host owns, but what it *means* belongs to exactly one
/// generation. Scoping it here is what stops a card picked up in one plugin's pane from
/// arriving in another plugin's action route as if that plugin's own UI had produced it —
/// a cross-principal path that would never have passed the dispatcher.
public struct PluginViewDragScope: Hashable, Sendable {
    public let pluginID: PluginID
    public let viewID: String
    /// The pane this view is open in, or nil for a view with a single instance.
    public let instanceID: String?

    public init(pluginID: PluginID, viewID: String, instanceID: String?) {
        self.pluginID = pluginID
        self.viewID = viewID
        self.instanceID = instanceID
    }
}

/// What a `dragSource` node hands to whichever `dropTarget` node receives it.
///
/// The whole mechanism is one bounded string travelling from a subtree the plugin marked
/// draggable to a subtree it marked droppable, arriving as the target's own
/// `views.onSelect(action, value)` — the same event shape a button press and a text-field
/// submit already use. See the T-056 section of `docs/architecture-interaction-boundaries.md`
/// for why that is CONTRIBUTION plus an existing EVENT rather than a new mechanism.
///
/// The pasteboard is not a trust boundary and is not treated as one: scope travels *in* the
/// dragged string and is checked on arrival. A local process that can synthesise a drag onto
/// a focused pane can synthesise a click on the button beside it, so these rules buy
/// correctness against accident and against cross-plugin leakage — not resistance to a
/// hostile local app.
public enum PluginViewDrag {
    /// Longest payload a drag may carry (invariant 10). A payload names a thing the plugin
    /// already drew — a task id, a row key — so a few hundred characters is generous; a
    /// plugin wanting to move a *document* between panes is asking for a different feature.
    public static let maximumPayloadLength = 256

    /// Names both the format and its version, so a future envelope shape can refuse today's
    /// rather than misread it.
    static let marker = "tenon.plugin-view-drag.v1"

    /// The one place the payload bound lives: publication, encoding, and admission all ask
    /// this. Returns the payload when it may travel, `nil` when it may not.
    public static func admissiblePayload(_ payload: String?) -> String? {
        guard let payload, !payload.isEmpty, payload.count <= maximumPayloadLength else {
            return nil
        }
        return payload
    }

    /// The string the host puts on the pasteboard for a drag that started in `scope`.
    /// `nil` when the payload may not travel, and then the subtree simply is not draggable.
    public static func encode(payload: String, from scope: PluginViewDragScope) -> String? {
        guard let admissible = admissiblePayload(payload) else { return nil }
        let envelope = Envelope(
            marker: marker,
            plugin: scope.pluginID.rawValue,
            view: scope.viewID,
            instance: scope.instanceID,
            payload: admissible
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The payload a drop in `scope` receives, or `nil` when the drag may not be admitted:
    /// it did not start in a plugin view, it started in a different plugin/view/instance,
    /// or it carries a payload past the bound.
    ///
    /// Every clause is fail-closed on its own, and the bound is re-checked here rather than
    /// trusted from publication — an envelope this host did not build is exactly the case
    /// the publication check cannot cover.
    public static func decode(_ dragged: String, into scope: PluginViewDragScope) -> String? {
        guard let envelope = try? JSONDecoder().decode(
            Envelope.self,
            from: Data(dragged.utf8)
        ) else {
            return nil
        }
        guard envelope.marker == marker,
              envelope.plugin == scope.pluginID.rawValue,
              envelope.view == scope.viewID,
              envelope.instance == scope.instanceID
        else {
            return nil
        }
        return admissiblePayload(envelope.payload)
    }

    /// The wire shape. `instance` is absent, not empty, for a view with a single instance,
    /// so "no instance" and "an instance named the empty string" stay distinguishable.
    private struct Envelope: Codable {
        let marker: String
        let plugin: String
        let view: String
        let instance: String?
        let payload: String
    }
}
