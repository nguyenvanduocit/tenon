import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The full-width top row shared with the traffic lights. Its left zone (app identity
/// + sidebar toggle) sits above the sidebar column; its right zone (the tab strip,
/// ending in the `+` launcher) sits above the content column. The whole row is a
/// window-drag surface, with interactive controls carving their own clicks out of it.
struct ShellTitleBar: View {
    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var intentRuntime: AppIntentRuntime
    var router: DragRouter
    var palette: CommandPaletteState
    var quickCommands: QuickCommandStore
    let agentSuggestions: [AgentLaunchSuggestion]
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void

    @State private var launcherPresented = false
    /// Which tab's right-click launcher popover is open, if any. One value for the whole
    /// strip: opening a second tab's launcher closes the first.
    @State private var contextLauncherTab: UUID?

    /// Dispatch a launcher command as if it had been chosen *on this tab*.
    ///
    /// The scope is the whole point: the palette and unanchored launcher surfaces invoke
    /// against the focused pane, which for a right-click on a background tab would put the
    /// result in the wrong place.
    /// Placement itself stays host policy inside `workspace.content.open.v1` — this only
    /// says which tab is being talked about. The result flows back to the launcher, which
    /// settles it exactly as the `+` popover does.
    private func send(_ commandID: String, onTab tabID: UUID) async -> IntentResult? {
        guard let paneID = TabContextPlacement.scopedPane(
            in: store.catalog,
            tabID: tabID
        ) else {
            return nil
        }
        let workspaceID = TabContextPlacement.owningWorkspace(
            in: store.catalog,
            tabID: tabID
        )
        if TabContextPlacement.requiresRevealing(
            in: store.catalog,
            tabID: tabID,
            placesContent: true
        ) {
            store.selectTab(tabID)
        }
        return await PaletteIntentInvoker.send(
            commandID: commandID,
            scope: InvocationScope(
                workspaceID: workspaceID,
                paneID: paneID
            ),
            host: host,
            runtime: intentRuntime
        )
    }

    /// Dispatch a title-bar `+` choice inside a fresh tab. The temporary tab provides
    /// ordinary pane scope to plugin openers; commands whose own meaning is "new tab"
    /// replace that placeholder instead of leaving two tabs behind.
    private func sendInNewTab(_ commandID: String) async -> IntentResult? {
        guard let invocation = PaletteIntentInvoker.prepare(
            commandID: commandID,
            host: host
        ) else { return nil }
        return await NewTabLauncherPlacement.invoke(
            in: store,
            userGestureID: invocation.userGestureID
        ) { scope in
            await PaletteIntentInvoker.send(
                invocation,
                scope: scope,
                runtime: intentRuntime
            )
        }
    }

    /// Width the tab chips actually need, so the row can hand everything past them
    /// to the drag surface instead of letting the scroll view swallow the whole side.
    @State private var tabStripWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            leftZone
                .frame(
                    width: sidebarVisible ? sidebarWidth : TenonTheme.sidebarWidth,
                    alignment: .leading
                )

            // With the sidebar open, the shell's full-height resize edge draws this
            // seam (and makes it draggable), so the title bar must not stack a second
            // static rule at the same x. With the sidebar closed there is no edge
            // below, so the identity/tabs separator lives here.
            if !sidebarVisible {
                Rectangle()
                    .fill(TenonTheme.line)
                    .frame(width: 1)
            }

            rightZone
                .frame(maxWidth: .infinity)
        }
        .background(WindowDragArea(color: TenonTheme.chromeNS))
    }

    private var leftZone: some View {
        HStack(spacing: 8) {
            // Reserved for the OS traffic-light buttons, which overlay this corner.
            Color.clear
                .frame(width: TenonTheme.trafficLightInset)

            // Drop the wordmark first when the sidebar column is too narrow to hold
            // the full identity + toggle without the title crowding into the divider.
            // ViewThatFits keeps the last (title-less) candidate once nothing fits.
            ViewThatFits(in: .horizontal) {
                identityRow(showTitle: true)
                identityRow(showTitle: false)
            }
        }
        .padding(.trailing, 8)
    }

    /// Icon + optional "Tenon" wordmark, with the sidebar toggle pinned to the right.
    private func identityRow(showTitle: Bool) -> some View {
        HStack(spacing: 8) {
            (AppMark.image.map { Image(nsImage: $0) } ?? Image(systemName: "terminal.fill"))
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(TenonTheme.text)
                .accessibilityHidden(true)

            if showTitle {
                Text("Tenon")
                    .font(TenonTheme.interfaceFont(size: 13, weight: .bold))
                    .foregroundStyle(TenonTheme.text)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 6)

            // T-029: how many panes across the whole catalog await a human. The one
            // machine's rollup — hidden entirely while nothing needs attention.
            if totalUnseen > 0 {
                Text("\(totalUnseen)")
                    .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                    .foregroundStyle(TenonTheme.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TenonTheme.amber))
                    .help("\(totalUnseen) pane(s) finished and are waiting for you")
                    .accessibilityIdentifier("tenon.unseenCount")
            }

            ShellIconButton(
                symbol: sidebarVisible ? "sidebar.left" : "sidebar.leading",
                help: "Toggle sidebar",
                action: onToggleSidebar
            )
            .accessibilityIdentifier("tenon.toggleSidebar")
        }
    }

    private var rightZone: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(Array(activeTabs.enumerated()), id: \.element.id) { index, tab in
                        TabChip(
                            title: tabTitle(for: tab, index: index),
                            isActive: tab.id == activeWorkspace?.activeTabID,
                            attentionState: PaneAttentionProjection.tabState(
                                for: tab,
                                attention: pool.paneAttention
                            ),
                            isUnseen: PaneAttentionProjection.tabIsUnseen(
                                tab,
                                attention: pool.paneAttention
                            ),
                            canClose: activeTabs.count > 1,
                            isDropTarget: router.activeDropTarget == .existingTab(tab.id),
                            select: { store.selectTab(tab.id) },
                            close: { store.closeTab(tab.id) },
                            openLauncher: { contextLauncherTab = tab.id }
                        )
                        // Report the chip's window-space frame so a pane dragged up
                        // from the canvas can be hit-tested against it.
                        .background(WindowFrameReporter { router.tabChipFrames[tab.id] = $0 })
                        // Right-click opens the same launcher the `+` button opens —
                        // one catalog, one presentation — scoped to this chip's tab.
                        .popover(
                            isPresented: Binding(
                                get: { contextLauncherTab == tab.id },
                                set: { if !$0 { contextLauncherTab = nil } }
                            ),
                            arrowEdge: .bottom
                        ) {
                            LauncherMenu(
                                host: host,
                                intentRuntime: intentRuntime,
                                palette: palette,
                                agentSuggestions: agentSuggestions,
                                launchAgent: { suggestion in
                                    AgentLaunchExecutor.run(
                                        suggestion,
                                        placement: .tab(tab.id),
                                        workspaceStore: store,
                                        terminalPool: pool
                                    )
                                },
                                send: { commandID in
                                    LauncherOutcome(await send(commandID, onTab: tab.id))
                                },
                                dismiss: { contextLauncherTab = nil }
                            )
                        }
                    }

                    ShellIconButton(symbol: "plus", help: "Open something new") {
                        launcherPresented = true
                    }
                    .accessibilityIdentifier("tenon.newTab")
                    .overlay {
                        if router.activeDropTarget == .newTab {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(TenonTheme.amber, lineWidth: 1.5)
                        }
                    }
                    .popover(isPresented: $launcherPresented, arrowEdge: .bottom) {
                        LauncherMenu(
                            host: host,
                            intentRuntime: intentRuntime,
                            palette: palette,
                            agentSuggestions: agentSuggestions,
                            launchAgent: { suggestion in
                                AgentLaunchExecutor.run(
                                    suggestion,
                                    placement: .newTab,
                                    workspaceStore: store,
                                    terminalPool: pool
                                )
                            },
                            send: { commandID in
                                LauncherOutcome(await sendInNewTab(commandID))
                            },
                            dismiss: { launcherPresented = false }
                        )
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                tabStripWidth = width
                            }
                    }
                )
            }
            .scrollIndicators(.hidden)
            // The strip claims only the width its chips need; everything past them
            // goes to the drag surface, so the empty stretch of the row drags and
            // double-clicks like a system title bar instead of dead-ending in the
            // scroll view. The priority keeps the strip served first, so it still
            // takes the whole side (and scrolls) once the chips outgrow it.
            .frame(maxWidth: max(tabStripWidth, 1))
            .layoutPriority(1)

            WindowDragArea(color: TenonTheme.chromeNS)
                .frame(maxWidth: .infinity)

            QuickCommandControl(
                commands: quickCommands,
                workspaceStore: store,
                terminalPool: pool
            )
            .padding(.leading, 8)
            .accessibilityIdentifier("tenon.quickCommands.control")
        }
        // The whole strip is the "drop for a new tab" band; individual chips
        // carve out "drop into that tab" within it.
        .background(WindowFrameReporter { router.tabBarBand = $0 })
        .padding(.horizontal, 8)
        // Drop frames for tabs that have closed so a stale rect never claims a drop.
        .onChange(of: activeTabs.map(\.id)) { _, ids in
            router.tabChipFrames = router.tabChipFrames.filter { ids.contains($0.key) }
        }
    }

    // MARK: - Derived state

    private var activeWorkspace: Workspace? {
        store.catalog.activeWorkspace
    }

    private var totalUnseen: Int {
        PaneAttentionProjection.totalUnseen(
            catalog: store.catalog,
            attention: pool.paneAttention
        )
    }

    private var activeTabs: [TenonCore.Tab] {
        activeWorkspace?.tabs ?? []
    }

    private func tabTitle(for tab: TenonCore.Tab, index: Int) -> String {
        let terminalTitle = pool.title(for: tab)
        if terminalTitle != "Terminal" {
            return terminalTitle
        }
        return "Terminal \(index + 1)"
    }
}

