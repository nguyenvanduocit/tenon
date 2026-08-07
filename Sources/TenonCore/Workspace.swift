// @domain: workspace-model
import Foundation
import TenonIntentCore

public enum SlotContent: Equatable, Sendable {
    case terminal
    case changes
    case docs
    /// The host-native automation operations surface: armed schedules, Run Now,
    /// authoring, and recent delivery evidence.
    case automation
    /// One file open as a pane. Created by `workspace.tab.create.v1` or
    /// `workspace.pane.content.set.v1`; the host owns the native editor.
    case file(path: String)
    case pluginView(pluginID: PluginID, viewID: String)
    /// The host's default diff view, showing the change described by `request`.
    /// Created by `workspace.tab.create.v1` with typed diff content.
    case diff(DiffRequest)
    case empty

    /// Whether a pane already showing `self` is where `content` belongs when the host is
    /// asked to open it. The pane holding a file takes the next file and the pane holding a
    /// diff takes the next diff, a plugin view only ever yields to that same view, and a
    /// blank pane takes anything. This is the rule that keeps browsing a file tree from
    /// burying the workspace in panes.
    public func yieldsPane(to content: SlotContent) -> Bool {
        switch (self, content) {
        case (.empty, _):
            return true
        case (.terminal, .terminal),
             (.changes, .changes),
             (.docs, .docs),
             (.automation, .automation),
             (.file, .file),
             (.diff, .diff):
            return true
        case let (.pluginView(pluginID, viewID), .pluginView(otherPluginID, otherViewID)):
            return pluginID == otherPluginID && viewID == otherViewID
        default:
            return false
        }
    }

    public var busValue: String {
        switch self {
        case .terminal:
            return "terminal"
        case .file(let path):
            return "file:\(path)"
        case .changes:
            return "changes"
        case .docs:
            return "docs"
        case .automation:
            return "automation"
        case .pluginView(let pluginID, let viewID):
            return "plugin-view:\(pluginID.rawValue):\(viewID)"
        case .diff(let request):
            return "diff:\(request.fileName)"
        case .empty:
            return "empty"
        }
    }
}

public struct WorkspaceSlot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var rect: GridRect
    public internal(set) var content: SlotContent

    public init(id: UUID = UUID(), rect: GridRect, content: SlotContent = .terminal) {
        self.id = id
        self.rect = rect
        self.content = content
    }

    public var spatialSlot: SpatialSlot {
        SpatialSlot(id: id, rect: rect)
    }
}

public struct Tab: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var slots: [WorkspaceSlot]
    public internal(set) var activeSlotID: UUID?

    public init(
        id: UUID = UUID(),
        slots: [WorkspaceSlot],
        activeSlotID: UUID?
    ) {
        precondition(
            activeSlotID == nil || slots.contains(where: { $0.id == activeSlotID }),
            "activeSlotID must identify a slot in this tab"
        )
        precondition(
            activeSlotID != nil || slots.isEmpty,
            "a non-empty tab must have an active slot"
        )
        precondition(
            SpatialLayout.isValid(slots.map(\.spatialSlot)),
            "tab slots must form a valid spatial layout"
        )

        self.id = id
        self.slots = slots
        self.activeSlotID = activeSlotID
    }

    public init(id: UUID = UUID(), content: SlotContent = .terminal) {
        let slot = WorkspaceSlot(
            rect: GridRect(
                x: 0,
                y: 0,
                width: SpatialLayout.columns,
                height: SpatialLayout.rows
            ),
            content: content
        )
        self.init(id: id, slots: [slot], activeSlotID: slot.id)
    }

    public var activeSlot: WorkspaceSlot? {
        slots.first { $0.id == activeSlotID }
    }

    public var spatialSlots: [SpatialSlot] {
        slots.map(\.spatialSlot)
    }
}

public struct Workspace: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var name: String
    public internal(set) var path: URL
    public internal(set) var tabs: [Tab]
    public internal(set) var activeTabID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        tabs: [Tab],
        activeTabID: UUID
    ) {
        precondition(
            Self.isValid(tabs: tabs, activeTabID: activeTabID),
            "workspace tabs and slots must have unique identities and valid selection"
        )

        self.id = id
        self.name = name
        self.path = path
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        content: SlotContent = .terminal
    ) {
        let tab = Tab(content: content)
        self.init(
            id: id,
            name: name,
            path: path,
            tabs: [tab],
            activeTabID: tab.id
        )
    }

    public var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    public static func isValid(tabs: [Tab], activeTabID: UUID) -> Bool {
        guard !tabs.isEmpty,
              tabs.contains(where: { $0.id == activeTabID }),
              Set(tabs.map(\.id)).count == tabs.count
        else { return false }

        let slotIDs = tabs.flatMap { $0.slots.map(\.id) }
        guard Set(slotIDs).count == slotIDs.count else { return false }

        return tabs.allSatisfy { tab in
            SpatialLayout.isValid(tab.spatialSlots) &&
                (
                    (tab.slots.isEmpty && tab.activeSlotID == nil) ||
                    tab.slots.contains(where: { $0.id == tab.activeSlotID })
                )
        }
    }
}

public enum WorkspaceEvent: Equatable, Sendable {
    case workspaceAdded(UUID)
    case workspaceRemoved(UUID)
    case workspaceSelected(UUID)
    case tabOpened(tab: UUID, workspace: UUID)
    case tabClosed(tab: UUID, workspace: UUID)
    case tabSelected(tab: UUID, workspace: UUID)
    case slotOpened(slot: UUID, tab: UUID, workspace: UUID)
    case slotClosed(slot: UUID, tab: UUID, workspace: UUID)
    case slotFocused(slot: UUID, tab: UUID, workspace: UUID)
    case slotSplit(
        original: UUID,
        new: UUID,
        axis: SplitAxis,
        tab: UUID,
        workspace: UUID
    )
    case slotsMoved(slots: [UUID], tab: UUID, workspace: UUID)
    case slotsSwapped(first: UUID, second: UUID, tab: UUID, workspace: UUID)
    case slotsResized(
        slots: [UUID],
        detached: Bool,
        tab: UUID,
        workspace: UUID
    )
    case slotContentChanged(
        slot: UUID,
        content: SlotContent,
        tab: UUID,
        workspace: UUID
    )
    case slotMovedToTab(
        slot: UUID,
        fromTab: UUID,
        toTab: UUID,
        workspace: UUID
    )
}

