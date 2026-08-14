// @domain: workspace-model
import Foundation
import TenonIntentCore

public enum SlotContent: Equatable, Sendable {
    case terminal
    case changes
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
    /// A session that has already happened, read with Agent Lens over its recorded
    /// transcript. The pane holds no PTY until someone resumes it.
    case agentSession(AgentSessionRef)
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
             (.automation, .automation),
             (.file, .file),
             (.diff, .diff),
             // Browsing a session list is the same motion as browsing a file tree: the pane
             // that is already reading a recorded session takes the next one, so opening
             // five of them in a row leaves one pane rather than five.
             (.agentSession, .agentSession):
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
        case .automation:
            return "automation"
        case .pluginView(let pluginID, let viewID):
            return "plugin-view:\(pluginID.rawValue):\(viewID)"
        case .diff(let request):
            return "diff:\(request.fileName)"
        case .agentSession(let ref):
            // Provider and session id, and deliberately not the transcript path: the bus
            // value is read by plugins and written into diagnostics, and a home directory is
            // not something a pane's identity needs to publish.
            return "agent-session:\(ref.provider.rawValue):\(ref.sessionID)"
        case .empty:
            return "empty"
        }
    }
}

public struct WorkspaceSlot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var rect: GridRect
    public internal(set) var content: SlotContent
    /// A person-pinned chrome label. `nil` means derive the title from live pane content.
    public internal(set) var customTitle: String?

    public init(
        id: UUID = UUID(),
        rect: GridRect,
        content: SlotContent = .terminal,
        customTitle: String? = nil
    ) {
        self.id = id
        self.rect = rect
        self.content = content
        self.customTitle = customTitle.flatMap(PaneTitle.sanitized)
    }

    public var spatialSlot: SpatialSlot {
        SpatialSlot(id: id, rect: rect)
    }
}

public struct Tab: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var slots: [WorkspaceSlot]
    public internal(set) var activeSlotID: UUID?

    /// The number this tab is called by until its content names itself — `Terminal 3`.
    ///
    /// It belongs to the tab, not to the tab's place in the strip. Numbering by position is
    /// what made a working reorder invisible: drag one unnamed tab past another and the chips
    /// swap while the labels swap back, leaving the strip reading exactly as before (T-105).
    ///
    /// Assigned once, by `WorkspaceCatalog` when the tab joins a workspace, and never changed
    /// after that: closing the middle of three tabs leaves `1` and `3`, and the next tab is
    /// `4`. Gaps are the price of a name that stays put, and they are the cheaper half of
    /// that trade. What a number may do is come back once no tab holds it — see
    /// `Workspace.nextTabNumber`, which says exactly how far the promise reaches.
    public internal(set) var number: Int

    public init(
        id: UUID = UUID(),
        slots: [WorkspaceSlot],
        activeSlotID: UUID?,
        number: Int = 1
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
        self.number = number
    }

    /// A tab holding one pane. The pane fills the canvas unless `sizing` caps it, in which
    /// case the width it does not take is empty canvas the person can fill.
    public init(
        id: UUID = UUID(),
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited,
        number: Int = 1
    ) {
        let slot = WorkspaceSlot(
            rect: sizing.fitting(
                GridRect(
                    x: 0,
                    y: 0,
                    width: SpatialLayout.columns,
                    height: SpatialLayout.rows
                )
            ),
            content: content
        )
        self.init(id: id, slots: [slot], activeSlotID: slot.id, number: number)
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
    /// How this workspace is marked and tinted. Presentation only: `id` is the identity, so
    /// customising this never disturbs the tree below it. See `WorkspaceIdentity.swift`.
    public internal(set) var appearance: WorkspaceAppearance
    public internal(set) var tabs: [Tab]
    public internal(set) var activeTabID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        appearance: WorkspaceAppearance = .default,
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
        self.appearance = appearance
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        appearance: WorkspaceAppearance = .default,
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) {
        let tab = Tab(content: content, sizing: sizing)
        self.init(
            id: id,
            name: name,
            path: path,
            appearance: appearance,
            tabs: [tab],
            activeTabID: tab.id
        )
    }

    /// The name a person chose, or nil while this workspace still carries the one Tenon
    /// derived from its folder. A name field starts from this, so an unnamed workspace opens
    /// with an empty field whose placeholder is the derived name — the same state Reset
    /// produces, spelled once.
    public var customName: String? {
        name == WorkspaceName.derived(for: path) ? nil : name
    }

    /// The number the next tab to join this workspace is called by: one past the highest any
    /// tab here currently holds.
    ///
    /// The promise this keeps is the one T-105 is about — **no tab's name ever changes** — and
    /// it is deliberately not the stronger "no number is ever handed out twice". Close the
    /// highest-numbered tab and the next one takes that number back; no tab holds it, so no
    /// name moves and no two chips read alike. Buying strict monotonicity would mean a
    /// counter persisted per workspace, which is durable state earning nothing a person can
    /// see.
    public var nextTabNumber: Int {
        (tabs.map(\.number).max() ?? 0) + 1
    }

    /// Whether anything about how this workspace is presented was chosen by a person. Drives
    /// the reset affordance: there is nothing to restore when the answer is no.
    public var hasCustomIdentity: Bool {
        !appearance.isDefault || customName != nil
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
    /// A workspace's name, mark, or tint changed. Nothing below it moved — this is the one
    /// workspace fact that leaves every tab, pane, and selection exactly where it was.
    case workspaceIdentityChanged(UUID)
    /// A workspace took a different place in the catalog's sidebar order. Its tabs, panes,
    /// identity, and active selection are unchanged.
    case workspaceMoved(workspace: UUID, from: Int, to: Int)
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
    /// A pane's optional display label changed. Its UUID, content, geometry, and owner did not.
    case slotIdentityChanged(slot: UUID, tab: UUID, workspace: UUID)
    case slotMovedToTab(
        slot: UUID,
        fromTab: UUID,
        toTab: UUID,
        workspace: UUID
    )
    /// A tab took a different place in its own workspace's order (T-096). It carries both
    /// indices because the fact is the *move*: an observer holding a tab list can apply it
    /// without re-reading the catalog, and "from 2 to 2" is not a fact this event can state.
    case tabMoved(tab: UUID, from: Int, to: Int, workspace: UUID)
}

