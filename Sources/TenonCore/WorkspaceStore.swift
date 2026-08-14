// @domain: workspace-model
import Foundation
import Observation
import TenonIntentCore

@Observable
public final class WorkspaceStore {
    public private(set) var catalog: WorkspaceCatalog
    /// Changes whenever a successful workspace mutation publishes a new catalog.
    /// Cursor-based readers use this identity to reject mixed-version pages.
    public private(set) var snapshotID = UUID()

    @ObservationIgnored
    public var onEvents: ((
        _ events: [WorkspaceEvent],
        _ snapshot: WorkspaceCatalog
    ) -> Void)?

    /// The content a fresh pane opens with when the caller doesn't ask for a specific
    /// one. The shell wires these to the user's `AppPreferences`; the default keeps the
    /// bare store (and every test that never sets them) opening terminals.
    @ObservationIgnored public var newTabContentProvider: () -> SlotContent = { .terminal }
    @ObservationIgnored public var newSplitContentProvider: () -> SlotContent = { .terminal }
    @ObservationIgnored public var newWorkspaceContentProvider: () -> SlotContent = { .terminal }

    /// How wide automatic layout may make a pane. The shell wires this to the user's
    /// `AppPreferences`; the bare store, and every test that never sets it, leaves creation
    /// and close-time absorption bounded only by the space the layout offers.
    @ObservationIgnored public var newPaneSizingProvider: () -> NewPaneSizing = { .unlimited }

    /// The live automatic-layout policy, read fresh for pane creation and close absorption.
    /// AppKit surfaces that compute a pane rect themselves — the empty-canvas launcher —
    /// read it here and apply it DIRECT.
    public var newPaneSizing: NewPaneSizing { newPaneSizingProvider() }

    /// Opened views are recorded here, against the workspace the mutation's own events name,
    /// so the empty-tab launcher can offer a "recently opened" list scoped to the workspace
    /// that owns it. Nil in headless tests that don't exercise it.
    public let recent: RecentStore?

    /// Opened workspaces are recorded here so the sidebar's contextual library can
    /// offer them again after they're closed. Nil in headless tests that skip it.
    public let recentWorkspaces: RecentWorkspaceStore?

    /// The folders the open workspaces are rooted at, republished only when a workspace
    /// opens or closes. The sidebar's contextual library filters its recent list against
    /// this instead of reading `catalog`, so tab/slot churn can't re-layout an open menu
    /// (see `WorkspaceSidebarView`).
    public private(set) var openWorkspaceFolders: Set<String>

    public init(
        catalog: WorkspaceCatalog = WorkspaceCatalog(),
        recent: RecentStore? = nil,
        recentWorkspaces: RecentWorkspaceStore? = nil
    ) {
        self.catalog = catalog
        self.recent = recent
        self.recentWorkspaces = recentWorkspaces
        self.openWorkspaceFolders = WorkspaceStore.folders(in: catalog)
    }

    public func addWorkspace(
        name: String,
        path: URL,
        content: SlotContent? = nil,
        appearance: WorkspaceAppearance = .default
    ) {
        guard apply({
            $0.addWorkspace(
                name: name,
                path: path,
                content: content ?? newWorkspaceContentProvider(),
                sizing: newPaneSizing
            )
        }) else { return }

        let workspaceID = catalog.activeWorkspaceID
        if !appearance.isDefault {
            apply { $0.setWorkspaceAppearance(workspaceID, appearance) }
        }
        recordRecentWorkspace(workspaceID)
    }

    public func removeWorkspace(_ id: UUID) {
        apply { $0.removeWorkspace(id) }
    }

    public func selectWorkspace(_ id: UUID) {
        apply { $0.selectWorkspace(id) }
    }

    /// Puts a workspace at another index without changing which workspace, tab, or pane is
    /// active. The sidebar and accessibility routes both enter through this typed mutation.
    public func moveWorkspace(_ id: UUID, to index: Int) {
        apply { $0.moveWorkspace(id, to: index) }
    }