public struct WorkspaceCatalog: Equatable, Sendable {
    public private(set) var workspaces: [Workspace]
    public private(set) var activeWorkspaceID: UUID

    public init(
        name: String = "Workspace 1",
        path: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        content: SlotContent = .terminal
    ) {
        let workspace = Workspace(name: name, path: path, content: content)
        self.workspaces = [workspace]
        self.activeWorkspaceID = workspace.id
    }

    public init(workspaces: [Workspace], activeWorkspaceID: UUID) {
        precondition(
            Self.isValid(
                workspaces: workspaces,
                activeWorkspaceID: activeWorkspaceID
            ),
            "catalog workspace, tab, and slot identities must be globally unique"
        )
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
    }

    public static func isValid(
        workspaces: [Workspace],
        activeWorkspaceID: UUID
    ) -> Bool {
        guard !workspaces.isEmpty,
              workspaces.contains(where: { $0.id == activeWorkspaceID }),
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.allSatisfy({
                  Workspace.isValid(tabs: $0.tabs, activeTabID: $0.activeTabID)
              })
        else { return false }

        let tabIDs = workspaces.flatMap { $0.tabs.map(\.id) }
        let slotIDs = workspaces.flatMap { workspace in
            workspace.tabs.flatMap { $0.slots.map(\.id) }
        }
        return Set(tabIDs).count == tabIDs.count &&
            Set(slotIDs).count == slotIDs.count
    }

    public var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    public var activeTab: Tab? {
        activeWorkspace?.activeTab
    }

    public var activeSlotID: UUID? {
        activeTab?.activeSlotID
    }

