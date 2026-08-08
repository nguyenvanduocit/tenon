// @domain: terminal-surface, workspace-model
import Foundation
import TenonCore

/// The two edges that decide which pane has the keyboard, kept in one place so they cannot
/// disagree.
///
/// Focus is model-driven: the workspace names the active pane, and the responder chain is
/// moved to match. The opposite direction exists too — a person clicking into a terminal is
/// a fact AppKit learns first — and it is the pair that made T-088 possible. Each edge on
/// its own is fine; together they formed a cycle with no fixed point:
///
///   `.slotFocused(X)` → `focusSurface(X)` → `becomeFirstResponder` → `focusSlot(X)` → …
///
/// `Workspace.focusSlot` only refuses a pane that is *already* active, so two focus commands
/// issued in one burst for different panes each found the model pointing at the other one,
/// flipped it, and emitted a fresh command. Two in, two out, forever — which is what the
/// person saw as the old and new panes trading focus without further input.
///
/// The cycle is cut in two places, and both are needed. `SurfacePool` refuses to report a
/// responder change the host itself caused, so a command can no longer manufacture the event
/// that re-issues it. And a queued command reads the live model before it acts, so the last
/// model write wins regardless of the order two commands happen to run in.
@MainActor
enum PaneFocusRouting {
    /// The surface→model edge: a person put the keyboard in this pane, so the workspace
    /// follows. `SurfacePool` has already filtered out the responder changes the host caused.
    static func connect(store: WorkspaceStore, surfaces: SurfacePool) {
        surfaces.onSlotFocusGained = { [weak store] slotID in
            store?.focusSlot(slotID)
        }
    }

    /// The model→surface edge: the workspace named an active pane, so the responder chain
    /// moves to it on the next turn.
    ///
    /// The turn of delay is what a freshly opened pane needs — its surface is built by the
    /// render that the same mutation triggers. The live re-read is what keeps that delay
    /// safe: by the time this runs the model may have moved on, and a command for a pane the
    /// workspace no longer considers active carries nothing worth applying.
    static func scheduleFocusCommand(
        for slotID: UUID,
        store: WorkspaceStore,
        surfaces: SurfacePool
    ) {
        Task { @MainActor [weak store, weak surfaces] in
            await Task.yield()
            guard let store, let surfaces,
                  store.catalog.activeSlotID == slotID
            else { return }
            surfaces.focusSurface(for: slotID)
        }
    }
}
