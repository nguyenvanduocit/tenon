// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore

/// The left navigation column: one row per workspace, an "Add Workspace…" context
/// action, and the picker that seeds a new workspace path.
struct WorkspaceSidebarView: View {
    var store: WorkspaceStore
    var pool: SurfacePool

    var body: some View {
        VStack(spacing: 0) {
            // The workspace rows read `store.catalog`, so they must re-render on every
            // tab/slot change — but this view *owns the context menu*, and macOS rebuilds
            // an open menu whenever its owning view re-renders, which reads as a shift a
            // beat after the menu appears (a terminal grabbing focus mutates the catalog).
            // So the rows live in their own view, and this one reads only the recents
            // (`RecentWorkspaceStore` is `@Observable`) plus `store.openWorkspaceFolders`,
            // which republishes when a workspace opens or closes and stays silent through
            // tab/slot churn — the menu stays put yet still refreshes when its own list changes.
            WorkspaceRowList(store: store, pool: pool)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Add Workspace…") { chooseWorkspace() }
                    // Filtered before the cap, so five offers stay five offers no matter how
                    // many of the remembered workspaces happen to be open.
                    let offered = store.recentWorkspaces?
                        .recent(excludingFolders: store.openWorkspaceFolders) ?? []
                    let recents = Array(offered.prefix(5))
                    if !recents.isEmpty {
                        Divider()
                        // Flat, plain-text items — no titled `Section` and no `Label`
                        // image. macOS re-measures a SwiftUI menu that carries a section
                        // header or icon column a beat after it opens, which showed up as
                        // the menu snapping to a narrower width; a flat list of buttons
                        // lays out once and stays put.
                        ForEach(recents) { entry in
                            Button(entry.name) { openRecent(entry) }
                        }
                    }
                }

            SidebarFooter()
        }
        .background(TenonTheme.chrome)
    }

    /// Re-open a remembered workspace. The menu only offers closed ones, but a workspace can
    /// open between the menu appearing and the click landing — so surface that one instead of
    /// adding a duplicate. The catalog is read here in the click handler, not in the view
    /// body, which keeps this check off the open menu's re-layout path.
    private func openRecent(_ entry: RecentWorkspaceStore.Entry) {
        let folder = RecentWorkspaceStore.folderKey(entry.path)
        if let open = store.catalog.workspaces.first(where: {
            RecentWorkspaceStore.folderKey($0.path) == folder
        }) {
            store.selectWorkspace(open.id)
        } else {
            store.addWorkspace(name: entry.name, path: entry.path)
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Workspace"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.addWorkspace(name: WorkspaceName.derived(for: url), path: url)
        }
    }
}

/// The scrollable list of workspace rows. Kept separate from the context-menu-bearing
/// container so this — the view that depends on `store.catalog` — can re-render freely on
/// tab/slot churn without dragging the open Add-Workspace menu through a re-layout.
private struct WorkspaceRowList: View {
    var store: WorkspaceStore
    var pool: SurfacePool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(store.catalog.workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        store: store,
                        isActive: workspace.id == store.catalog.activeWorkspaceID,
                        // T-029: this row's rollup of the one attention machine.
                        // Read here, inside the row list, so the open context menu
                        // above never re-lays-out on attention churn.
                        unseenCount: PaneAttentionProjection.unseenCount(
                            in: workspace,
                            attention: pool.paneAttention
                        ),
                        canRemove: store.catalog.workspaces.count > 1,
                        select: { store.selectWorkspace(workspace.id) },
                        remove: { store.removeWorkspace(workspace.id) }
                    )
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
        }
        .tenonScrollbarStyle()
        .scrollIndicators(.hidden)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    /// T-097: the customisation popover writes straight through to the typed workspace
    /// service, so the row hands it the store rather than a fourth closure.
    var store: WorkspaceStore
    let isActive: Bool
    /// T-029: how many of this workspace's panes finished (or died) unviewed.
    /// The row bolds and counts while it is non-zero; viewing clears it upstream.
    let unseenCount: Int
    let canRemove: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var isHovering = false
    @State private var isCustomising = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                WorkspaceMark(workspace: workspace)
                    .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name)
                        .font(
                            TenonTheme.interfaceFont(
                                size: 11,
                                weight: unseenCount > 0 ? .bold : .semibold
                            )
                        )
                        .foregroundStyle(isActive ? TenonTheme.text : TenonTheme.muted)
                        .lineLimit(1)
                    Text("\(workspace.tabs.count) \(workspace.tabs.count == 1 ? "tab" : "tabs")")
                        .font(TenonTheme.utilityFont(size: 8))
                        .foregroundStyle(TenonTheme.muted)
                }
                Spacer()

                if unseenCount > 0 {
                    Text("\(unseenCount)")
                        .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                        .foregroundStyle(TenonTheme.ink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(TenonTheme.amber))
                        .accessibilityIdentifier("tenon.workspaceUnseenCount")
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isActive
                            ? Color.primary.opacity(0.09)
                            : (isHovering ? Color.primary.opacity(0.04) : .clear)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("tenon.workspaceRow")
        // The mark is drawn, so it has to be spoken: the row announces the name it carries
        // and what it is marked with, and never leans on colour to tell two rows apart. The
        // tab count and the unseen count stay in the label — an explicit label replaces the
        // children VoiceOver would otherwise have read.
        .accessibilityLabel(
            WorkspaceRowAnnouncement.text(for: workspace, unseenCount: unseenCount)
        )
        .contextMenu {
            Button("Customise Workspace…") { isCustomising = true }
            Button("Remove Workspace", role: .destructive, action: remove)
                .disabled(!canRemove)
        }
        .popover(isPresented: $isCustomising, arrowEdge: .trailing) {
            WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: { isCustomising = false }
            )
        }
    }
}
