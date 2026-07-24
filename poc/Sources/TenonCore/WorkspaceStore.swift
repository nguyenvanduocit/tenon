import Foundation
import Observation

@Observable
public final class WorkspaceStore {
    public private(set) var catalog: WorkspaceCatalog

    @ObservationIgnored
    public var onEvents: ((
        _ events: [WorkspaceEvent],
        _ snapshot: WorkspaceCatalog
    ) -> Void)?

    public init(catalog: WorkspaceCatalog = WorkspaceCatalog()) {
        self.catalog = catalog
    }

    public func addWorkspace(name: String, path: URL) {
        apply { $0.addWorkspace(name: name, path: path) }
    }

    public func removeWorkspace(_ id: UUID) {
        apply { $0.removeWorkspace(id) }
    }

    public func selectWorkspace(_ id: UUID) {
        apply { $0.selectWorkspace(id) }
    }

    public func newTab() {
        apply { $0.newTab() }
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
        apply { $0.addSlot(content: content) }
    }

    public func splitActiveSlot(
        _ axis: SplitAxis,
        content: SlotContent = .terminal
    ) {
        apply { $0.splitActiveSlot(axis, content: content) }
    }

    public func splitSlot(
        _ id: UUID,
        _ axis: SplitAxis,
        content: SlotContent = .terminal
    ) {
        apply { $0.splitSlot(id, axis, content: content) }
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
        apply { $0.setSlotContent(id, content) }
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

    private func apply(_ mutation: (inout WorkspaceCatalog) -> [WorkspaceEvent]) {
        var next = catalog
        let events = mutation(&next)
        guard !events.isEmpty else { return }
        catalog = next
        onEvents?(events, next)
    }
}

public extension PluginHost {
    func emit(
        workspaceEvents events: [WorkspaceEvent],
        in snapshot: WorkspaceCatalog
    ) {
        guard !events.isEmpty else { return }

        for event in events {
            let representation = Self.busRepresentation(of: event)
            emit(event: representation.name, payload: representation.payload)
        }

        emit(event: "workspace.changed", payload: [
            "workspaces": snapshot.workspaces.count,
            "tabs": snapshot.workspaces.reduce(0) { $0 + $1.tabs.count },
            "slots": snapshot.allSlotIDs.count,
            "activeWorkspaceId": snapshot.activeWorkspaceID.uuidString,
        ])
    }

    private static func busRepresentation(
        of event: WorkspaceEvent
    ) -> (name: String, payload: [String: Any]) {
        switch event {
        case .workspaceAdded(let workspace):
            return (
                "workspace.added",
                ["workspaceId": workspace.uuidString]
            )

        case .workspaceRemoved(let workspace):
            return (
                "workspace.removed",
                ["workspaceId": workspace.uuidString]
            )

        case .workspaceSelected(let workspace):
            return (
                "workspace.selected",
                ["workspaceId": workspace.uuidString]
            )

        case .tabOpened(let tab, let workspace):
            return (
                "workspace.tab-opened",
                [
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .tabClosed(let tab, let workspace):
            return (
                "workspace.tab-closed",
                [
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .tabSelected(let tab, let workspace):
            return (
                "workspace.tab-selected",
                [
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotOpened(let slot, let tab, let workspace):
            return (
                "workspace.slot-opened",
                [
                    "slotId": slot.uuidString,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotClosed(let slot, let tab, let workspace):
            return (
                "workspace.slot-closed",
                [
                    "slotId": slot.uuidString,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotFocused(let slot, let tab, let workspace):
            return (
                "workspace.slot-focused",
                [
                    "slotId": slot.uuidString,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotSplit(let original, let new, let axis, let tab, let workspace):
            return (
                "workspace.slot-split",
                [
                    "slotId": original.uuidString,
                    "newSlotId": new.uuidString,
                    "axis": axis.busValue,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotsMoved(let slots, let tab, let workspace):
            return (
                "workspace.slots-moved",
                [
                    "slotIds": slots.map(\.uuidString),
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotsSwapped(let first, let second, let tab, let workspace):
            return (
                "workspace.slots-swapped",
                [
                    "firstSlotId": first.uuidString,
                    "secondSlotId": second.uuidString,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotsResized(let slots, let detached, let tab, let workspace):
            return (
                "workspace.slots-resized",
                [
                    "slotIds": slots.map(\.uuidString),
                    "detached": detached,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotContentChanged(let slot, let content, let tab, let workspace):
            return (
                "workspace.slot-content-changed",
                [
                    "slotId": slot.uuidString,
                    "content": content.busValue,
                    "tabId": tab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )

        case .slotMovedToTab(let slot, let fromTab, let toTab, let workspace):
            return (
                "workspace.slot-moved-to-tab",
                [
                    "slotId": slot.uuidString,
                    "fromTabId": fromTab.uuidString,
                    "toTabId": toTab.uuidString,
                    "workspaceId": workspace.uuidString,
                ]
            )
        }
    }
}

private extension SplitAxis {
    var busValue: String {
        switch self {
        case .horizontal:
            return "horizontal"
        case .vertical:
            return "vertical"
        }
    }
}