public struct WorkspaceCatalog: Equatable, Sendable {
    public private(set) var workspaces: [Workspace]
    public private(set) var activeWorkspaceID: UUID

    /// The first workspace. An unnamed one takes the name Tenon derives from its folder —
    /// the same rule every later workspace already opened with, so the very first workspace
    /// stops being the only one carrying a generic label.
    public init(
        name: String? = nil,
        path: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        content: SlotContent = .terminal
    ) {
        let workspace = Workspace(
            name: name ?? WorkspaceName.derived(for: path),
            path: path,
            content: content
        )
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
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        let workspace = Workspace(name: name, path: path, content: content, sizing: sizing)
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

    /// Name this workspace. A name that carries no characters asks for the derived default
    /// back, so clearing the field and pressing Reset agree instead of being two states.
    ///
    /// The workspace is addressed by `id` throughout, which is what makes duplicate display
    /// names safe: nothing here reads a name to find a workspace.
    @discardableResult
    public mutating func renameWorkspace(
        _ id: UUID,
        to typed: String
    ) -> [WorkspaceEvent] {
        setWorkspaceIdentity(id, name: typed)
    }

    /// Mark and tint this workspace.
    @discardableResult
    public mutating func setWorkspaceAppearance(
        _ id: UUID,
        _ appearance: WorkspaceAppearance
    ) -> [WorkspaceEvent] {
        setWorkspaceIdentity(id, appearance: appearance)
    }

    /// Apply one finite presentation patch. `nil` means a field was absent and stays as it
    /// is; an empty `name` is present and therefore restores the derived folder name.
    /// Applying name + appearance together publishes one fact and one catalog snapshot,
    /// which is the atomic typed operation the public intent adapts.
    @discardableResult
    public mutating func setWorkspaceIdentity(
        _ id: UUID,
        name typedName: String? = nil,
        appearance: WorkspaceAppearance? = nil
    ) -> [WorkspaceEvent] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return [] }

        let current = workspaces[index]
        let name = typedName.map {
            WorkspaceName.sanitized($0) ?? WorkspaceName.derived(for: current.path)
        } ?? current.name
        let nextAppearance = appearance ?? current.appearance
        guard name != current.name || nextAppearance != current.appearance else { return [] }