    public var allSlotIDs: [UUID] {
        workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots.map(\.id)
            }
        }
    }

    /// Every `.pluginView` slot across all workspaces and tabs, as (slotID, pluginID,
    /// viewID). The host reconciles plugin-view *instances* off this — one live instance
    /// per pane holding a plugin view, keyed by the pane's slot id (T-012). Order is
    /// stable (workspace → tab → slot).
    public var pluginViewSlots: [(slotID: UUID, pluginID: PluginID, viewID: String)] {
        workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots.compactMap {
                    slot -> (slotID: UUID, pluginID: PluginID, viewID: String)? in
                    guard case let .pluginView(pluginID, viewID) = slot.content else {
                        return nil
                    }
                    return (slot.id, pluginID, viewID)
                }
            }
        }
    }

    public func slot(id: UUID) -> WorkspaceSlot? {
        for workspace in workspaces {
            for tab in workspace.tabs {
                if let slot = tab.slots.first(where: { $0.id == id }) {
                    return slot
                }
            }
        }
        return nil
    }

    /// The workspace and tab that own `id`, searched across the whole catalog — a pane in
    /// an unselected workspace resolves exactly like one in the selected workspace, because
    /// a pane's owner is a property of the pane, not of the current selection.
    public func owner(
        ofSlot id: UUID
    ) -> (workspaceID: UUID, workspacePath: URL, tabID: UUID)? {
        for workspace in workspaces {
            for tab in workspace.tabs
            where tab.slots.contains(where: { $0.id == id }) {
                return (workspace.id, workspace.path, tab.id)
            }
        }
        return nil
    }

    @discardableResult
    public mutating func addWorkspace(
        name: String,
        path: URL,
        content: SlotContent = .terminal
    ) -> [WorkspaceEvent] {
        let workspace = Workspace(name: name, path: path, content: content)
        let tab = workspace.tabs[0]
        let slot = tab.slots[0]
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id

        return [
            .workspaceAdded(workspace.id),
            .tabOpened(tab: tab.id, workspace: workspace.id),
            .slotOpened(slot: slot.id, tab: tab.id, workspace: workspace.id),
            .workspaceSelected(workspace.id),
            .tabSelected(tab: tab.id, workspace: workspace.id),
            .slotFocused(slot: slot.id, tab: tab.id, workspace: workspace.id),
        ]
    }

    @discardableResult
    public mutating func selectWorkspace(_ id: UUID) -> [WorkspaceEvent] {
        guard id != activeWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id }),
              let tab = workspace.activeTab
        else { return [] }

        activeWorkspaceID = id
        var events: [WorkspaceEvent] = [
            .workspaceSelected(id),
            .tabSelected(tab: tab.id, workspace: id),
        ]
        if let slotID = tab.activeSlotID {
            events.append(.slotFocused(slot: slotID, tab: tab.id, workspace: id))
        }
        return events
    }

    /// Drop a workspace, keeping at least one alive so the catalog stays valid.
    /// The teardown is fully described in events (slot/tab closures) exactly like
    /// `closeTab`, and removing the active workspace re-selects a neighbor.
    @discardableResult
    public mutating func removeWorkspace(_ id: UUID) -> [WorkspaceEvent] {
        guard workspaces.count > 1,
              let index = workspaces.firstIndex(where: { $0.id == id })
        else { return [] }

        let wasActive = id == activeWorkspaceID
        let removed = workspaces.remove(at: index)

        var events: [WorkspaceEvent] = []
        for tab in removed.tabs {
            for slot in tab.slots {
                events.append(.slotClosed(slot: slot.id, tab: tab.id, workspace: removed.id))
            }
            events.append(.tabClosed(tab: tab.id, workspace: removed.id))
        }
        events.append(.workspaceRemoved(removed.id))

        if wasActive {
            let next = workspaces[min(index, workspaces.count - 1)]
            activeWorkspaceID = next.id
            events.append(.workspaceSelected(next.id))
            if let tab = next.activeTab {
                events.append(.tabSelected(tab: tab.id, workspace: next.id))
                if let slotID = tab.activeSlotID {
                    events.append(.slotFocused(slot: slotID, tab: tab.id, workspace: next.id))
                }
            }
        }

        return events
    }

    @discardableResult
    public mutating func newTab(content: SlotContent = .terminal) -> [WorkspaceEvent] {
        guard let workspaceIndex = activeWorkspaceIndex else { return [] }
        let workspaceID = workspaces[workspaceIndex].id
        let tab = Tab(content: content)
        let slot = tab.slots[0]

        workspaces[workspaceIndex].tabs.append(tab)
        workspaces[workspaceIndex].activeTabID = tab.id

        return [
            .tabOpened(tab: tab.id, workspace: workspaceID),
            .slotOpened(slot: slot.id, tab: tab.id, workspace: workspaceID),
            .tabSelected(tab: tab.id, workspace: workspaceID),
            .slotFocused(slot: slot.id, tab: tab.id, workspace: workspaceID),
        ]
    }

    @discardableResult
    public mutating func selectTab(_ id: UUID) -> [WorkspaceEvent] {
        guard let workspaceIndex = activeWorkspaceIndex,
              id != workspaces[workspaceIndex].activeTabID,
              let tab = workspaces[workspaceIndex].tabs.first(where: { $0.id == id })
        else { return [] }

        let workspaceID = workspaces[workspaceIndex].id
        workspaces[workspaceIndex].activeTabID = id
        var events: [WorkspaceEvent] = [
            .tabSelected(tab: id, workspace: workspaceID),
        ]
        if let slotID = tab.activeSlotID {
            events.append(.slotFocused(slot: slotID, tab: id, workspace: workspaceID))
        }
        return events
    }

    @discardableResult
    public mutating func selectNextTab() -> [WorkspaceEvent] {
        selectTab(offsetBy: 1)
    }

    @discardableResult
    public mutating func selectPreviousTab() -> [WorkspaceEvent] {
        selectTab(offsetBy: -1)
    }

    @discardableResult
    public mutating func closeTab(_ id: UUID) -> [WorkspaceEvent] {
        closeTab(id, in: activeWorkspaceID)
    }

    /// Closes a tab in a named workspace without selecting that workspace. This is used
    /// by host-owned placement cleanup that may finish after the human navigates away.
    @discardableResult
    public mutating func closeTab(_ id: UUID, in workspaceID: UUID) -> [WorkspaceEvent] {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[workspaceIndex].tabs.count > 1,
              let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == id })
        else { return [] }

        let workspaceIsActive = activeWorkspaceID == workspaceID
        let removed = workspaces[workspaceIndex].tabs.remove(at: tabIndex)
        var events = removed.slots.map {
            WorkspaceEvent.slotClosed(slot: $0.id, tab: removed.id, workspace: workspaceID)
        }
        events.append(.tabClosed(tab: removed.id, workspace: workspaceID))

        if workspaces[workspaceIndex].activeTabID == id {
            let nextIndex = max(0, tabIndex - 1)
            let next = workspaces[workspaceIndex].tabs[nextIndex]
            workspaces[workspaceIndex].activeTabID = next.id
            if workspaceIsActive {
                events.append(.tabSelected(tab: next.id, workspace: workspaceID))
                if let slotID = next.activeSlotID {
                    events.append(.slotFocused(
                        slot: slotID,
                        tab: next.id,
                        workspace: workspaceID
                    ))
                }
            }
        }

        return events
    }

    @discardableResult
    public mutating func addSlot(content: SlotContent = .terminal) -> [WorkspaceEvent] {
        openSlot(content: content, near: activeTab?.activeSlotID)
    }

    /// Adds one pane at the exact empty grid rectangle selected by the caller. This is
    /// the targeted counterpart to `addSlot(content:)`, whose placement policy chooses
    /// the best available region on its own.
    @discardableResult
    public mutating func addSlot(
        id: UUID,
        content: SlotContent,
        at rect: GridRect
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation,
              slot(id: id) == nil
        else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        let proposal = tab.spatialSlots + [SpatialSlot(id: id, rect: rect)]
        guard SpatialLayout.isValid(proposal) else { return [] }

        let slot = WorkspaceSlot(id: id, rect: rect, content: content)
        workspaces[location.workspace].tabs[location.tab].slots.append(slot)
        workspaces[location.workspace].tabs[location.tab].activeSlotID = id
        let workspaceID = workspaces[location.workspace].id
        return [
            .slotOpened(slot: id, tab: tab.id, workspace: workspaceID),
            .slotFocused(slot: id, tab: tab.id, workspace: workspaceID),
        ]
    }

    /// Removes an untouched launcher reservation without asking neighbouring panes to
    /// absorb it. The surrounding geometry therefore returns to the exact pre-click
    /// layout instead of expanding as an ordinary pane close would.
    @discardableResult
    public mutating func discardEmptySlot(
        _ id: UUID,
        restoringFocusTo previousSlotID: UUID?
    ) -> [WorkspaceEvent] {
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices {
                let tab = workspaces[workspaceIndex].tabs[tabIndex]
                guard let slotIndex = tab.slots.firstIndex(where: { $0.id == id }),
                      tab.slots[slotIndex].content == .empty
                else { continue }

                var slots = tab.slots
                slots.remove(at: slotIndex)
                var activeSlotID = tab.activeSlotID
                if activeSlotID == id {
                    activeSlotID = previousSlotID.flatMap { previous in
                        slots.contains(where: { $0.id == previous }) ? previous : nil
                    } ?? slots.first?.id
                }
                workspaces[workspaceIndex].tabs[tabIndex].slots = slots
                workspaces[workspaceIndex].tabs[tabIndex].activeSlotID = activeSlotID

                let workspaceID = workspaces[workspaceIndex].id
                var events: [WorkspaceEvent] = [
                    .slotClosed(slot: id, tab: tab.id, workspace: workspaceID),
                ]
                if let activeSlotID,
                   activeSlotID != tab.activeSlotID,
                   activeWorkspaceID == workspaceID,
                   workspaces[workspaceIndex].activeTabID == tab.id
                {
                    events.append(.slotFocused(
                        slot: activeSlotID,
                        tab: tab.id,
                        workspace: workspaceID
                    ))
                }
                return events
            }
        }
        return []
    }

    /// A second pane showing what `id` shows. Placement is the same policy `addSlot` uses,
    /// anchored on the duplicated pane rather than the focused one, so duplicating a pane
    /// nobody is looking at never resizes the pane they are.
    @discardableResult
    public mutating func duplicateSlot(_ id: UUID) -> [WorkspaceEvent] {
        guard let content = activeTab?.slots.first(where: { $0.id == id })?.content
        else { return [] }
        return openSlot(content: content, near: id)
    }

    /// Whether `duplicateSlot(_:)` would produce a pane: free canvas exists, or the pane is
    /// big enough to split along one axis. The header menu asks so it can grey the item out
    /// instead of offering a click that does nothing.
    public func canDuplicateSlot(_ id: UUID) -> Bool {
        guard let tab = activeTab,
              let slot = tab.slots.first(where: { $0.id == id })
        else { return false }
        if SpatialLayout.bestEmptyRect(in: tab.spatialSlots, near: id) != nil { return true }
        return slot.rect.width >= SpatialLayout.minimumWidth * 2 ||
            slot.rect.height >= SpatialLayout.minimumHeight * 2
    }

    /// Where a new pane goes: the free canvas next to `anchor` when the layout has any,
    /// otherwise `anchor` splits along the axis that still fits.
    @discardableResult
    private mutating func openSlot(
        content: SlotContent,
        near anchor: UUID?
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let current = workspaces[location.workspace].tabs[location.tab]
        let newSlotID = UUID()

        if current.slots.isEmpty {
            let slot = WorkspaceSlot(
                id: newSlotID,
                rect: fullGridRect,
                content: content
            )
            workspaces[location.workspace].tabs[location.tab].slots = [slot]
            workspaces[location.workspace].tabs[location.tab].activeSlotID = slot.id
            return [
                .slotOpened(
                    slot: slot.id,
                    tab: current.id,
                    workspace: workspaces[location.workspace].id
                ),
                .slotFocused(
                    slot: slot.id,
                    tab: current.id,
                    workspace: workspaces[location.workspace].id
                ),
            ]
        }

        if let rect = SpatialLayout.bestEmptyRect(
            in: current.spatialSlots,
            near: anchor
        ) {
            let slot = WorkspaceSlot(id: newSlotID, rect: rect, content: content)
            workspaces[location.workspace].tabs[location.tab].slots.append(slot)
            workspaces[location.workspace].tabs[location.tab].activeSlotID = slot.id
            return [
                .slotOpened(
                    slot: slot.id,
                    tab: current.id,
                    workspace: workspaces[location.workspace].id
                ),
                .slotFocused(
                    slot: slot.id,
                    tab: current.id,
                    workspace: workspaces[location.workspace].id
                ),
            ]
        }

        guard let anchor,
              let anchorSlot = current.slots.first(where: { $0.id == anchor })
        else { return [] }
        let axis: SplitAxis =
            anchorSlot.rect.width < SpatialLayout.minimumWidth * 2 &&
            anchorSlot.rect.height >= SpatialLayout.minimumHeight * 2
                ? .vertical
                : .horizontal
        return splitSlot(anchor, axis, content: content)
    }

    @discardableResult
    public mutating func splitActiveSlot(
        _ axis: SplitAxis,
        content: SlotContent = .terminal
    ) -> [WorkspaceEvent] {
        guard let activeSlotID = activeTab?.activeSlotID else { return [] }
        return splitSlot(activeSlotID, axis, content: content)
    }

    /// Split a specific slot in the active tab, mirroring `closeSlot(_:)`'s
    /// id-targeted shape so callers (a pane's context menu, a keybinding) can act
    /// on any slot without first stealing focus. The new slot becomes active.
    @discardableResult
    public mutating func splitSlot(
        _ id: UUID,
        _ axis: SplitAxis,
        content: SlotContent = .terminal
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard tab.slots.contains(where: { $0.id == id }) else { return [] }
        let newSlotID = UUID()
        guard let transaction = SpatialLayout.split(
            tab.spatialSlots,
            slotID: id,
            newSlotID: newSlotID,
            axis: axis
        ) else { return [] }

        let rects = Dictionary(
            uniqueKeysWithValues: transaction.proposal.map { ($0.id, $0.rect) }
        )
        var slots = tab.slots.map { slot -> WorkspaceSlot in
            var updated = slot
            updated.rect = rects[slot.id]!
            return updated
        }
        guard let newRect = rects[newSlotID] else { return [] }
        slots.append(WorkspaceSlot(id: newSlotID, rect: newRect, content: content))

        workspaces[location.workspace].tabs[location.tab].slots = slots
        workspaces[location.workspace].tabs[location.tab].activeSlotID = newSlotID
        let workspaceID = workspaces[location.workspace].id
        return [
            .slotOpened(slot: newSlotID, tab: tab.id, workspace: workspaceID),
            .slotSplit(
                original: id,
                new: newSlotID,
                axis: axis,
                tab: tab.id,
                workspace: workspaceID
            ),
            .slotFocused(slot: newSlotID, tab: tab.id, workspace: workspaceID),
        ]
    }

    @discardableResult
    public mutating func closeSlot(_ id: UUID) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let removedIndex = tab.slots.firstIndex(where: { $0.id == id }),
              let transaction = SpatialLayout.close(tab.spatialSlots, slotID: id)
        else { return [] }

        let remainingByID = Dictionary(
            uniqueKeysWithValues: tab.slots
                .filter { $0.id != id }
                .map { ($0.id, $0) }
        )
        let slots = transaction.proposal.map { spatial -> WorkspaceSlot in
            var slot = remainingByID[spatial.id]!
            slot.rect = spatial.rect
            return slot
        }
        var activeSlotID = tab.activeSlotID
        if activeSlotID == id {
            if let absorbingSlotID = transaction.absorbedSlotIDs.first(
                where: { absorbedID in slots.contains { $0.id == absorbedID } }
            ) {
                activeSlotID = absorbingSlotID
            } else if slots.isEmpty {
                activeSlotID = nil
            } else {
                activeSlotID = slots[max(0, min(removedIndex - 1, slots.count - 1))].id
            }
        }

        workspaces[location.workspace].tabs[location.tab].slots = slots
        workspaces[location.workspace].tabs[location.tab].activeSlotID = activeSlotID
        let workspaceID = workspaces[location.workspace].id
        var events: [WorkspaceEvent] = [
            .slotClosed(slot: id, tab: tab.id, workspace: workspaceID),
        ]
        if !transaction.absorbedSlotIDs.isEmpty {
            events.append(.slotsResized(
                slots: transaction.absorbedSlotIDs,
                detached: false,
                tab: tab.id,
                workspace: workspaceID
            ))
        }
        if let activeSlotID, activeSlotID != tab.activeSlotID {
            events.append(.slotFocused(
                slot: activeSlotID,
                tab: tab.id,
                workspace: workspaceID
            ))
        }
        return events
    }

    @discardableResult
    public mutating func focusSlot(_ id: UUID) -> [WorkspaceEvent] {
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices {
                guard workspaces[workspaceIndex].tabs[tabIndex].slots.contains(
                    where: { $0.id == id }
                ) else { continue }

                let workspaceID = workspaces[workspaceIndex].id
                let tabID = workspaces[workspaceIndex].tabs[tabIndex].id
                let isAlreadyFocused =
                    activeWorkspaceID == workspaceID &&
                    workspaces[workspaceIndex].activeTabID == tabID &&
                    workspaces[workspaceIndex].tabs[tabIndex].activeSlotID == id
                guard !isAlreadyFocused else { return [] }

                var events: [WorkspaceEvent] = []
                let changedWorkspace = activeWorkspaceID != workspaceID
                if changedWorkspace {
                    activeWorkspaceID = workspaceID
                    events.append(.workspaceSelected(workspaceID))
                }
                if changedWorkspace || workspaces[workspaceIndex].activeTabID != tabID {
                    workspaces[workspaceIndex].activeTabID = tabID
                    events.append(.tabSelected(tab: tabID, workspace: workspaceID))
                }
                workspaces[workspaceIndex].tabs[tabIndex].activeSlotID = id
                events.append(.slotFocused(slot: id, tab: tabID, workspace: workspaceID))
                return events
            }
        }
        return []
    }

    @discardableResult
    public mutating func focusNextSlot() -> [WorkspaceEvent] {
        focusSlot(offsetBy: 1)
    }

    @discardableResult
    public mutating func focusPreviousSlot() -> [WorkspaceEvent] {
        focusSlot(offsetBy: -1)
    }

    @discardableResult
    public mutating func setSlotContent(
        _ id: UUID,
        _ content: SlotContent
    ) -> [WorkspaceEvent] {
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices {
                guard let slotIndex = workspaces[workspaceIndex].tabs[tabIndex].slots
                    .firstIndex(where: { $0.id == id }),
                    workspaces[workspaceIndex].tabs[tabIndex].slots[slotIndex].content != content
                else { continue }

                workspaces[workspaceIndex].tabs[tabIndex].slots[slotIndex].content = content
                return [
                    .slotContentChanged(
                        slot: id,
                        content: content,
                        tab: workspaces[workspaceIndex].tabs[tabIndex].id,
                        workspace: workspaces[workspaceIndex].id
                    ),
                ]
            }
        }
        return []
    }

    /// Pop a slot out of its current tab into a brand-new tab, keeping the slot's
    /// identity (so its terminal surface survives) and content. The source tab
    /// reflows exactly like `closeSlot`; moving a tab's only slot leaves that tab
    /// empty (a valid state). The new tab becomes active and the moved slot focused.
    @discardableResult
    public mutating func moveSlotToNewTab(_ slotID: UUID) -> [WorkspaceEvent] {
        guard let source = location(ofSlot: slotID) else { return [] }
        let sourceTabID = workspaces[source.workspace].tabs[source.tab].id
        let workspaceID = workspaces[source.workspace].id
        guard let detached = detachSlot(slotID, at: source) else { return [] }

        let movedSlot = WorkspaceSlot(
            id: detached.slot.id,
            rect: fullGridRect,
            content: detached.slot.content
        )
        let newTab = Tab(slots: [movedSlot], activeSlotID: movedSlot.id)
        workspaces[source.workspace].tabs.append(newTab)
        workspaces[source.workspace].activeTabID = newTab.id

        var events: [WorkspaceEvent] = []
        if !detached.resized.isEmpty {
            events.append(.slotsResized(
                slots: detached.resized,
                detached: false,
                tab: sourceTabID,
                workspace: workspaceID
            ))
        }
        events.append(.tabOpened(tab: newTab.id, workspace: workspaceID))
        events.append(.slotMovedToTab(
            slot: movedSlot.id,
            fromTab: sourceTabID,
            toTab: newTab.id,
            workspace: workspaceID
        ))
        events.append(.tabSelected(tab: newTab.id, workspace: workspaceID))
        events.append(.slotFocused(
            slot: movedSlot.id,
            tab: newTab.id,
            workspace: workspaceID
        ))
        return events
    }

    /// Move a slot into an existing tab of the active workspace, placing it exactly
    /// as `addSlot` would (largest empty rect, else split the target's active slot).
    /// The slot keeps its identity + content; the source tab reflows like `closeSlot`.
    /// The target tab becomes active and the moved slot focused. No-op when the slot
    /// or target is unknown, or the target is the slot's own tab.
    @discardableResult
    public mutating func moveSlot(
        _ slotID: UUID,
        toTab targetTabID: UUID
    ) -> [WorkspaceEvent] {
        guard let source = location(ofSlot: slotID),
              let targetIndex = workspaces[source.workspace].tabs.firstIndex(
                  where: { $0.id == targetTabID }
              ),
              workspaces[source.workspace].tabs[source.tab].id != targetTabID
        else { return [] }

        let workspaceID = workspaces[source.workspace].id
        let sourceTabID = workspaces[source.workspace].tabs[source.tab].id
        let didSelectTarget = workspaces[source.workspace].activeTabID != targetTabID
        let content = workspaces[source.workspace].tabs[source.tab]
            .slots.first { $0.id == slotID }!.content

        // Placement is computed on the target's current layout before detaching, so a
        // slot that cannot be placed leaves the whole catalog untouched.
        guard let placement = placement(
            forSlot: slotID,
            content: content,
            in: workspaces[source.workspace].tabs[targetIndex]
        ) else { return [] }
        guard let detached = detachSlot(slotID, at: source) else { return [] }

        workspaces[source.workspace].tabs[targetIndex].slots = placement.slots
        workspaces[source.workspace].tabs[targetIndex].activeSlotID = slotID
        workspaces[source.workspace].activeTabID = targetTabID

        var events: [WorkspaceEvent] = []
        if !detached.resized.isEmpty {
            events.append(.slotsResized(
                slots: detached.resized,
                detached: false,
                tab: sourceTabID,
                workspace: workspaceID
            ))
        }
        events.append(.slotMovedToTab(
            slot: slotID,
            fromTab: sourceTabID,
            toTab: targetTabID,
            workspace: workspaceID
        ))
        if !placement.changed.isEmpty {
            events.append(.slotsResized(
                slots: placement.changed,
                detached: false,
                tab: targetTabID,
                workspace: workspaceID
            ))
        }
        if didSelectTarget {
            events.append(.tabSelected(tab: targetTabID, workspace: workspaceID))
        }
        events.append(.slotFocused(
            slot: slotID,
            tab: targetTabID,
            workspace: workspaceID
        ))
        return events
    }

    /// Move a slot into an existing tab at the edge selected on that tab's visible
    /// canvas. The destination layout is resolved before the source is detached, so an
    /// invalid or stale target leaves both tabs unchanged.
    @discardableResult
    public mutating func moveSlot(
        _ slotID: UUID,
        toTab targetTabID: UUID,
        beside targetSlotID: UUID,
        edge: SpatialDropEdge
    ) -> [WorkspaceEvent] {
        guard let source = location(ofSlot: slotID),
              let targetIndex = workspaces[source.workspace].tabs.firstIndex(
                  where: { $0.id == targetTabID }
              ),
              workspaces[source.workspace].tabs[source.tab].id != targetTabID
        else { return [] }

        let targetTab = workspaces[source.workspace].tabs[targetIndex]
        guard let insertion = SpatialLayout.insertBeside(
            targetTab.spatialSlots,
            newSlotID: slotID,
            targetID: targetSlotID,
            edge: edge
        ) else { return [] }

        let workspaceID = workspaces[source.workspace].id
        let sourceTabID = workspaces[source.workspace].tabs[source.tab].id
        let didSelectTarget = workspaces[source.workspace].activeTabID != targetTabID
        let content = workspaces[source.workspace].tabs[source.tab]
            .slots.first { $0.id == slotID }!.content
        let targetSlotsByID = Dictionary(
            uniqueKeysWithValues: targetTab.slots.map { ($0.id, $0) }
        )
        let changedTargetIDs = insertion.proposal.compactMap { spatial -> UUID? in
            guard spatial.id != slotID,
                  targetSlotsByID[spatial.id]?.rect != spatial.rect
            else { return nil }
            return spatial.id
        }

        guard let detached = detachSlot(slotID, at: source) else { return [] }

        workspaces[source.workspace].tabs[targetIndex].slots = insertion.proposal.map {
            spatial in
            if spatial.id == slotID {
                return WorkspaceSlot(id: slotID, rect: spatial.rect, content: content)
            }
            var slot = targetSlotsByID[spatial.id]!
            slot.rect = spatial.rect
            return slot
        }
        workspaces[source.workspace].tabs[targetIndex].activeSlotID = slotID
        workspaces[source.workspace].activeTabID = targetTabID

        var events: [WorkspaceEvent] = []
        if !detached.resized.isEmpty {
            events.append(.slotsResized(
                slots: detached.resized,
                detached: false,
                tab: sourceTabID,
                workspace: workspaceID
            ))
        }
        events.append(.slotMovedToTab(
            slot: slotID,
            fromTab: sourceTabID,
            toTab: targetTabID,
            workspace: workspaceID
        ))
        if !changedTargetIDs.isEmpty {
            events.append(.slotsResized(
                slots: changedTargetIDs,
                detached: false,
                tab: targetTabID,
                workspace: workspaceID
            ))
        }
        if didSelectTarget {
            events.append(.tabSelected(tab: targetTabID, workspace: workspaceID))
        }
        events.append(.slotFocused(
            slot: slotID,
            tab: targetTabID,
            workspace: workspaceID
        ))
        return events
    }

    @discardableResult
    public mutating func applyMove(
        _ transaction: SpatialLayoutTransaction
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation,
              transaction.kind == .move,
              transaction.isValid
        else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let changedSlotIDs = changedSlotIDs(
            baseline: transaction.baseline,
            proposal: transaction.proposal,
            claimedAffectedSlotIDs: transaction.affectedSlotIDs,
            tab: tab
        ) else { return [] }

        let rects = Dictionary(
            uniqueKeysWithValues: transaction.proposal.map { ($0.id, $0.rect) }
        )
        workspaces[location.workspace].tabs[location.tab].slots = tab.slots.map { slot in
            var updated = slot
            updated.rect = rects[slot.id]!
            return updated
        }
        return [
            .slotsMoved(
                slots: changedSlotIDs,
                tab: tab.id,
                workspace: workspaces[location.workspace].id
            ),
        ]
    }

    @discardableResult
    public mutating func applySwap(
        _ transaction: SpatialLayoutTransaction
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation,
              transaction.kind == .swap,
              transaction.isValid
        else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let changedSlotIDs = changedSlotIDs(
            baseline: transaction.baseline,
            proposal: transaction.proposal,
            claimedAffectedSlotIDs: transaction.affectedSlotIDs,
            tab: tab
        ), changedSlotIDs.count == 2 else { return [] }

        let rects = Dictionary(
            uniqueKeysWithValues: transaction.proposal.map { ($0.id, $0.rect) }
        )
        workspaces[location.workspace].tabs[location.tab].slots = tab.slots.map { slot in
            var updated = slot
            updated.rect = rects[slot.id]!
            return updated
        }
        return [
            .slotsSwapped(
                first: changedSlotIDs[0],
                second: changedSlotIDs[1],
                tab: tab.id,
                workspace: workspaces[location.workspace].id
            ),
        ]
    }

    @discardableResult
    public mutating func applyResize(
        _ transaction: ResizeLayoutTransaction
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation,
              transaction.isValid
        else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let changedSlotIDs = changedSlotIDs(
            baseline: transaction.baseline,
            proposal: transaction.proposal,
            claimedAffectedSlotIDs: transaction.affectedSlotIDs,
            tab: tab
        ) else { return [] }

        let rects = Dictionary(
            uniqueKeysWithValues: transaction.proposal.map { ($0.id, $0.rect) }
        )
        workspaces[location.workspace].tabs[location.tab].slots = tab.slots.map { slot in
            var updated = slot
            updated.rect = rects[slot.id]!
            return updated
        }
        return [
            .slotsResized(
                slots: changedSlotIDs,
                detached: transaction.isDetached,
                tab: tab.id,
                workspace: workspaces[location.workspace].id
            ),
        ]
    }

    /// Grows one pane of the active tab into the free columns beside it — what a
    /// double-click on a pane header asks for. The caller names a pane, never a
    /// geometry, so the fill rule stays in `SpatialLayout` and the commit stays the
    /// same validated `applyResize` path every other geometry change takes.
    @discardableResult
    public mutating func fillSlotWidth(_ id: UUID) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard tab.slots.contains(where: { $0.id == id }) else { return [] }
        return applyResize(SpatialLayout.fillWidth(tab.spatialSlots, slotID: id))
    }

    /// Sends one edge of a pane to a fraction of the canvas — what the border's
    /// contextual menu asks for. Same shape as `fillSlotWidth`: the caller names a pane
    /// and an edge, never a geometry, so the sizing rule stays in `SpatialLayout` and
    /// the commit takes the same validated `applyResize` path as a drag.
    @discardableResult
    public mutating func resizeSlot(
        _ id: UUID,
        direction: ResizeDirection,
        fraction: SpatialExtentFraction
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard tab.slots.contains(where: { $0.id == id }) else { return [] }
        return applyResize(SpatialLayout.resize(
            tab.spatialSlots,
            slotID: id,
            direction: direction,
            fraction: fraction
        ))
    }

    /// Steps one edge of a pane to the next size in that border's cycle — what a
    /// double-click on the border asks for. Same shape again: the caller names a pane and
    /// an edge, the cycle rule stays in `SpatialLayout`, the commit stays `applyResize`.
    @discardableResult
    public mutating func cycleSlotExtent(
        _ id: UUID,
        direction: ResizeDirection
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard tab.slots.contains(where: { $0.id == id }) else { return [] }
        return applyResize(SpatialLayout.cycleExtent(
            tab.spatialSlots,
            slotID: id,
            direction: direction
        ))
    }

    private var activeWorkspaceIndex: Int? {
        workspaces.firstIndex { $0.id == activeWorkspaceID }
    }

    private var activeTabLocation: (workspace: Int, tab: Int)? {
        guard let workspaceIndex = activeWorkspaceIndex,
              let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(
                where: { $0.id == workspaces[workspaceIndex].activeTabID }
              )
        else { return nil }
        return (workspaceIndex, tabIndex)
    }

    private var fullGridRect: GridRect {
        GridRect(
            x: 0,
            y: 0,
            width: SpatialLayout.columns,
            height: SpatialLayout.rows
        )
    }

    private func changedSlotIDs(
        baseline: [SpatialSlot],
        proposal: [SpatialSlot],
        claimedAffectedSlotIDs: [UUID],
        tab: Tab
    ) -> [UUID]? {
        let current = tab.spatialSlots
        guard baseline == current,
              SpatialLayout.isValid(proposal),
              proposal.count == current.count,
              Set(proposal.map(\.id)) == Set(current.map(\.id))
        else { return nil }

        let proposalRects = Dictionary(
            uniqueKeysWithValues: proposal.map { ($0.id, $0.rect) }
        )
        let changed = current.compactMap { slot -> UUID? in
            proposalRects[slot.id] == slot.rect ? nil : slot.id
        }
        guard !changed.isEmpty,
              claimedAffectedSlotIDs.count == Set(claimedAffectedSlotIDs).count,
              Set(changed) == Set(claimedAffectedSlotIDs)
        else { return nil }
        return claimedAffectedSlotIDs
    }

    /// The (workspace, tab) indices of the tab holding `slotID`, searched only within
    /// the active workspace — the scope every cross-tab drag operates in.
    private func location(ofSlot slotID: UUID) -> (workspace: Int, tab: Int)? {
        guard let workspaceIndex = activeWorkspaceIndex else { return nil }
        for tabIndex in workspaces[workspaceIndex].tabs.indices
        where workspaces[workspaceIndex].tabs[tabIndex]
            .slots.contains(where: { $0.id == slotID }) {
            return (workspaceIndex, tabIndex)
        }
        return nil
    }

    /// Remove a slot from its tab and reflow the survivors, mirroring `closeSlot`'s
    /// absorption. Returns the removed slot (identity + content intact for reparenting)
    /// and the ids of any slots that grew to absorb the freed space.
    private mutating func detachSlot(
        _ slotID: UUID,
        at location: (workspace: Int, tab: Int)
    ) -> (slot: WorkspaceSlot, resized: [UUID])? {
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let removed = tab.slots.first(where: { $0.id == slotID }),
              let removedIndex = tab.slots.firstIndex(where: { $0.id == slotID }),
              let transaction = SpatialLayout.close(tab.spatialSlots, slotID: slotID)
        else { return nil }

        let remainingByID = Dictionary(
            uniqueKeysWithValues: tab.slots
                .filter { $0.id != slotID }
                .map { ($0.id, $0) }
        )
        let slots = transaction.proposal.map { spatial -> WorkspaceSlot in
            var slot = remainingByID[spatial.id]!
            slot.rect = spatial.rect
            return slot
        }
        var activeSlotID = tab.activeSlotID
        if activeSlotID == slotID {
            if let absorbingSlotID = transaction.absorbedSlotIDs.first(
                where: { absorbedID in slots.contains { $0.id == absorbedID } }
            ) {
                activeSlotID = absorbingSlotID
            } else if slots.isEmpty {
                activeSlotID = nil
            } else {
                activeSlotID = slots[max(0, min(removedIndex - 1, slots.count - 1))].id
            }
        }

        workspaces[location.workspace].tabs[location.tab].slots = slots
        workspaces[location.workspace].tabs[location.tab].activeSlotID = activeSlotID
        return (removed, transaction.absorbedSlotIDs)
    }

    /// The target tab's slot array after admitting a moved slot, mirroring `addSlot`'s
    /// placement: fill an empty tab, else the largest empty rect, else split the
    /// target's active slot. `changed` lists existing slots whose rect the placement
    /// shrank. Returns nil when the slot cannot be placed (leaving the catalog untouched).
    private func placement(
        forSlot id: UUID,
        content: SlotContent,
        in tab: Tab
    ) -> (slots: [WorkspaceSlot], changed: [UUID])? {
        if tab.slots.isEmpty {
            return ([WorkspaceSlot(id: id, rect: fullGridRect, content: content)], [])
        }

        if let rect = SpatialLayout.bestEmptyRect(
            in: tab.spatialSlots,
            near: tab.activeSlotID
        ) {
            var slots = tab.slots
            slots.append(WorkspaceSlot(id: id, rect: rect, content: content))
            return (slots, [])
        }

        guard let active = tab.activeSlot else { return nil }
        let axis: SplitAxis =
            active.rect.width < SpatialLayout.minimumWidth * 2 &&
            active.rect.height >= SpatialLayout.minimumHeight * 2
                ? .vertical
                : .horizontal
        guard let transaction = SpatialLayout.split(
            tab.spatialSlots,
            slotID: active.id,
            newSlotID: id,
            axis: axis
        ) else { return nil }

        let rects = Dictionary(
            uniqueKeysWithValues: transaction.proposal.map { ($0.id, $0.rect) }
        )
        var slots = tab.slots.map { slot -> WorkspaceSlot in
            var updated = slot
            updated.rect = rects[slot.id]!
            return updated
        }
        slots.append(WorkspaceSlot(id: id, rect: rects[id]!, content: content))
        return (slots, [active.id])
    }

    private mutating func selectTab(offsetBy offset: Int) -> [WorkspaceEvent] {
        guard let workspaceIndex = activeWorkspaceIndex,
              workspaces[workspaceIndex].tabs.count > 1,
              let activeIndex = workspaces[workspaceIndex].tabs.firstIndex(
                where: { $0.id == workspaces[workspaceIndex].activeTabID }
              )
        else { return [] }
        let count = workspaces[workspaceIndex].tabs.count
        let nextIndex = (activeIndex + offset + count) % count
        return selectTab(workspaces[workspaceIndex].tabs[nextIndex].id)
    }

    private mutating func focusSlot(offsetBy offset: Int) -> [WorkspaceEvent] {
        guard let tab = activeTab,
              tab.slots.count > 1,
              let activeSlotID = tab.activeSlotID,
              let activeIndex = tab.slots.firstIndex(where: { $0.id == activeSlotID })
        else { return [] }
        let count = tab.slots.count
        let nextIndex = (activeIndex + offset + count) % count
        return focusSlot(tab.slots[nextIndex].id)
    }
}
