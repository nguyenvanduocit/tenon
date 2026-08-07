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
            store.addWorkspace(
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                path: url
            )
        }
    }
}

/// Fixed host utilities beneath the workspace list. Labeled controls collapse to icons at
/// the sidebar's minimum width; VoiceOver and tooltips retain the full names in both forms.
private struct SidebarFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    private static let helpURL = projectURL()
    private static let feedbackURL = projectURL(path: "issues/new")
    private static let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "—"
    private static let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "—"

    var body: some View {
        VStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                SidebarFooterActions(
                    showsTitles: true,
                    openHelp: openHelp,
                    openFeedback: openFeedback,
                    openSettings: openAppSettings
                )
                SidebarFooterActions(
                    showsTitles: false,
                    openHelp: openHelp,
                    openFeedback: openFeedback,
                    openSettings: openAppSettings
                )
            }

            Text("v\(Self.version) (\(Self.build))")
                .font(TenonTheme.utilityFont(size: 8))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
                .accessibilityLabel("Version \(Self.version), build \(Self.build)")
                .accessibilityIdentifier("tenon.sidebarVersion")
        }
        .padding(.horizontal, 7)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)
        }
    }

    private func openHelp() {
        openURL(Self.helpURL)
    }

    private func openFeedback() {
        openURL(Self.feedbackURL)
    }

    private func openAppSettings() {
        openSettings()
    }

    private static func projectURL(path: String? = nil) -> URL {
        let suffix = path.map { "/\($0)" } ?? ""
        guard let url = URL(string: "https://github.com/nguyenvanduocit/tenon\(suffix)") else {
            fatalError("The fixed Tenon project URL must be valid")
        }
        return url
    }
}

private struct SidebarFooterActions: View {
    let showsTitles: Bool
    let openHelp: () -> Void
    let openFeedback: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            SidebarFooterButton(
                title: "Help",
                symbol: "questionmark.circle",
                accessibilityIdentifier: "tenon.sidebarHelp",
                showsTitle: showsTitles,
                action: openHelp
            )
            SidebarFooterButton(
                title: "Feedback",
                symbol: "bubble.left",
                accessibilityIdentifier: "tenon.sidebarFeedback",
                showsTitle: showsTitles,
                action: openFeedback
            )
            SidebarFooterButton(
                title: "Settings",
                symbol: "gearshape",
                accessibilityIdentifier: "tenon.sidebarSettings",
                showsTitle: showsTitles,
                action: openSettings
            )
        }
    }
}

private struct SidebarFooterButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let accessibilityIdentifier: String
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(TenonTheme.interfaceFont(size: 8.5))
            .lineLimit(1)
            .padding(.top, showsTitle ? 13 : 0)
            .frame(
                width: showsTitle ? 44 : 28,
                height: showsTitle ? 38 : 28
            )
            .foregroundStyle(showsTitle ? TenonTheme.muted : .clear)
            .contentShape(Rectangle())
            .overlay(alignment: showsTitle ? .top : .center) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TenonTheme.muted)
                    .padding(.top, showsTitle ? 6 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .buttonStyle(.plain)
            .background(TenonTheme.chromeRaised, in: .rect(cornerRadius: 6))
            .help(title)
            .accessibilityIdentifier(accessibilityIdentifier)
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
    let isActive: Bool
    /// T-029: how many of this workspace's panes finished (or died) unviewed.
    /// The row bolds and counts while it is non-zero; viewing clears it upstream.
    let unseenCount: Int
    let canRemove: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? TenonTheme.amber : TenonTheme.muted)
                    .frame(width: 29, height: 29)
                    .accessibilityHidden(true)

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
        .contextMenu {
            Button("Remove Workspace", role: .destructive, action: remove)
                .disabled(!canRemove)
        }
    }
}
