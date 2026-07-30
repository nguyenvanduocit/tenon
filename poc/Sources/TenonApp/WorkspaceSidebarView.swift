import AppKit
import SwiftUI
import TenonCore

/// The left navigation column: one row per workspace, an "Add Workspace…" context
/// action, and the picker that seeds a new workspace path.
struct WorkspaceSidebarView: View {
    var store: WorkspaceStore

    var body: some View {
        // The workspace rows read `store.catalog`, so they must re-render on every
        // tab/slot change — but this view *owns the context menu*, and macOS rebuilds
        // an open menu whenever its owning view re-renders, which reads as a shift a
        // beat after the menu appears (a terminal grabbing focus mutates the catalog).
        // So the rows live in their own view, and this one reads only the recents
        // (`RecentWorkspaceStore` is `@Observable`) — the menu stays put through
        // catalog churn yet still refreshes when the recent list actually changes.
        WorkspaceRowList(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.chrome)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add Workspace…") { chooseWorkspace() }
                let recents = Array((store.recentWorkspaces?.recent ?? []).prefix(5))
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
    }

    /// Re-open a remembered workspace: surface it if it's already open, otherwise add it.
    /// The catalog is read here in the click handler — not in the view body — so
    /// re-opening the same folder never spawns a duplicate, without tying the menu to
    /// the catalog's churn.
    private func openRecent(_ entry: RecentWorkspaceStore.Entry) {
        if let open = store.catalog.workspaces.first(where: { $0.path == entry.path }) {
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
            store.addWorkspace(
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                path: url
            )
        }
    }
}

/// The scrollable list of workspace rows. Kept separate from the context-menu-bearing
/// container so this — the view that depends on `store.catalog` — can re-render freely on
/// tab/slot churn without dragging the open Add-Workspace menu through a re-layout.
private struct WorkspaceRowList: View {
    var store: WorkspaceStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(store.catalog.workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isActive: workspace.id == store.catalog.activeWorkspaceID,
                        canRemove: store.catalog.workspaces.count > 1,
                        select: { store.selectWorkspace(workspace.id) },
                        remove: { store.removeWorkspace(workspace.id) }
                    )
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let canRemove: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isActive
                                ? TenonTheme.amber.opacity(0.16)
                                : TenonTheme.chromeRaised
                        )
                    Text(workspace.name.prefix(1).uppercased())
                        .font(TenonTheme.utilityFont(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? TenonTheme.amber : TenonTheme.muted)
                }
                .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.name)
                        .font(TenonTheme.interfaceFont(size: 11, weight: .semibold))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(1)
                    Text("\(workspace.tabs.count) \(workspace.tabs.count == 1 ? "tab" : "tabs")")
                        .font(TenonTheme.utilityFont(size: 8))
                        .foregroundStyle(TenonTheme.muted)
                }
                Spacer()
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 46)
            .background(
                isActive ? TenonTheme.chromeRaised.opacity(0.96) : Color.clear
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? TenonTheme.amber : Color.clear)
                    .frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenon.workspaceRow")
        .contextMenu {
            Button("Remove Workspace", role: .destructive, action: remove)
                .disabled(!canRemove)
        }
    }
}
