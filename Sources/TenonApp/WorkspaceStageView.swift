// @domain: workspace-model
import SwiftUI
import TenonCore

/// The tab-local canvas: the active tab's spatial slots, an empty-state call to
/// action when a tab has no slots, and a launch placeholder when no tab exists.
struct WorkspaceStageView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var agentLens: AgentLensPool
    var webPool: PluginWebSurfacePool
    var host: PluginHost
    var intentRuntime: AppIntentRuntime
    var palette: CommandPaletteState
    let agentSuggestions: [AgentLaunchSuggestion]
    var editorStates: EditorPaneStateStore
    var paneHeaders: PaneHeaderStore
    var paneRenamer: PaneRenameCoordinator
    var router: DragRouter
    var automation: AutomationScheduler
    let automationSchedulesEnabled: Bool
    let automationActions: AutomationPaneActions

    var body: some View {
        let pluginSnapshots = host.plugins
        let pluginViewSections = host.pluginViews
        let webSurfaceTitles = webPool.titles
        // THE INVALIDATION CONTRACT. `configure` on the canvas is reached only when this
        // body re-evaluates, so reading the store here is what makes a host-native pane's
        // header refresh at all — its content model lives in a different SwiftUI graph and
        // can invalidate nothing out here. Drop this line and every built-in header
        // silently freezes at its first value while still rendering.
        let paneHeaderValues = paneHeaders.headers
        // Same contract, one layer over: a pane reports its rename on its own title, and the
        // canvas below is an `NSView` that observes nothing. This read is what turns
        // "generating" into a repaint of that pane's header.
        let paneRenameValues = paneRenamer.phases

        if let workspace = store.catalog.activeWorkspace,
           let tab = workspace.activeTab {
            ZStack {
                SpatialCanvasView(
                    tab: tab,
                    workspaceID: workspace.id,
                    workspacePath: workspace.path,
                    allLiveSlotIDs: Set(store.catalog.allSlotIDs),
                    activeSlotID: tab.activeSlotID,
                    store: store,
                    pool: pool,
                    agentLens: agentLens,
                    webPool: webPool,
                    host: host,
                    intentRuntime: intentRuntime,
                    palette: palette,
                    agentSuggestions: agentSuggestions,
                    editorStates: editorStates,
                    pluginSnapshots: pluginSnapshots,
                    pluginViewSections: pluginViewSections,
                    webSurfaceTitles: webSurfaceTitles,
                    paneAttention: pool.paneAttention,
                    paneHeaders: paneHeaderValues,
                    paneHeaderStore: paneHeaders,
                    paneRenames: paneRenameValues,
                    paneRenamer: paneRenamer,
                    router: router,
                    automation: automation,
                    automationSchedulesEnabled: automationSchedulesEnabled,
                    automationActions: automationActions
                )

                if tab.slots.isEmpty {
                    EmptyTabCallToAction(
                        workspaceID: workspace.id,
                        store: store,
                        pool: pool,
                        agentSuggestions: agentSuggestions
                    )
                }
            }
            .background(TenonTheme.ink)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(TenonTheme.muted)
                    .accessibilityHidden(true)
                Text("Add terminal")
                    .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                Button("New tab") {
                    store.newTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.ink)
        }
    }
}

/// The empty tab presents the shared launcher card; its actions add a fresh slot
/// to the otherwise-empty tab.
private struct EmptyTabCallToAction: View {
    /// The workspace this tab belongs to, handed down from the one place that already knows
    /// it. The card offers only this workspace's recents; it never asks which workspace is
    /// selected, so a list can't follow the selection somewhere else.
    let workspaceID: UUID
    let store: WorkspaceStore
    let pool: SurfacePool
    let agentSuggestions: [AgentLaunchSuggestion]

    var body: some View {
        EmptyStateCard(
            recents: store.recent?.recent(for: workspaceID) ?? [],
            agentSuggestions: agentSuggestions,
            isActive: true,
            onLaunch: { store.addSlot(content: $0) },
            onLaunchAgent: { suggestion in
                _ = AgentLaunchExecutor.run(
                    suggestion,
                    placement: .emptyTab,
                    workspaceStore: store,
                    terminalPool: pool
                )
            },
            onRunCommand: { commandLine in
                _ = TerminalCommandLaunch.run(
                    commandLine: commandLine,
                    placement: .emptyTab,
                    workspaceStore: store,
                    terminalPool: pool
                )
            }
        )
        .accessibilityIdentifier("empty-tab-card")
    }
}