        workspaces[index].name = name
        workspaces[index].appearance = nextAppearance
        return [.workspaceIdentityChanged(id)]
    }

    /// Give this workspace Tenon's default appearance back. The workspace itself survives
    /// untouched — this restores how it is presented, it does not close and reopen it.
    @discardableResult
    public mutating func resetWorkspaceIdentity(_ id: UUID) -> [WorkspaceEvent] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].hasCustomIdentity
        else { return [] }
        workspaces[index].name = WorkspaceName.derived(for: workspaces[index].path)
        workspaces[index].appearance = .default
        return [.workspaceIdentityChanged(id)]
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

    /// Moves a workspace to another place in the catalog order.
    ///
    /// Selection is UUID-owned, so moving either the active workspace or one of its neighbors
    /// changes only display order. Tabs, panes, roots, and resource identities travel with the
    /// workspace value untouched.
    @discardableResult
    public mutating func moveWorkspace(_ id: UUID, to index: Int) -> [WorkspaceEvent] {
        guard let from = workspaces.firstIndex(where: { $0.id == id }),
              index >= 0, index < workspaces.count, index != from
        else { return [] }

        workspaces.insert(workspaces.remove(at: from), at: index)
        return [.workspaceMoved(workspace: id, from: from, to: index)]
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
    public mutating func newTab(
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let workspaceIndex = activeWorkspaceIndex else { return [] }
        let workspaceID = workspaces[workspaceIndex].id
        let tab = Tab(
            content: content,
            sizing: sizing,
            number: workspaces[workspaceIndex].nextTabNumber
        )
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

    /// Moves a tab to a different place in the **active** workspace's order (T-096).
    ///
    /// Scoping it to the active workspace is what makes "a reorder moves no tab between
    /// workspaces" a property of the operation rather than of the caller: there is no
    /// parameter that could name another workspace, and a tab id belonging to one returns
    /// no events. Everything else about the tab is left alone — its identity, its slots,
    /// its own active pane, and the workspace's `activeTabID` — so which tab is selected
    /// survives its neighbours moving around it.
    @discardableResult
    public mutating func moveTab(_ id: UUID, to index: Int) -> [WorkspaceEvent] {
        guard let workspaceIndex = activeWorkspaceIndex else { return [] }
        var tabs = workspaces[workspaceIndex].tabs
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              index >= 0, index < tabs.count, index != from
        else { return [] }

        tabs.insert(tabs.remove(at: from), at: index)
        workspaces[workspaceIndex].tabs = tabs

        return [
            .tabMoved(
                tab: id,
                from: from,
                to: index,
                workspace: workspaces[workspaceIndex].id
            ),
        ]
    }

    @discardableResult
    public mutating func addSlot(
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        openSlot(content: content, near: activeTab?.activeSlotID, sizing: sizing)
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
                events.append(contentsOf: closeTabIfEmpty(tab.id, in: workspaceID))
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
    public mutating func duplicateSlot(
        _ id: UUID,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let content = activeTab?.slots.first(where: { $0.id == id })?.content
        else { return [] }
        return openSlot(content: content, near: id, sizing: sizing)
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
        near anchor: UUID?,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let current = workspaces[location.workspace].tabs[location.tab]
        let newSlotID = UUID()

        if current.slots.isEmpty {
            let slot = WorkspaceSlot(
                id: newSlotID,
                rect: sizing.fitting(fullGridRect),
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
            let slot = WorkspaceSlot(
                id: newSlotID,
                rect: sizing.fitting(rect),
                content: content
            )
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
        return splitSlot(anchor, axis, content: content, sizing: sizing)
    }

    @discardableResult
    public mutating func splitActiveSlot(
        _ axis: SplitAxis,
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let activeSlotID = activeTab?.activeSlotID else { return [] }
        return splitSlot(activeSlotID, axis, content: content, sizing: sizing)
    }

    /// Split a specific slot in the active tab, mirroring `closeSlot(_:)`'s
    /// id-targeted shape so callers (a pane's context menu, a keybinding) can act
    /// on any slot without first stealing focus. The new slot becomes active.
    @discardableResult
    public mutating func splitSlot(
        _ id: UUID,
        _ axis: SplitAxis,
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard tab.slots.contains(where: { $0.id == id }) else { return [] }
        let newSlotID = UUID()
        guard let transaction = SpatialLayout.split(
            tab.spatialSlots,
            slotID: id,
            newSlotID: newSlotID,
            axis: axis,
            newSlotMaximumWidth: sizing.maximumColumns
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
    public mutating func closeSlot(
        _ id: UUID,
        sizing: NewPaneSizing = .unlimited
    ) -> [WorkspaceEvent] {
        guard let location = activeTabLocation else { return [] }
        let tab = workspaces[location.workspace].tabs[location.tab]
        guard let removedIndex = tab.slots.firstIndex(where: { $0.id == id }),
              let transaction = SpatialLayout.close(
                  tab.spatialSlots,
                  slotID: id,
                  maximumAbsorbedWidth: sizing.maximumColumns
              )
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
        events.append(contentsOf: closeTabIfEmpty(tab.id, in: workspaceID))
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

    /// Pin a display name to a pane, or clear it back to its content-derived title.
    @discardableResult
    public mutating func renameSlot(_ id: UUID, to typed: String) -> [WorkspaceEvent] {
        let title = PaneTitle.sanitized(typed)
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices {
                guard let slotIndex = workspaces[workspaceIndex].tabs[tabIndex].slots
                    .firstIndex(where: { $0.id == id }),
                    workspaces[workspaceIndex].tabs[tabIndex].slots[slotIndex].customTitle != title
                else { continue }

                workspaces[workspaceIndex].tabs[tabIndex].slots[slotIndex].customTitle = title
                return [
                    .slotIdentityChanged(
                        slot: id,
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
    /// reflows exactly like `closeSlot`; moving a tab's only slot closes that empty
    /// source tab after the new tab exists. The new tab becomes active and the moved
    /// slot focused.
    @discardableResult
    public mutating func moveSlotToNewTab(_ slotID: UUID) -> [WorkspaceEvent] {
        guard let source = location(ofSlot: slotID) else { return [] }
        let sourceTabID = workspaces[source.workspace].tabs[source.tab].id
        let workspaceID = workspaces[source.workspace].id
        guard let detached = detachSlot(slotID, at: source) else { return [] }

        let movedSlot = WorkspaceSlot(
            id: detached.slot.id,
            rect: fullGridRect,
            content: detached.slot.content,
            customTitle: detached.slot.customTitle
        )
        let newTab = Tab(
            slots: [movedSlot],
            activeSlotID: movedSlot.id,
            number: workspaces[source.workspace].nextTabNumber
        )
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
        events.append(contentsOf: closeTabIfEmpty(sourceTabID, in: workspaceID))
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
        if let movedIndex = workspaces[source.workspace].tabs[targetIndex].slots
            .firstIndex(where: { $0.id == slotID })
        {
            workspaces[source.workspace].tabs[targetIndex].slots[movedIndex].customTitle =
                detached.slot.customTitle
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
        events.append(contentsOf: closeTabIfEmpty(sourceTabID, in: workspaceID))
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
                return WorkspaceSlot(
                    id: slotID,
                    rect: spatial.rect,
                    content: content,
                    customTitle: detached.slot.customTitle
                )
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
        events.append(contentsOf: closeTabIfEmpty(sourceTabID, in: workspaceID))
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

    /// Collapse a tab whose last pane just left through a pane-level mutation. The
    /// workspace's required final tab remains as its empty structural placeholder;
    /// `closeTab` owns that invariant and the neighboring-tab selection events.
    private mutating func closeTabIfEmpty(
        _ tabID: UUID,
        in workspaceID: UUID
    ) -> [WorkspaceEvent] {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.tabs.first(where: { $0.id == tabID })?.slots.isEmpty == true
        else { return [] }
        return closeTab(tabID, in: workspaceID)
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

    /// Remove a slot from its tab and reflow the survivors with the same structural
    /// absorption as `closeSlot`, but without the close-only configured width cap. Returns
    /// the removed slot (identity + content intact for reparenting) and the ids of any slots
    /// that grew to absorb the freed space.
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
