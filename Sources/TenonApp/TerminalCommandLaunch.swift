// @domain: command-surface
import Foundation
import TenonCore

/// Puts a terminal where a launcher choice said to put it, then delivers one command line to
/// it. This is the host-native placement/delivery path — the same typed workspace/surface
/// calls a person's own runbook makes — and it mints no principal and enters no intent adapter.
///
/// Two callers share it and must not drift apart: a detected agent (which validates its
/// executable first, then hands its assembled command line here) and a command a person typed
/// into an empty pane's search field. Placement, spawn directory, and the wait for a live
/// shell are the same work in both cases, so they are written once.
///
/// Known bound: `sendTextWhenReady` writes into the PTY's canonical input queue, which macOS
/// caps at `MAX_INPUT` (1024 bytes) and silently truncates past — see T-159. Everything typed
/// into a search field is far below that; an assembled agent command line can approach it.
@MainActor
enum TerminalCommandLaunch {
    static func run(
        commandLine: String,
        placement: AgentLaunchPlacement,
        workspaceStore: WorkspaceStore,
        terminalPool: SurfacePool
    ) -> LauncherOutcome {
        guard let workspace = workspaceStore.catalog.activeWorkspace else {
            return .targetUnavailable
        }
        let paneID: UUID?
        switch placement {
        case .newTab:
            let existingTabs = Set(workspace.tabs.map(\.id))
            workspaceStore.newTab(content: .terminal)
            guard let tab = workspaceStore.catalog.activeTab,
                  !existingTabs.contains(tab.id)
            else { return .targetUnavailable }
            paneID = tab.activeSlotID

        case .tab(let tabID):
            guard workspace.tabs.contains(where: { $0.id == tabID }) else {
                return .targetUnavailable
            }
            workspaceStore.selectTab(tabID)
            if let empty = workspaceStore.catalog.activeTab?.slots.first(where: {
                $0.content == .empty
            }) {
                workspaceStore.setSlotContent(empty.id, .terminal)
                workspaceStore.focusSlot(empty.id)
                paneID = empty.id
            } else if workspaceStore.catalog.activeTab?.slots.isEmpty == true {
                workspaceStore.addSlot(content: .terminal)
                paneID = workspaceStore.catalog.activeSlotID
            } else {
                let existingPanes = Set(
                    workspaceStore.catalog.activeTab?.slots.map(\.id) ?? []
                )
                workspaceStore.splitActiveSlot(.horizontal, content: .terminal)
                let candidate = workspaceStore.catalog.activeSlotID
                paneID = candidate.flatMap { existingPanes.contains($0) ? nil : $0 }
            }

        case .emptyTab:
            guard workspaceStore.catalog.activeTab?.slots.isEmpty == true else {
                return .targetUnavailable
            }
            workspaceStore.addSlot(content: .terminal)
            paneID = workspaceStore.catalog.activeSlotID

        case .emptySlot(let slotID):
            guard workspaceStore.catalog.slot(id: slotID)?.content == .empty else {
                return .targetUnavailable
            }
            workspaceStore.setSlotContent(slotID, .terminal)
            workspaceStore.focusSlot(slotID)
            paneID = workspaceStore.catalog.slot(id: slotID)?.content == .terminal
                ? slotID
                : nil

        case .emptyGrid(let rect):
            paneID = workspaceStore.addSlot(content: .terminal, at: rect)
        }

        guard let paneID,
              workspaceStore.catalog.slot(id: paneID)?.content == .terminal
        else { return .targetUnavailable }
        terminalPool.seedSpawnDirectory(workspace.path, for: paneID)
        terminalPool.sendTextWhenReady(commandLine + "\n", to: paneID)
        return .ran
    }
}