    /// Name a workspace. Clearing the name asks for Tenon's derived default back.
    public func renameWorkspace(_ id: UUID, to typed: String) {
        setWorkspaceIdentity(id, name: typed)
    }

    /// Mark and tint a workspace.
    public func setWorkspaceAppearance(_ id: UUID, to appearance: WorkspaceAppearance) {
        setWorkspaceIdentity(id, appearance: appearance)
    }

    /// One atomic presentation patch shared by the built-in editor and public intent
    /// adapter. Nil leaves that half unchanged; an empty present name restores its default.
    public func setWorkspaceIdentity(
        _ id: UUID,
        name: String? = nil,
        appearance: WorkspaceAppearance? = nil
    ) {
        guard apply({
            $0.setWorkspaceIdentity(id, name: name, appearance: appearance)
        }) else { return }
        updateRecentWorkspaceIdentity(id)
    }

    /// Give a workspace Tenon's default name, mark, and tint back, leaving the workspace
    /// itself — its id, root, tabs, and panes — exactly where it is.
    public func resetWorkspaceIdentity(_ id: UUID) {
        guard apply({ $0.resetWorkspaceIdentity(id) }) else { return }
        updateRecentWorkspaceIdentity(id)
    }

    public func newTab(content: SlotContent? = nil) {
        let resolved = content ?? newTabContentProvider()
        recordRecent(
            resolved,
            from: applyEvents { $0.newTab(content: resolved, sizing: newPaneSizing) }
        )
    }

    public func selectTab(_ id: UUID) {
        apply { $0.selectTab(id) }
    }

    public func selectNextTab() {
        apply { $0.selectNextTab() }
    }

    public func selectPreviousTab() {
        apply { $0.selectPreviousTab() }
    }

    public func closeTab(_ id: UUID) {
        apply { $0.closeTab(id) }
    }

    public func closeTab(_ id: UUID, in workspaceID: UUID) {
        apply { $0.closeTab(id, in: workspaceID) }
    }

    /// Puts a tab at a different place in the active workspace's order (T-096). A
    /// destination that is out of range, names a tab this workspace is not showing, or is
    /// the place the tab already occupies publishes nothing and changes nothing.
    public func moveTab(_ id: UUID, to index: Int) {
        apply { $0.moveTab(id, to: index) }
    }

    public func addSlot(content: SlotContent = .terminal) {
        recordRecent(
            content,
            from: applyEvents { $0.addSlot(content: content, sizing: newPaneSizing) }
        )
    }

    /// Reserves an exact empty canvas region and returns the pane identity a scoped
    /// launcher invocation can address. `rect` is placed as given: the canvas fitted it to
    /// the creation maximum when it hit-tested the click, because only there is the cell
    /// the person actually pointed at still known.
    @discardableResult
    public func addSlot(content: SlotContent, at rect: GridRect) -> UUID? {
        let id = UUID()
        guard apply({ $0.addSlot(id: id, content: content, at: rect) }) else { return nil }
        return id
    }

    public func discardEmptySlot(_ id: UUID, restoringFocusTo previousSlotID: UUID?) {
        apply { $0.discardEmptySlot(id, restoringFocusTo: previousSlotID) }
    }

    public func splitActiveSlot(
        _ axis: SplitAxis,
        content: SlotContent? = nil
    ) {
        let resolved = content ?? newSplitContentProvider()
        recordRecent(resolved, from: applyEvents {
            $0.splitActiveSlot(axis, content: resolved, sizing: newPaneSizing)
        })
    }

    public func splitSlot(
        _ id: UUID,
        _ axis: SplitAxis,
        content: SlotContent? = nil
    ) {
        let resolved = content ?? newSplitContentProvider()
        recordRecent(resolved, from: applyEvents {
            $0.splitSlot(id, axis, content: resolved, sizing: newPaneSizing)
        })
    }

