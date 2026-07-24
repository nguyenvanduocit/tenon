import AppKit
import SwiftUI
import TenonCore

/// The left navigation column: one row per workspace, an "Add Workspace…" context
/// action, and the picker that seeds a new workspace path.
struct WorkspaceSidebarView: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.chrome)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Add Workspace…") { chooseWorkspace() }
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
