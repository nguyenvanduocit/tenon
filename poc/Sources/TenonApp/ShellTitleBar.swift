import AppKit
import SwiftUI
import TenonCore

/// The full-width top row shared with the traffic lights. Its left zone (app identity
/// + sidebar toggle) sits above the sidebar column; its right zone (tab strip + the
/// "add slot" menu) sits above the content column. The whole row is a window-drag
/// surface, with interactive controls carving their own clicks out of it.
struct ShellTitleBar: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var router: DragRouter
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void

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
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)

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
        HStack(spacing: 8) {
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

                    ShellIconButton(symbol: "plus", help: "New tab (⌘T)") {
                        store.newTab()
                    }
                    .accessibilityIdentifier("tenon.newTab")
                    .overlay {
                        if router.activeDropTarget == .newTab {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(TenonTheme.amber, lineWidth: 1.5)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole strip is the "drop for a new tab" band; individual chips
            // carve out "drop into that tab" within it.
            .background(WindowFrameReporter { router.tabBarBand = $0 })

            slotControls
        }
        .padding(.horizontal, 8)
        // Drop frames for tabs that have closed so a stale rect never claims a drop.
        .onChange(of: activeTabs.map(\.id)) { _, ids in
            router.tabChipFrames = router.tabChipFrames.filter { ids.contains($0.key) }
        }
    }

    private var slotControls: some View {
        Menu {
            Button("Terminal") { store.addSlot(content: .terminal) }
            Button("Files") {
                store.addSlot(
                    content: .pluginView(
                        pluginID: "dev.tenon.file-explorer",
                        viewID: "tree"
                    )
                )
            }
            Button("Diff") { store.addSlot(content: .changes) }
            Button("Docs") { store.addSlot(content: .docs) }
            Button("Browser") {
                store.addSlot(
                    content: .pluginView(
                        pluginID: "dev.tenon.browser",
                        viewID: "browser"
                    )
                )
            }
        } label: {
            Label("Add slot", systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(TenonTheme.interfaceFont(size: 10, weight: .semibold))
        .foregroundStyle(TenonTheme.ink)
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(TenonTheme.amber)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            .frame(height: 32)
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
                        .frame(width: 24, height: 32)
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
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TenonTheme.muted)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
    }
}
