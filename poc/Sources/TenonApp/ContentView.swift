import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The shell composition root: a single top title bar — traffic lights, app identity,
/// and the tab strip share one row — over a body of workspace navigation and a
/// tab-local spatial canvas. Every visible region is its own view; this struct only
/// owns the sidebar's show/width layout state and wires the pieces together.
struct ContentView: View {
    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var webPool: PluginWebSurfacePool
    var intentRuntime: AppIntentRuntime
    var router: DragRouter
    var palette: CommandPaletteState
    var pluginUI: PluginUIState

    /// Per-slot editor state (scroll/selection/unsaved buffer). Owned here — above
    /// the stage — because it must survive the pane views SwiftUI destroys on every
    /// tab switch; `SurfacePool` is the same idea for terminal surfaces (T-016).
    @State private var editorStates = EditorPaneStateStore()

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
                host: host,
                store: store,
                pool: pool,
                intentRuntime: intentRuntime,
                router: router,
                palette: palette,
                sidebarVisible: sidebarVisible,
                sidebarWidth: sidebarWidth,
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() }
                }
            )
            .frame(height: TenonTheme.titleBarHeight)

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            HStack(spacing: 0) {
                if sidebarVisible {
                    WorkspaceSidebarView(store: store, pool: pool)
                        .frame(width: sidebarWidth)
                }

                VStack(spacing: 0) {
                    WorkspaceStageView(
                        store: store,
                        pool: pool,
                        webPool: webPool,
                        host: host,
                        editorStates: editorStates,
                        router: router
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(TenonTheme.line)
                        .frame(height: 1)

                    WorkspaceStatusBar(host: host)
                        .frame(height: TenonTheme.statusBarHeight)
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
        .overlay { PluginUIOverlay(state: pluginUI) }
        // Rebuild the whole shell when the accent changes so every chrome element
        // re-reads TenonTheme.amber. Reading the shared store here registers the
        // observation; terminal surfaces persist in the pool across the rebuild.
        .id(AppPreferencesStore.shared.preferences.accent)
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
                .animation(.easeOut(duration: 0.12), value: resizeHovering)

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
                                // The edge unmounts on collapse, so its hover-exit
                                // never fires — balance the pushed resize cursor here.
                                if resizeHovering {
                                    resizeHovering = false
                                    NSCursor.pop()
                                }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    sidebarVisible = false
                                }
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
}
