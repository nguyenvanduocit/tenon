import AppKit
import SwiftUI
import TenonCore

/// The shell composition root: a single top title bar — traffic lights, app identity,
/// and the tab strip share one row — over a body of workspace navigation and a
/// tab-local spatial canvas. Every visible region is its own view; this struct only
/// owns the sidebar's show/width layout state and wires the pieces together.
struct ContentView: View {
    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var router: DragRouter

    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = SidebarResize.defaultWidth
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
                router: router,
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
                    WorkspaceSidebarView(store: store)
                        .frame(width: sidebarWidth)

                    sidebarDivider
                }

                VStack(spacing: 0) {
                    WorkspaceStageView(store: store, pool: pool, host: host, router: router)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(TenonTheme.line)
                        .frame(height: 1)

                    WorkspaceStatusBar(store: store, pool: pool, host: host)
                        .frame(height: TenonTheme.statusBarHeight)
                }
            }
            .overlay(alignment: .leading) {
                if sidebarVisible {
                    sidebarResizeHandle
                        // Centre the grab strip on the 1-pt divider at x = sidebarWidth.
                        .offset(x: sidebarWidth - (sidebarHandleWidth - 1) / 2)
                }
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
    }

    /// The 1-pt divider between sidebar and stage. Brightens while it is being
    /// hovered or dragged so the resize affordance is discoverable.
    private var sidebarDivider: some View {
        Rectangle()
            .fill(resizeHovering || resizeStartWidth != nil ? TenonTheme.amber : TenonTheme.line)
            .frame(width: 1)
            .animation(.easeOut(duration: 0.12), value: resizeHovering)
    }

    /// Invisible strip overlaid on the divider. Dragging it resizes the sidebar;
    /// pulling narrower than `SidebarResize.minWidth` collapses it. Translation is
    /// read in `.global` space so the strip moving with the divider never skews it.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: sidebarHandleWidth)
            .frame(maxHeight: .infinity)
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
                            // The handle unmounts on collapse, so its hover-exit
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
            .accessibilityIdentifier("tenon.sidebarResize")
    }
}
