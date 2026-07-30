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

    /// Opened views are recorded here so the empty-tab launcher can offer a
    /// "recently opened" list. Nil in headless tests that don't exercise it.
    public let recent: RecentStore?

    /// Opened workspaces are recorded here so the sidebar's Add-Workspace menu can
    /// offer them again after they're closed. Nil in headless tests that skip it.
    public let recentWorkspaces: RecentWorkspaceStore?

    public init(
        catalog: WorkspaceCatalog = WorkspaceCatalog(),
        recent: RecentStore? = nil,
        recentWorkspaces: RecentWorkspaceStore? = nil
    ) {
        self.catalog = catalog
        self.recent = recent
        self.recentWorkspaces = recentWorkspaces
    }

    public func addWorkspace(name: String, path: URL, content: SlotContent? = nil) {
        if apply({ $0.addWorkspace(name: name, path: path, content: content ?? newWorkspaceContentProvider()) }) {
            recentWorkspaces?.record(name: name, path: path)
        }
    }

    public func removeWorkspace(_ id: UUID) {
        apply { $0.removeWorkspace(id) }
    }

    public func selectWorkspace(_ id: UUID) {
        apply { $0.selectWorkspace(id) }
    }

    public func newTab(content: SlotContent? = nil) {
        let resolved = content ?? newTabContentProvider()
        if apply({ $0.newTab(content: resolved) }) { recent?.record(resolved) }
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

    public func addSlot(content: SlotContent = .terminal) {
        if apply({ $0.addSlot(content: content) }) { recent?.record(content) }
    }

    public func splitActiveSlot(
        _ axis: SplitAxis,
        content: SlotContent? = nil
    ) {
        let resolved = content ?? newSplitContentProvider()
        if apply({ $0.splitActiveSlot(axis, content: resolved) }) { recent?.record(resolved) }
    }

    public func splitSlot(
        _ id: UUID,
        _ axis: SplitAxis,
        content: SlotContent? = nil
    ) {
        let resolved = content ?? newSplitContentProvider()
        if apply({ $0.splitSlot(id, axis, content: resolved) }) { recent?.record(resolved) }
    }

    public func closeSlot(_ id: UUID) {
        apply { $0.closeSlot(id) }
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
        if apply({ $0.setSlotContent(id, content) }) { recent?.record(content) }
    }

    /// Shows `request` in the active tab: reuses an existing diff pane if one is
    /// already open there (so clicking file after file changes the same pane), and
    /// otherwise splits the active slot to make one — never opens a new tab.
    public func showDiff(_ request: DiffRequest) {
        let content = SlotContent.diff(request)
        if let existing = catalog.activeTab?.slots.first(where: {
            if case .diff = $0.content { return true }
            return false
        }) {
            setSlotContent(existing.id, content)
            focusSlot(existing.id)
        } else {
            splitActiveSlot(.horizontal, content: content)
        }
    }

    public func moveSlotToNewTab(_ id: UUID) {
        apply { $0.moveSlotToNewTab(id) }
    }

    public func moveSlot(_ id: UUID, toTab targetTabID: UUID) {
        apply { $0.moveSlot(id, toTab: targetTabID) }
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

    @discardableResult
    private func apply(_ mutation: (inout WorkspaceCatalog) -> [WorkspaceEvent]) -> Bool {
        var next = catalog
        let events = mutation(&next)
        guard !events.isEmpty else { return false }
        catalog = next
        snapshotID = UUID()
        onEvents?(events, next)
        return true
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
        await reconcileViewInstances(from: snapshot)
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
