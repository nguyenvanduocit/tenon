// @domain: pane-chrome
import Foundation
import TenonCore
import TenonIntentCore

/// The pure join that answers one question: what header does this slot's pane show?
///
/// It is a `switch` over slot content, not a lookup, because the answer's SOURCE differs by
/// owner and that difference is the rule worth writing down. A host-native pane's header comes
/// from `PaneHeaderStore`, where its own content view pushed it. A plugin pane's header comes
/// from that plugin's contribution and is deliberately unreachable from the store: the host
/// rebuilds `pluginViews` from live sessions only, so anything a retired generation drew
/// disappears with its contributions and nothing has to sweep after it (invariant 10). Reading
/// the store for a plugin pane would put that chrome back from a dictionary the host has no
/// reason to clean, which is exactly the leak the split prevents.
///
/// Pure and headless on purpose — the whole join is asserted without a window.
enum PaneHeaderProjection {
    /// Whether `section` is the contribution THIS pane shows: the plugin's singleton for the
    /// view (no instance), or this slot's own instance — never a neighbouring pane's (T-012).
    ///
    /// One predicate, every reader. A pane's title and its body must agree on which
    /// contribution is "mine"; restating `instanceID == nil || instanceID == slotID` at each
    /// reader is one chance per reader for them to disagree the day the rule changes.
    static func matches(
        _ section: PluginViewSection,
        pluginID: PluginID,
        viewID: String,
        slotID: UUID
    ) -> Bool {
        guard section.pluginID == pluginID, section.viewID == viewID else {
            return false
        }
        return section.instanceID == nil || section.instanceID == slotID.uuidString
    }

    /// This pane's section, or nil when the plugin publishes none — a retired generation, a
    /// view that never opened, or another pane's instance and no instance of our own.
    static func section(
        pluginID: PluginID,
        viewID: String,
        slotID: UUID,
        in sections: [PluginViewSection]
    ) -> PluginViewSection? {
        sections.first {
            matches($0, pluginID: pluginID, viewID: viewID, slotID: slotID)
        }
    }

    /// `published` is the store's entry for this slot, looked up by the caller, so the canvas
    /// is handed a value dictionary rather than the store itself; `pluginViewSections` is the
    /// host's live contribution list, from which a plugin pane picks its own.
    ///
    /// Written as an exhaustive switch rather than a `?? .empty`, so that adding a kind of pane
    /// forces its author to say which owner supplies its header instead of silently inheriting
    /// the host-native answer.
    static func header(
        for slot: WorkspaceSlot,
        published: PaneHeader?,
        pluginViewSections: [PluginViewSection]
    ) -> PaneHeader {
        switch slot.content {
        case let .pluginView(pluginID, viewID):
            // A plugin pane's chrome lives and dies with its contribution, which a plugin
            // publishes through `views.set` and the host rebuilds from live sessions. It is
            // read from the section this slot matched — `section(pluginID:viewID:slotID:in:)`,
            // above — and never from the store, so a retired generation's header vanishes with
            // its contributions and nothing has to sweep after it. A plugin that published no
            // `header` publishes `.empty`: the bare chrome every pane starts with.
            return section(
                pluginID: pluginID,
                viewID: viewID,
                slotID: slot.id,
                in: pluginViewSections
            )?.header ?? .empty
        case .terminal, .changes, .file, .diff, .automation, .agentSession, .empty:
            // A recorded session's header is host-native like the rest: the pane's own view
            // pushes it to `PaneHeaderStore` once it knows what it is reading, so a session
            // whose title arrives from the transcript names the pane the same way a live one
            // does. The reference's `displayName` is what it publishes until then.
            return published ?? .empty
        }
    }
}
