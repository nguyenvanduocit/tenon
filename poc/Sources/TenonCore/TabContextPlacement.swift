import Foundation

/// Where a command chosen from a tab's context menu should land.
///
/// The launcher and the palette invoke a command against whatever pane is focused, which
/// is right for a keyboard surface and wrong for a menu opened by right-clicking a
/// *specific* tab — including a tab that is not the selected one. This resolves the pane
/// that scope should name, so the answer is a value the tests can pin rather than a side
/// effect of which pane happened to have focus.
///
/// Pure by construction: it reads a catalog and returns identifiers. Placement itself
/// stays where `workspace.content.open.v1` already put it — host policy, reusing a pane
/// showing the same kind of content and otherwise splitting. This only says *which tab is
/// being talked about*.
public enum TabContextPlacement {
    /// The pane a command should be scoped to when it is chosen from `tabID`'s menu.
    ///
    /// The tab's own active pane, because that is the pane a human looking at that tab
    /// would consider current — not the globally focused pane, which may be in another tab
    /// entirely. Falls back to the tab's first pane when the tab records no active one, and
    /// to `nil` when the tab is unknown or empty, which callers must treat as "do not
    /// invoke" rather than as "use the focused pane".
    public static func scopedPane(
        in catalog: WorkspaceCatalog,
        tabID: UUID
    ) -> UUID? {
        guard let tab = tab(in: catalog, id: tabID) else { return nil }
        if let active = tab.activeSlotID,
           tab.slots.contains(where: { $0.id == active })
        {
            return active
        }
        return tab.slots.first?.id
    }

    /// The workspace that owns `tabID`, so a command chosen on a tab in an unselected
    /// workspace still resolves against the right tree.
    public static func owningWorkspace(
        in catalog: WorkspaceCatalog,
        tabID: UUID
    ) -> UUID? {
        catalog.workspaces.first { workspace in
            workspace.tabs.contains { $0.id == tabID }
        }?.id
    }

    /// Whether choosing this command has to bring `tabID` forward.
    ///
    /// A command that opens content into the tab has to show it — a pane the human cannot
    /// see is not an outcome. A command with no placement (`New Tab`, and anything that
    /// acts elsewhere) has no reason to move the selection, so a right-click on a
    /// background tab leaves the human where they were.
    public static func requiresRevealing(
        in catalog: WorkspaceCatalog,
        tabID: UUID,
        placesContent: Bool
    ) -> Bool {
        guard placesContent else { return false }
        return catalog.activeWorkspace?.activeTabID != tabID
    }

    private static func tab(
        in catalog: WorkspaceCatalog,
        id: UUID
    ) -> Tab? {
        for workspace in catalog.workspaces {
            if let match = workspace.tabs.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }
}
