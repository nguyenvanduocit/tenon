// @domain: workspace-model
import AppKit
import SwiftUI
import TenonCore

/// One compact budget for the sidebar's contextual workspace library. Ten rows plus the
/// optional search field stay inside the 520 pt ceiling for a focused Tenon surface.
enum WorkspaceRecentMenuMetrics {
    static let width: CGFloat = 300
    static let actionHeight: CGFloat = 34
    static let searchHeight: CGFloat = 32
    static let sectionHeight: CGFloat = 24
    static let rowHeight: CGFloat = 38
    static let listPadding: CGFloat = 4
    static let controlRadius: CGFloat = 6
    static let maximumVisibleRows = 10

    static func listHeight(rowCount: Int) -> CGFloat {
        CGFloat(max(1, min(rowCount, maximumVisibleRows))) * rowHeight
            + listPadding * 2
    }
}

/// Pure query/cap rules, kept outside the view so the ten-visible/twenty-retained contract
/// cannot drift with SwiftUI composition.
enum WorkspaceRecentMenuProjection {
    static func showsSearch(for entries: [RecentWorkspaceStore.Entry]) -> Bool {
        entries.count > WorkspaceRecentMenuMetrics.maximumVisibleRows
    }

    static func visible(
        entries: [RecentWorkspaceStore.Entry],
        query: String
    ) -> [RecentWorkspaceStore.Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = needle.isEmpty
            ? entries
            : entries.filter { entry in
                entry.name.localizedCaseInsensitiveContains(needle)
                    || entry.path.path.localizedCaseInsensitiveContains(needle)
            }
        return Array(matches.prefix(WorkspaceRecentMenuMetrics.maximumVisibleRows))
    }
}

/// Searchable recent workspaces shown for a secondary click in the sidebar's empty area.
/// Opening and adding both call the same typed `WorkspaceStore` service as the old menu.
struct WorkspaceRecentMenu: View {
    var store: WorkspaceStore
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var offered: [RecentWorkspaceStore.Entry] {
        store.recentWorkspaces?
            .recent(excludingFolders: store.openWorkspaceFolders) ?? []
    }

    var body: some View {
        let entries = offered
        let visible = WorkspaceRecentMenuProjection.visible(entries: entries, query: query)
        let selected = visible.isEmpty ? 0 : min(selection, visible.count - 1)

        VStack(spacing: 0) {
            addWorkspaceButton
            separator

            if WorkspaceRecentMenuProjection.showsSearch(for: entries) {
                searchField
                separator
            }

            Text("RECENT WORKSPACES")
                .font(TenonTheme.utilityFont(size: 9, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: WorkspaceRecentMenuMetrics.sectionHeight)
                .accessibilityHidden(true)

            results(entries: visible, selected: selected)
        }
        .frame(width: WorkspaceRecentMenuMetrics.width)
        .background(TenonTheme.chromeRaised)
        .tint(TenonTheme.amber)
        .defaultFocus($searchFocused, true)
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) {
            move(1, count: visible.count)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1, count: visible.count)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .accessibilityIdentifier("tenon.workspaceRecentMenu")
    }

    private var addWorkspaceButton: some View {
        Button(action: chooseWorkspace) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(TenonTheme.amber)
                    .accessibilityHidden(true)
                Text("Add Workspace…")
                    .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                    .foregroundStyle(TenonTheme.text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: WorkspaceRecentMenuMetrics.actionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenon.workspaceRecentMenu.add")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .frame(width: 16)
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            TextField("Search recent workspaces…", text: $query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.text)
                .focused($searchFocused)
                .onSubmit(openSelected)
                .accessibilityLabel("Search recent workspaces")
                .accessibilityIdentifier("tenon.workspaceRecentMenu.search")
        }
        .padding(.horizontal, 12)
        .frame(height: WorkspaceRecentMenuMetrics.searchHeight)
    }

