// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The shell composition root: a single top title bar — traffic lights, app identity,
/// and the tab strip share one row — over a body of workspace navigation and a
/// tab-local spatial canvas. Every visible region is its own view; this struct only
/// owns the sidebar's expanded/collapsed width state and wires the pieces together.
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    var paneRenamer: PaneRenameCoordinator
    var agentLens: AgentLensPool
    /// T-178: which panes hold an agent, for the sidebar's tagline. Optional so an offscreen
    /// renderer can mount the shell without a hook server behind it.
    var agentPanes: AgentPaneRoster?
    var webPool: PluginWebSurfacePool
    var intentRuntime: AppIntentRuntime
    var router: DragRouter
    var palette: CommandPaletteState
    var quickCommands: QuickCommandStore
    var pluginUI: PluginUIState
    var automation: AutomationScheduler
    /// T-100's read-only process monitor, drawn in the title bar.
    var resourceMonitor: ResourceMonitorModel?
    /// Which chrome row holds the tabs and which holds the plugin status items. Passed in
    /// rather than read from the shared store inside the body, so an offscreen renderer can
    /// photograph either order without writing anybody's persisted preferences.
    let chromeOrder: ShellChromeOrder
    let automationSchedulesEnabled: Bool
    let automationActions: AutomationPaneActions

    /// Per-slot editor state (scroll/selection/unsaved buffer). Owned here — above
    /// the stage — because it must survive the pane views SwiftUI destroys on every
    /// tab switch; `SurfacePool` is the same idea for terminal surfaces (T-016).
    @State private var editorStates = EditorPaneStateStore()
    /// Where a host-native pane's chrome-header contribution lives while its content view
    /// is mounted. Owned here, above the stage, for the same reason `editorStates` is:
    /// the views that publish into it are destroyed and rebuilt on every tab switch, and
    /// the stage has to be able to read it as an observed input.
    @State private var paneHeaders = PaneHeaderStore()
    @State private var agentSuggestions: [AgentLaunchSuggestion] = []

    /// `false` means the persistent icon rail; the workspace switcher never disappears.
    @State private var sidebarVisible = AppPreferencesStore.shared.preferences.sidebarVisibleOnLaunch
    @State private var sidebarWidth: CGFloat =
        CGFloat(AppPreferencesStore.shared.preferences.sidebarWidth)
    /// Sidebar width captured when a resize drag begins, so a drag that ends in a
    /// collapse can restore the width the sidebar re-opens at.
    @State private var resizeStartWidth: CGFloat?
    @State private var resizeHovering = false

    /// Hit-target width of the invisible strip you grab to drag the divider. Wider
    /// than the 1-pt line so the pointer catches it without pixel-hunting.
    private let sidebarHandleWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            ShellTitleBar(
                store: store,
                pool: pool,
                resourceMonitor: resourceMonitor,
                quickCommands: quickCommands,
                sidebarVisible: sidebarVisible,
                sidebarWidth: sidebarWidth,
                onToggleSidebar: {
                    setSidebarVisible(!sidebarVisible)
                }
            ) {
                chromeOccupant(chromeOrder.titleBarStrip, edge: .top)
            }
            .frame(height: TenonTheme.titleBarHeight)

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            HStack(spacing: 0) {
                WorkspaceSidebarView(
                    store: store,
                    pool: pool,
                    closeCoordinator: closeCoordinator,
                    agentPanes: agentPanes,
                    isCollapsed: !sidebarVisible
                )
                .frame(
                    width: SidebarResize.renderedWidth(
                        isExpanded: sidebarVisible,
                        expandedWidth: sidebarWidth
                    )
                )

                VStack(spacing: 0) {
                    WorkspaceStageView(
                        store: store,
                        pool: pool,
                        agentLens: agentLens,
                        webPool: webPool,
                        host: host,
                        intentRuntime: intentRuntime,
                        palette: palette,
                        agentSuggestions: agentSuggestions,
                        editorStates: editorStates,
                        paneHeaders: paneHeaders,
                        paneRenamer: paneRenamer,
                        router: router,
                        automation: automation,
                        automationSchedulesEnabled: automationSchedulesEnabled,
                        automationActions: automationActions
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(TenonTheme.line)
                        .frame(height: 1)

                    // Inside the content column, never spanning the window: the sidebar's
                    // resize edge below is a full-height grab strip drawn over everything at
                    // `sidebarWidth`, and a full-width foot row would have an 8-pt dead band
                    // cut through whatever it is holding.
                    ShellFootBar(
                        height: TenonTheme.footHeight(for: chromeOrder.footStrip)
                    ) {
                        chromeOccupant(chromeOrder.footStrip, edge: .bottom)
                    }
                }
            }
        }
        // The sidebar's right edge is one continuous border from the top of the title
        // bar down to the status bar: hover or drag it anywhere and the whole line
        // lights amber and resizes the sidebar — so the strip inside the title bar
        // behaves exactly like the strip below it instead of being a dead static rule.
        .overlay(alignment: .leading) {
            if sidebarVisible {
                sidebarEdge
                    // Centre the grab strip on the 1-pt line at x = sidebarWidth.
                    .offset(x: sidebarWidth - (sidebarHandleWidth - 1) / 2)
            }
        }
        .background(TenonTheme.ink)
        .foregroundStyle(TenonTheme.text)
        .preferredColorScheme(.dark)
        .background(WindowChrome())
        .shellCloseConfirmation(closeCoordinator)
        // Draw up into the transparent title-bar region so the tab strip sits on the
        // title bar next to the traffic lights (browser-style), instead of below a
        // wasted strip that shows the desktop through the transparent titlebar.
        .ignoresSafeArea(.container, edges: .top)
        // The command palette floats over the whole shell (title bar included) when
        // presented; it renders nothing otherwise. State lives outside the accent
        // rebuild below, so opening/closing it survives a theme change.
        .overlay {
            PaletteOverlay(
                host: host,
                intentRuntime: intentRuntime,
                palette: palette
            )
        }
        // Host presentation for plugin-only `ui.pick/prompt/confirm/toast.v1`
        // intents. Renders nothing until an authorized request arrives.
        .overlay {
            PluginUIOverlay(
                state: pluginUI,
                bottomInset: TenonTheme.footHeight(for: chromeOrder.footStrip) + 16
            )
        }
        // A plugin view's modal, over the whole shell. Renders nothing until a view
        // publishes one, and dismissing routes back to that view rather than clearing
        // it here — the plugin owns the state.
        .overlay { PluginModalOverlay(host: host) }
        .task {
            agentSuggestions = await AgentLaunchDetector.scanLive()
        }
        // Rebuild the whole shell when the accent changes so every chrome element
        // re-reads TenonTheme.amber. Reading the shared store here registers the
        // observation; terminal surfaces persist in the pool across the rebuild.
        .id(AppPreferencesStore.shared.preferences.accent)
    }

    /// This shell's occupant for one chrome row, wired to this shell's live objects.
    private func chromeOccupant(
        _ strip: ShellChromeStrip,
        edge: ShellChromeEdge
    ) -> ShellChromeOccupant {
        ShellChromeOccupant(
            strip: strip,
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
    }

    /// The sidebar's right edge: a 1-pt line centred inside an invisible grab strip,
    /// spanning the full window height so it reads and behaves as one border from the
    /// title bar through the content. The line brightens to amber while hovered or
    /// dragged; dragging resizes the sidebar and pulling narrower than
    /// `SidebarResize.minWidth` collapses it. Translation is read in `.global` space so
    /// the strip moving with the divider never skews the drag.
    private var sidebarEdge: some View {
        ZStack {
            Rectangle()
                .fill(resizeHovering || resizeStartWidth != nil ? TenonTheme.amber : TenonTheme.line)
                .frame(width: 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: resizeHovering
                )

            Color.clear
                .frame(width: sidebarHandleWidth)
                .contentShape(Rectangle())
                .onHover { inside in
                    resizeHovering = inside
                    if inside {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = resizeStartWidth ?? sidebarWidth
                            if resizeStartWidth == nil { resizeStartWidth = sidebarWidth }
                            switch SidebarResize.resolve(
                                proposedWidth: base + value.translation.width
                            ) {
                            case .resize(let width):
                                sidebarWidth = width
                            case .collapse:
                                resizeStartWidth = nil
                                // The resize edge unmounts when the sidebar becomes a rail,
                                // so its hover-exit never fires — balance the cursor here.
                                if resizeHovering {
                                    resizeHovering = false
                                    NSCursor.pop()
                                }
                                setSidebarVisible(false)
                                sidebarWidth = base
                            }
                        }
                        .onEnded { _ in resizeStartWidth = nil }
                )
        }
        .frame(width: sidebarHandleWidth)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("tenon.sidebarResize")
    }

    private func setSidebarVisible(_ visible: Bool) {
        if reduceMotion {
            sidebarVisible = visible
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                sidebarVisible = visible
            }
        }
    }
}
