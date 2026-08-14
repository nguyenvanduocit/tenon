// @domain: spatial-canvas
/// The SwiftUI boundary: one `NSViewRepresentable` that makes the canvas and reconfigures it.
///
/// It is deliberately thin. Everything it could be tempted to decide is already decided —
/// by the interaction coordinator above it, and by the `NSView` below it — so `updateNSView`
/// stays a hand-off rather than a place where two layout systems negotiate.
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

struct SpatialCanvasView: NSViewRepresentable {
    let tab: TenonCore.Tab
    /// Which workspace this canvas belongs to. Passed down beside `workspacePath` because an
    /// empty pane's launcher offers that workspace's recents and nothing else; a pane must
    /// be told its workspace rather than reading whichever one is selected when it draws.
    let workspaceID: UUID
    let workspacePath: URL
    let allLiveSlotIDs: Set<UUID>
    let activeSlotID: UUID?
    let store: WorkspaceStore
    let pool: SurfacePool
    let agentLens: AgentLensPool
    let webPool: PluginWebSurfacePool
    let host: PluginHost
    let intentRuntime: AppIntentRuntime
    let palette: CommandPaletteState
    let agentSuggestions: [AgentLaunchSuggestion]
    let editorStates: EditorPaneStateStore
    let pluginSnapshots: [PluginSnapshot]
    let pluginViewSections: [PluginViewSection]
    let webSurfaceTitles: [WebSurfaceKey: String]
    /// T-029: the per-slot attention projection; the card header shows its state dot.
    let paneAttention: [UUID: PaneActivity]
    /// The host-native panes' header contributions, passed as a VALUE exactly like
    /// `paneAttention`. `WorkspaceStageView.body` reads them off `PaneHeaderStore`, and
    /// that read is what invalidates this representable when one changes.
    let paneHeaders: [UUID: PaneHeader]
    /// The same store, for the command route back down. Held apart from the dictionary
    /// because routing a click is not something a re-render should depend on.
    let paneHeaderStore: PaneHeaderStore
    /// What each pane is doing to its own name. Read off the coordinator in
    /// `WorkspaceStageView.body` for the same invalidation reason `paneHeaders` is.
    let paneRenames: [UUID: PaneRenamePhase]
    let paneRenamer: PaneRenameCoordinator
    let router: DragRouter
    let automation: AutomationScheduler
    let automationSchedulesEnabled: Bool
    let automationActions: AutomationPaneActions

    func makeNSView(context: Context) -> SpatialCanvasNSView {
        SpatialCanvasNSView()
    }

    /// The canvas takes the space the stage gives it and proposes nothing of its own.
    ///
    /// T-121: without this, the question has an answer anyway — the wrong one. The stage's
    /// `ZStack` asks its child for an ideal size, and a representable that stays silent sends
    /// that question to AppKit, which answers it by running an Auto Layout fitting-size sweep
    /// across every card, every pane host and every `NSTextField` beneath the canvas. The
    /// sweep dirties the text fields it walks, so measuring re-arms the measurement, and with
    /// enough panes open the main runloop stops completing turns altogether.
    ///
    /// It is the same rule `SpatialSlotCardView.layout()` and `AgentSessionLayout` already
    /// keep one level down: a pane is sized by the canvas, never by what it contains.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SpatialCanvasNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ view: SpatialCanvasNSView, context: Context) {
        view.configure(
            tab: tab,
            workspaceID: workspaceID,
            workspacePath: workspacePath,
            allLiveSlotIDs: allLiveSlotIDs,
            activeSlotID: activeSlotID,
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
            paneAttention: paneAttention,
            paneHeaders: paneHeaders,
            paneHeaderStore: paneHeaderStore,
            paneRenames: paneRenames,
            paneRenamer: paneRenamer,
            router: router,
            automation: automation,
            automationSchedulesEnabled: automationSchedulesEnabled,
            automationActions: automationActions
        )
    }

    static func dismantleNSView(
        _ view: SpatialCanvasNSView,
        coordinator: Coordinator
    ) {
        view.prepareForRemoval()
    }
}