    @ViewBuilder
    private func results(entries: [RecentWorkspaceStore.Entry], selected: Int) -> some View {
        if entries.isEmpty {
            Text(query.isEmpty ? "No recent workspaces" : "No matching workspaces")
                .font(TenonTheme.interfaceFont(size: 11))
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: WorkspaceRecentMenuMetrics.rowHeight)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // The direct `EnumeratedSequence` collection conformance is macOS 26;
                    // Tenon targets macOS 14, so materialise these at-most-ten rows.
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        WorkspaceRecentRow(
                            entry: entry,
                            isSelected: index == selected,
                            open: { openRecent(entry) }
                        )
                    }
                }
                .padding(.vertical, WorkspaceRecentMenuMetrics.listPadding)
            }
            .tenonScrollbarStyle()
            .frame(height: WorkspaceRecentMenuMetrics.listHeight(rowCount: entries.count))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recent workspaces")
        }
    }

    private var separator: some View {
        Rectangle().fill(TenonTheme.line).frame(height: 1)
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func openSelected() {
        let entries = WorkspaceRecentMenuProjection.visible(entries: offered, query: query)
        guard !entries.isEmpty else { return }
        openRecent(entries[min(max(selection, 0), entries.count - 1)])
    }

    private func openRecent(_ entry: RecentWorkspaceStore.Entry) {
        let folder = RecentWorkspaceStore.folderKey(entry.path)
        if let open = store.catalog.workspaces.first(where: {
            RecentWorkspaceStore.folderKey($0.path) == folder
        }) {
            dismiss()
            store.selectWorkspace(open.id)
        } else {
            dismiss()
            store.addWorkspace(
                name: entry.name,
                path: entry.path,
                appearance: entry.appearance
            )
        }
    }

    private func chooseWorkspace() {
        dismiss()
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

private struct WorkspaceRecentRow: View {
    let entry: RecentWorkspaceStore.Entry
    let isSelected: Bool
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                WorkspaceMark(recent: entry, size: 13)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(TenonTheme.interfaceFont(size: 11, weight: .semibold))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(1)
                    Text(entry.path.path)
                        .font(TenonTheme.utilityFont(size: 8.5))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: WorkspaceRecentMenuMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: WorkspaceRecentMenuMetrics.controlRadius)
                    .fill(
                        isSelected
                            ? TenonTheme.amber.opacity(0.13)
                            : (isHovering ? Color.primary.opacity(0.05) : .clear)
                    )
                    .padding(.horizontal, 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.path.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.name), \(entry.appearance.symbol.label), \(entry.path.path)"
        )
        .accessibilityIdentifier("tenon.workspaceRecentMenu.row")
    }
}

/// Frames of the live workspace rows in the sidebar coordinate space. The secondary-click
/// monitor uses them only to let a row's own Customise/Remove context menu win.
struct WorkspaceRowFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

/// AppKit supplies the secondary-click event SwiftUI doesn't expose. The representable is
/// hit-test transparent and consumes only clicks its caller explicitly claims.
struct SidebarContextClickCatcher: NSViewRepresentable {
    let claim: (CGPoint) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(claim: claim)
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        context.coordinator.claim = claim
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var claim: (CGPoint) -> Bool
        private weak var view: CatcherView?
        private var eventMonitor: Any?

        init(claim: @escaping (CGPoint) -> Bool) {
            self.claim = claim
        }

        func attach(to view: CatcherView) {
            detach()
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                guard let self, let location = self.location(for: event) else { return event }
                return self.claim(location) ? nil : event
            }
        }

        func detach() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            view = nil
        }

        private func location(for event: NSEvent) -> CGPoint? {
            guard event.type == .rightMouseDown
                    || (event.type == .leftMouseDown
                        && event.modifierFlags.contains(.control)),
                  let view,
                  event.window === view.window
            else { return nil }
            let location = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(location) ? location : nil
        }
    }

    final class CatcherView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
