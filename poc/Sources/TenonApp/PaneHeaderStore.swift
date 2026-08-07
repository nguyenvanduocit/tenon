// @domain: pane-chrome
import Foundation
import Observation
import TenonCore

/// Where a HOST-NATIVE pane's header contribution lives while its content view is mounted.
///
/// **This type exists to close an invalidation loop**, and that is the entire reason a header
/// is pushed into a store instead of pulled out of a content model where it is needed. A
/// header derived inside `SpatialCanvasNSView.configure` can never refresh: `configure` is
/// reached only when `WorkspaceStageView.body` re-evaluates, and that body's whole observed
/// set is `host.plugins`, `host.pluginViews`, `webPool.titles`, `store.catalog`,
/// `tab.activeSlotID` and `pool.paneAttention` (`WorkspaceStageView.swift:19-43`). A pane's
/// content model lives in a different SwiftUI graph — `@State` inside the content hosting
/// view — so nothing it changes can invalidate the outer one, and a header pulled from it
/// would freeze at whatever it said the first time the canvas was built.
///
/// Reading `headers` in `WorkspaceStageView.body` makes this store the sixth observed input.
/// **That read IS the invalidation contract**: drop it and every built-in header silently
/// stops updating while still rendering, which is the failure mode this design was written to
/// eliminate.
///
/// The channel costs what `pool.paneAttention` costs — the same shape, feeding the attention
/// dot in this very header today — because `publish` carries the same equality guard, so an
/// idle pane writes nothing and invalidates nobody.
///
/// Plugin panes are NOT stored here. Their header rides `PluginViewSection`, which
/// `PluginHost.publish()` rebuilds from live sessions only and which `WorkspaceStageView.body`
/// already observes, so a retired generation's header vanishes with its contributions for free
/// (invariant 10) and this store never has to know a plugin exists. `PaneHeaderProjection` is
/// where that split is enforced.
///
/// Data goes UP as a value; commands come DOWN as a typed `PaneHeaderCommand`. Every content
/// view keeps the state it already owns — Diff's style, Changes' layout — so moving a control
/// into the chrome moves pixels, not ownership.
@MainActor
@Observable
final class PaneHeaderStore {
    /// Read this in `WorkspaceStageView.body`, and pass the dictionary down as a value the way
    /// `paneAttention` is passed down. Reading it anywhere else observes nothing useful.
    private(set) var headers: [UUID: PaneHeader] = [:]

    /// Deliberately unobserved: a handler is a route, not state anyone renders, and making it
    /// observable would invalidate the canvas every time a content view remounted.
    @ObservationIgnored
    private var handlers: [UUID: (PaneHeaderCommand, String?) -> Void] = [:]

    /// Publish from `.task` / `.onChange` / `.onAppear` — never from a `body`. The equality
    /// guard makes a duplicate publish a true no-op with no `@Observable` mutation, so an
    /// accidental in-body write terminates after one pass instead of looping forever.
    func publish(_ header: PaneHeader, for slotID: UUID) {
        guard headers[slotID] != header else { return }
        headers[slotID] = header
    }

    /// One handler per slot: the pane that publishes a header is the pane that owns the state
    /// its controls change, so a second registration for the same slot is a remount, not a
    /// second listener.
    func onCommand(
        for slotID: UUID,
        _ handler: @escaping (PaneHeaderCommand, String?) -> Void
    ) {
        handlers[slotID] = handler
    }

    /// Routes a click that already resolved to a typed command. A slot whose content view has
    /// gone drops the command silently: the click raced the teardown, and there is no longer
    /// anything that owns the state it would have changed.
    func perform(_ command: PaneHeaderCommand, value: String?, for slotID: UUID) {
        handlers[slotID]?(command, value)
    }

    /// Called from each publisher's `.onDisappear` — the primary, symmetric release. Both
    /// halves go together: a handler left behind keeps the closed pane's model alive and lets
    /// a click on a recycled slot id reach a view that no longer exists.
    func clear(for slotID: UUID) {
        handlers.removeValue(forKey: slotID)
        guard headers[slotID] != nil else { return }
        headers.removeValue(forKey: slotID)
    }

    /// The deferred sweep, while one is in flight.
    ///
    /// Held rather than fired and forgotten for two reasons: a second configure pass
    /// replaces an unstarted sweep with its newer slot set instead of racing it, and a
    /// caller — including a test — can await the write that was deferred.
    @ObservationIgnored
    private(set) var pendingSweep: Task<Void, Never>?

    /// Backstop for a content view torn down without `onDisappear`, run from AFTER the view
    /// update that asked for it.
    ///
    /// The canvas asks for this from `SpatialCanvasNSView.configure`, which SwiftUI reaches
    /// through `updateNSView` — the middle of a view update, where mutating observable state
    /// is the "Modifying state during view update" defect. The guard below makes a sweep
    /// non-mutating whenever nothing is stale, and that is not a defence: the one moment
    /// something IS stale is the one moment this matters, a pane closing, which is precisely
    /// when the canvas runs it.
    ///
    /// So the DECISION is taken here, synchronously, because reading is always legal; the
    /// WRITE it implies is scheduled onto the main actor and lands once the update that
    /// asked for it has finished. Nothing can render the difference in between — the same
    /// pass has already removed the card for that slot.
    ///
    /// The primary release is still `clear(for:)` from a publisher's `.onDisappear`. This
    /// catches only a content view torn down without one.
    func scheduleSweep(retaining slotIDs: Set<UUID>) {
        guard holdsEntries(outside: slotIDs) else { return }
        pendingSweep?.cancel()
        pendingSweep = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.retainOnly(slotIDs)
        }
    }

    /// A pure read: does anything here belong to a slot that is no longer live?
    private func holdsEntries(outside slotIDs: Set<UUID>) -> Bool {
        headers.keys.contains { !slotIDs.contains($0) }
            || handlers.keys.contains { !slotIDs.contains($0) }
    }

    /// The sweep itself, reachable only through `scheduleSweep` so no future caller can
    /// put the write back on an update pass.
    ///
    /// The guard is written out rather than left to a whole-dictionary rewrite. Assigning an
    /// equal dictionary happens to notify nobody today, but that is the compiler's equality
    /// short-circuit on the generated setter, not a rule this file states; a per-key removal
    /// behind an explicit emptiness check states it.
    private func retainOnly(_ slotIDs: Set<UUID>) {
        // Handlers are unobserved, so sweeping them costs a reader nothing.
        for slotID in handlers.keys.filter({ !slotIDs.contains($0) }) {
            handlers.removeValue(forKey: slotID)
        }
        let stale = headers.keys.filter { !slotIDs.contains($0) }
        guard !stale.isEmpty else { return }
        for slotID in stale {
            headers.removeValue(forKey: slotID)
        }
    }
}