    /// A second pane showing what this pane shows. The content is copied, not shared: a
    /// duplicated terminal is a new shell, a duplicated editor is the same file open twice.
    public func duplicateSlot(_ id: UUID) {
        guard let content = catalog.slot(id: id)?.content else { return }
        recordRecent(
            content,
            from: applyEvents { $0.duplicateSlot(id, sizing: newPaneSizing) }
        )
    }

    public func closeSlot(_ id: UUID) {
        apply { $0.closeSlot(id, sizing: newPaneSizing) }
    }

    public func closeActiveSlot() {
        guard let id = catalog.activeSlotID else { return }
        closeSlot(id)
    }

    public func focusSlot(_ id: UUID) {
        apply { $0.focusSlot(id) }
    }

    public func focusNextSlot() {
        apply { $0.focusNextSlot() }
    }

    public func focusPreviousSlot() {
        apply { $0.focusPreviousSlot() }
    }

    public func setSlotContent(_ id: UUID, _ content: SlotContent) {
        recordRecent(content, from: applyEvents { $0.setSlotContent(id, content) })
    }

    /// Pin a pane label, or clear it back to the title derived from its content.
    public func renameSlot(_ id: UUID, to typed: String) {
        apply { $0.renameSlot(id, to: typed) }
    }

    /// Opens `content` in the active tab, reusing the pane that already shows this kind of
    /// surface and otherwise adding one. Placement is host policy: this never opens a tab.
    /// `SlotContent.yieldsPane(to:)` decides which existing panes qualify.
    ///
    /// The pane it adds goes through `addSlot`, which is the one placement policy every
    /// creation path shares: free canvas next to the active pane when the layout has any,
    /// a split only when it has none. Opening a file is not a request to halve the pane
    /// someone is looking at while half the canvas stands empty — and on a pane too narrow
    /// to split, that is also the difference between the file opening and nothing happening
    /// at all.
    public func openContent(_ content: SlotContent) {
        if let existing = reusableSlotID(for: content) {
            setSlotContent(existing, content)
            focusSlot(existing)
        } else {
            addSlot(content: content)
        }
    }

    /// The pane in the active tab that should take `content`, or nil when one must be
    /// split. A pane already showing this kind of surface wins over a blank one, and the
    /// focused pane wins over pane order, so repeated opens keep landing where the person
    /// is already looking.
    private func reusableSlotID(for content: SlotContent) -> UUID? {
        guard let tab = catalog.activeTab else { return nil }
        let candidates = tab.slots.filter { $0.content.yieldsPane(to: content) }

        func preferred(_ slots: [WorkspaceSlot]) -> UUID? {
            if let active = tab.activeSlotID,
               slots.contains(where: { $0.id == active })
            {
                return active
            }
            return slots.first?.id
        }

        return preferred(candidates.filter { $0.content != .empty })
            ?? preferred(candidates)
    }

    public func moveSlotToNewTab(_ id: UUID) {
        apply { $0.moveSlotToNewTab(id) }
    }

    public func moveSlot(_ id: UUID, toTab targetTabID: UUID) {
        apply { $0.moveSlot(id, toTab: targetTabID) }
    }

    public func moveSlot(_ id: UUID, toTab targetTabID: UUID, at rect: GridRect) {
        apply { $0.moveSlot(id, toTab: targetTabID, at: rect) }
    }

    public func moveSlot(
        _ id: UUID,
        toTab targetTabID: UUID,
        beside targetSlotID: UUID,
        edge: SpatialDropEdge
    ) {
        apply {
            $0.moveSlot(
                id,
                toTab: targetTabID,
                beside: targetSlotID,
                edge: edge
            )
        }
    }

    public func applyMove(_ transaction: SpatialLayoutTransaction) {
        apply { $0.applyMove(transaction) }
    }

    public func applySwap(_ transaction: SpatialLayoutTransaction) {
        apply { $0.applySwap(transaction) }
    }

    public func applyResize(_ transaction: ResizeLayoutTransaction) {
        apply { $0.applyResize(transaction) }
    }

