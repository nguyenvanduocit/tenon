import AppKit
import Foundation
import TenonCore

/// Pure projections of the per-slot `PaneActivity` machines onto the shell's surfaces
/// (T-029). The shell decides nothing: the viewed rule and every rollup are value-level
/// functions asserted headlessly in `PaneAttentionTests`, and every surface reads the
/// one machine — no second computation of "is this busy" exists anywhere.
enum PaneAttentionProjection {
    /// The three-condition viewed rule, decided in the core half's handoff: a pane is
    /// viewed while (a) the app is frontmost, (b) its workspace is the selected
    /// workspace, and (c) the pane is actually displayed on the canvas — the selected
    /// workspace's active tab renders all of its panes at once, so that tab's slots are
    /// the displayed set. Window focus alone never counts, workspace selection alone
    /// never counts for a pane in a background tab, and no timer ever feeds this.
    static func viewedSlots(
        appFrontmost: Bool,
        catalog: WorkspaceCatalog
    ) -> Set<UUID> {
        guard appFrontmost, let displayedTab = catalog.activeTab else { return [] }
        return Set(displayedTab.slots.map(\.id))
    }

    /// The sidebar row's rollup: how many of this workspace's slots are bold.
    static func unseenCount(
        in workspace: Workspace,
        attention: [UUID: PaneActivity]
    ) -> Int {
        workspace.tabs.reduce(0) { count, tab in
            count + tab.slots.count { attention[$0.id]?.isUnseen == true }
        }
    }

    /// The title-bar count: unseen slots across the whole catalog.
    static func totalUnseen(
        catalog: WorkspaceCatalog,
        attention: [UUID: PaneActivity]
    ) -> Int {
        catalog.workspaces.reduce(0) {
            $0 + unseenCount(in: $1, attention: attention)
        }
    }

    /// The tab chip's dot: its active slot's state — the same pane whose title the chip
    /// shows. `nil` (no dot) for a tab whose panes never materialised.
    static func tabState(
        for tab: TenonCore.Tab,
        attention: [UUID: PaneActivity]
    ) -> PaneActivityState? {
        guard let activeSlotID = tab.activeSlotID else { return nil }
        return attention[activeSlotID]?.state
    }

    /// The tab chip bolds while any of its slots is unseen, so attention cannot hide
    /// behind an unfocused pane of the tab.
    static func tabIsUnseen(
        _ tab: TenonCore.Tab,
        attention: [UUID: PaneActivity]
    ) -> Bool {
        tab.slots.contains { attention[$0.id]?.isUnseen == true }
    }

    /// One dot vocabulary for every surface: amber while output is still moving,
    /// green for a finish awaiting a human, dimmed green once acknowledged, muted for
    /// a quiet prompt, red for a dead shell.
    @MainActor
    static func dotColor(for state: PaneActivityState) -> NSColor {
        switch state {
        case .working:
            return TenonTheme.amberNS
        case .idle:
            return TenonTheme.mutedNS
        case .finishedUnseen:
            return .systemGreen
        case .seen:
            return NSColor.systemGreen.withAlphaComponent(0.45)
        case .exited:
            return .systemRed
        }
    }
}