private struct TabChip: View {
    let title: String
    let isActive: Bool
    /// T-029: the active slot's `PaneActivity` state — `nil` (no dot) while none of
    /// the tab's panes ever materialised.
    var attentionState: PaneActivityState?
    /// T-029: bold while any pane in this tab finished (or died) unviewed.
    var isUnseen: Bool = false
    let canClose: Bool
    var isDropTarget: Bool = false
    let select: () -> Void
    let close: () -> Void
    /// A right-click (or control-click) on the chip asks the owner to open the launcher
    /// popover anchored here — the same `LauncherMenu` the `+` button opens, scoped by
    /// the owner to this chip's tab.
    let openLauncher: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? TenonTheme.amber : TenonTheme.muted)
                if let attentionState {
                    Circle()
                        .fill(
                            Color(
                                nsColor: PaneAttentionProjection.dotColor(
                                    for: attentionState
                                )
                            )
                        )
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("tenon.tabAttentionDot")
                }
                Text(title)
                    .fontWeight(isUnseen ? .bold : .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }
            .font(TenonTheme.interfaceFont(size: 10, weight: .medium))
            .padding(.leading, 9)
            .padding(.trailing, canClose ? 28 : 9)
            // Content sizes the chip between its floor and the title's own cap, so a
            // one-word title still yields a chip you can read and aim at.
            .frame(minWidth: TenonTheme.tabMinWidth, alignment: .leading)
            .frame(height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActive
                        ? Color.primary.opacity(0.09)
                        : (isHovering ? Color.primary.opacity(0.04) : .clear)
                )
        }
        .onHover { isHovering = $0 }
        .overlay(alignment: .trailing) {
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(TenonTheme.muted)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TenonTheme.amber, lineWidth: 1.5)
            }
        }
        .overlay(RightClickCatcher(action: openLauncher))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tenon.tab")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "active" : "inactive")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// An invisible AppKit layer that turns a right-click (or control-click) into an action
/// while every other event falls through to the SwiftUI content beneath it. SwiftUI's
/// only native right-click affordance is `.contextMenu`, which draws a system menu; the
/// tab chip opens the launcher popover instead, so the click itself is caught here.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        /// Participate in hit-testing only while the event being routed is a right-click
        /// or a control-click; every other event never sees this view, so the chip's
        /// select and close buttons keep their clicks and hovers.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        /// Reachable only through the control-click branch of `hitTest`.
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            action?()
        }
    }
}

private struct ShellIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TenonTheme.muted)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
    }
}