    public func fillSlotWidth(_ id: UUID) {
        apply { $0.fillSlotWidth(id) }
    }

    public func resizeSlot(
        _ id: UUID,
        direction: ResizeDirection,
        fraction: SpatialExtentFraction
    ) {
        apply { $0.resizeSlot(id, direction: direction, fraction: fraction) }
    }

    public func cycleSlotExtent(_ id: UUID, direction: ResizeDirection) {
        apply { $0.cycleSlotExtent(id, direction: direction) }
    }

    /// "Did anything change?" — the answer almost every mutation wants, projected from the
    /// facts `applyEvents` returns.
    @discardableResult
    private func apply(_ mutation: (inout WorkspaceCatalog) -> [WorkspaceEvent]) -> Bool {
        !applyEvents(mutation).isEmpty
    }

    private func applyEvents(
        _ mutation: (inout WorkspaceCatalog) -> [WorkspaceEvent]
    ) -> [WorkspaceEvent] {
        var next = catalog
        let events = mutation(&next)
        guard !events.isEmpty else { return [] }
        catalog = next
        snapshotID = UUID()
        // Assigned only on a real change: an unconditional write would republish this on
        // every tab and slot mutation, which is exactly the churn it exists to avoid.
        let folders = WorkspaceStore.folders(in: next)
        if folders != openWorkspaceFolders { openWorkspaceFolders = folders }
        onEvents?(events, next)
        return events
    }

    /// File `content` into the recents of the workspace the mutation's own events name.
    ///
    /// The events are the authority, not `activeWorkspaceID`: `setSlotContent` addresses a
    /// pane anywhere in the catalog, so filling an empty pane in an unselected workspace must
    /// land in that workspace's list. A mutation that changed nothing emits nothing and
    /// records nothing, and a workspace that vanished between the mutation and this line
    /// records nothing either — there is no fallback target, because every fallback would be
    /// some other workspace.
    private func recordRecent(_ content: SlotContent, from events: [WorkspaceEvent]) {
        guard let recent, let workspaceID = events.first?.workspaceID,
              let workspace = catalog.workspaces.first(where: { $0.id == workspaceID })
        else { return }
        recent.record(content, for: workspaceID, root: workspace.path)
    }

    /// Opening changes recency; editing presentation does not. These two helpers keep that
    /// distinction at the typed store edge instead of asking SwiftUI call sites to remember
    /// which persistence operation a workspace mutation deserves.
    private func recordRecentWorkspace(_ id: UUID) {
        guard let workspace = catalog.workspaces.first(where: { $0.id == id }) else { return }
        recentWorkspaces?.record(
            name: workspace.name,
            path: workspace.path,
            appearance: workspace.appearance
        )
    }

    private func updateRecentWorkspaceIdentity(_ id: UUID) {
        guard let workspace = catalog.workspaces.first(where: { $0.id == id }) else { return }
        recentWorkspaces?.updateIdentity(
            name: workspace.name,
            path: workspace.path,
            appearance: workspace.appearance
        )
    }

    private static func folders(in catalog: WorkspaceCatalog) -> Set<String> {
        Set(catalog.workspaces.map { RecentWorkspaceStore.folderKey($0.path) })
    }
}

public extension PluginHost {
    func emit(
        workspaceEvents events: [WorkspaceEvent],
        in snapshot: WorkspaceCatalog
    ) async {
        guard !events.isEmpty else {
            return
        }

        for event in events {
            let representation = Self.busRepresentation(of: event)
            await emit(
                event: representation.name,
                payload: representation.payload
            )
        }

        await emit(
            event: "workspace.changed",
            payload: .object([
                "workspaces": .integer(Int64(snapshot.workspaces.count)),
                "tabs": .integer(
                    Int64(
                        snapshot.workspaces.reduce(0) {
                            $0 + $1.tabs.count
                        }
                    )
                ),
                "slots": .integer(Int64(snapshot.allSlotIDs.count)),
                "activeWorkspaceId": .string(
                    snapshot.activeWorkspaceID.uuidString
                ),
            ])
        )
    }

