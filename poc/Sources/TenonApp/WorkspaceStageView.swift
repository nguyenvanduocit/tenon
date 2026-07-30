import SwiftUI
import TenonCore

/// The tab-local canvas: the active tab's spatial slots, an empty-state call to
/// action when a tab has no slots, and a launch placeholder when no tab exists.
struct WorkspaceStageView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var webPool: PluginWebSurfacePool
    var host: PluginHost
    var editorStates: EditorPaneStateStore
    var router: DragRouter

    var body: some View {
        let pluginSnapshots = host.plugins
        let pluginViewSections = host.pluginViews
        let webSurfaceTitles = webPool.titles

        if let workspace = store.catalog.activeWorkspace,
           let tab = workspace.activeTab {
            ZStack {
                SpatialCanvasView(
                    tab: tab,
                    workspacePath: workspace.path,
                    allLiveSlotIDs: Set(store.catalog.allSlotIDs),
                    activeSlotID: tab.activeSlotID,
                    store: store,
                    pool: pool,
                    webPool: webPool,
                    host: host,
                    editorStates: editorStates,
                    pluginSnapshots: pluginSnapshots,
                    pluginViewSections: pluginViewSections,
                    webSurfaceTitles: webSurfaceTitles,
                    paneAttention: pool.paneAttention,
                    router: router
                )

                if tab.slots.isEmpty {
                    EmptyTabCallToAction(store: store)
                }
            }
            .background(TenonTheme.ink)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(TenonTheme.muted)
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
    let store: WorkspaceStore

    var body: some View {
        EmptyStateCard(
            title: "This tab is empty",
            subtitle: "No terminal running yet",
            recents: store.recent?.recent ?? [],
            isDefaultAction: true,
            onLaunch: { store.addSlot(content: $0) }
        )
        .accessibilityIdentifier("empty-tab-card")
    }
}
