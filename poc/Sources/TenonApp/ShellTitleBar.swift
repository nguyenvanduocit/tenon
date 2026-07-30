import AppKit
import SwiftUI
import TenonCore

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
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void

    @State private var launcherPresented = false
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
                            canClose: activeTabs.count > 1,
                            isDropTarget: router.activeDropTarget == .existingTab(tab.id),
                            select: { store.selectTab(tab.id) },
                            close: { store.closeTab(tab.id) }
                        )
                        // Report the chip's window-space frame so a pane dragged up
                        // from the canvas can be hit-tested against it.
                        .background(WindowFrameReporter { router.tabChipFrames[tab.id] = $0 })
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
    let canClose: Bool
    var isDropTarget: Bool = false
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? TenonTheme.amber : TenonTheme.muted)
                Text(title)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? TenonTheme.chromeRaised : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? TenonTheme.amber : Color.clear)
                .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tenon.tab")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "active" : "inactive")
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