    private static func busRepresentation(
        of event: WorkspaceEvent
    ) -> (name: String, payload: IntentValue) {
        switch event {
        case .workspaceAdded(let workspace):
            return (
                "workspace.added",
                .object([
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .workspaceRemoved(let workspace):
            return (
                "workspace.removed",
                .object([
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .workspaceSelected(let workspace):
            return (
                "workspace.selected",
                .object([
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .workspaceIdentityChanged(let workspace):
            return (
                "workspace.identity-changed",
                .object([
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .workspaceMoved(workspace, from, to):
            return (
                "workspace.moved",
                .object([
                    "workspaceId": .string(workspace.uuidString),
                    "fromIndex": .integer(Int64(from)),
                    "toIndex": .integer(Int64(to)),
                ])
            )

        case .tabOpened(let tab, let workspace):
            return (
                "workspace.tab-opened",
                .object([
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .tabClosed(let tab, let workspace):
            return (
                "workspace.tab-closed",
                .object([
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .tabSelected(let tab, let workspace):
            return (
                "workspace.tab-selected",
                .object([
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .slotOpened(let slot, let tab, let workspace):
            return (
                "workspace.slot-opened",
                .object([
                    "slotId": .string(slot.uuidString),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .slotClosed(let slot, let tab, let workspace):
            return (
                "workspace.slot-closed",
                .object([
                    "slotId": .string(slot.uuidString),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .slotFocused(let slot, let tab, let workspace):
            return (
                "workspace.slot-focused",
                .object([
                    "slotId": .string(slot.uuidString),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotSplit(
            original,
            new,
            axis,
            tab,
            workspace
        ):
            return (
                "workspace.slot-split",
                .object([
                    "slotId": .string(original.uuidString),
                    "newSlotId": .string(new.uuidString),
                    "axis": .string(axis.busValue),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case .slotsMoved(let slots, let tab, let workspace):
            return (
                "workspace.slots-moved",
                .object([
                    "slotIds": .array(
                        slots.map {
                            .string($0.uuidString)
                        }
                    ),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotsSwapped(
            first,
            second,
            tab,
            workspace
        ):
            return (
                "workspace.slots-swapped",
                .object([
                    "firstSlotId": .string(first.uuidString),
                    "secondSlotId": .string(second.uuidString),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotsResized(
            slots,
            detached,
            tab,
            workspace
        ):
            return (
                "workspace.slots-resized",
                .object([
                    "slotIds": .array(
                        slots.map {
                            .string($0.uuidString)
                        }
                    ),
                    "detached": .bool(detached),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotContentChanged(
            slot,
            content,
            tab,
            workspace
        ):
            return (
                "workspace.slot-content-changed",
                .object([
                    "slotId": .string(slot.uuidString),
                    "content": .string(content.busValue),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotIdentityChanged(slot, tab, workspace):
            return (
                "workspace.slot-identity-changed",
                .object([
                    "slotId": .string(slot.uuidString),
                    "tabId": .string(tab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .slotMovedToTab(
            slot,
            fromTab,
            toTab,
            workspace
        ):
            return (
                "workspace.slot-moved-to-tab",
                .object([
                    "slotId": .string(slot.uuidString),
                    "fromTabId": .string(fromTab.uuidString),
                    "toTabId": .string(toTab.uuidString),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )

        case let .tabMoved(tab, from, to, workspace):
            return (
                "workspace.tab-moved",
                .object([
                    "tabId": .string(tab.uuidString),
                    "fromIndex": .integer(Int64(from)),
                    "toIndex": .integer(Int64(to)),
                    "workspaceId": .string(workspace.uuidString),
                ])
            )
        }
    }
}

private extension SplitAxis {
    var busValue: String {
        switch self {
        case .horizontal:
            "horizontal"
        case .vertical:
            "vertical"
        }
    }
}
