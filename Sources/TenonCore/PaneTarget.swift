// @domain: workspace-model
import Foundation

/// Resolves a CLI pane selector to a concrete slot `UUID`, validating existence and — for
/// terminal I/O — that the slot actually holds a terminal. Pure over a `WorkspaceCatalog`, so
/// every branch is asserted in `TenonCoreTests`. A pane id *is* the slot id (VISION: session
/// continuity keys a surface to its slot UUID).
public enum PaneTarget {
    public enum Outcome: Equatable {
        case resolved(UUID)
        /// An explicit id that isn't in the catalog.
        case paneNotFound(UUID)
        /// The slot exists but isn't a terminal (e.g. a files or plugin view) — `send`/`read`/`wait`
        /// reject it explicitly rather than silently doing nothing.
        case notATerminal(UUID)
        /// No explicit id was given and there is no active slot to fall back to.
        case noActivePane
    }

    /// `explicit` nil ⇒ fall back to the catalog's active slot. `requireTerminal` gates whether a
    /// non-terminal slot is an error (`send`/`read`/`wait` require a terminal; `focus` does not).
    public static func resolve(
        explicit: UUID?,
        in catalog: WorkspaceCatalog,
        requireTerminal: Bool
    ) -> Outcome {
        if let explicit {
            guard let slot = catalog.slot(id: explicit) else {
                return .paneNotFound(explicit)
            }
            if requireTerminal, slot.content != .terminal {
                return .notATerminal(explicit)
            }
            return .resolved(explicit)
        }

        guard let active = catalog.activeSlotID else {
            return .noActivePane
        }
        if requireTerminal, let slot = catalog.slot(id: active), slot.content != .terminal {
            return .notATerminal(active)
        }
        return .resolved(active)
    }

    /// Where an authorized `terminal.run.v1` should land, nearest first:
    /// the active pane if it is a terminal → any terminal in the active tab → any terminal in
    /// another tab of the current workspace (focusing it switches to that tab, so the command
    /// still runs in front of the user). `nil` means the workspace has no terminal at all and
    /// the shell opens one.
    ///
    /// The fallback is the whole point. A plugin's buttons are clicked while the plugin's own
    /// panel is the active pane, so "write to the active pane" silently drops the command —
    /// the terminal the user already has open is what they meant, and spawning a fresh tab
    /// next to an idle shell is not.
    public static func preferredTerminal(in catalog: WorkspaceCatalog) -> UUID? {
        guard let workspace = catalog.activeWorkspace else { return nil }
        if let tab = catalog.activeTab {
            if let active = tab.activeSlotID,
               tab.slots.first(where: { $0.id == active })?.content == .terminal {
                return active
            }
            if let inTab = tab.slots.first(where: { $0.content == .terminal })?.id {
                return inTab
            }
        }
        for tab in workspace.tabs where tab.id != workspace.activeTabID {
            if let elsewhere = tab.slots.first(where: { $0.content == .terminal })?.id {
                return elsewhere
            }
        }
        return nil
    }
}
