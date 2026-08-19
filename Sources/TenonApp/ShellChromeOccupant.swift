// @domain: workspace-model
import SwiftUI
import TenonCore

/// Whichever strip a chrome row is holding.
///
/// Both rows draw this, and so does every offscreen renderer, so "the strip moves" is true by
/// construction rather than by several call sites agreeing: there is one place in the tree
/// that builds a `ShellTabStrip` and one place that builds a `WorkspaceStatusBar`, and adding
/// an argument to either touches one line.
///
/// It exists because the alternative is the thing this whole change is against — a second
/// spelling of the strip that looks identical the day it is written and drifts afterwards.
struct ShellChromeOccupant: View {
    let strip: ShellChromeStrip
    /// The window edge the *hosting row* is attached to, which the tab strip needs and the
    /// status strip does not.
    let edge: ShellChromeEdge

    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    var intentRuntime: AppIntentRuntime
    var router: DragRouter
    var palette: CommandPaletteState
    var agentSuggestions: [AgentLaunchSuggestion] = []

    var body: some View {
        switch strip {
        case .tabs:
            ShellTabStrip(
                edge: edge,
                host: host,
                store: store,
                pool: pool,
                closeCoordinator: closeCoordinator,
                intentRuntime: intentRuntime,
                router: router,
                palette: palette,
                agentSuggestions: agentSuggestions
            )
        case .status:
            WorkspaceStatusBar(host: host)
        }
    }
}
