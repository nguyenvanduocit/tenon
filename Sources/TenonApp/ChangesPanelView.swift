// @domain: repository-read, row-list
import AppKit
import Observation
import SwiftUI
import TenonCore

/// A changed file in the working tree, one row of the Changes panel.
struct ChangeEntry: Identifiable, Equatable, Sendable {
    let path: String
    /// Single-letter porcelain status (M/A/D/R/U/?).
    let badge: String
    /// True for the index (staged) side, false for the worktree side.
    let staged: Bool
    let untracked: Bool

    var id: String { (staged ? "s/" : "w/") + path }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String { (path as NSString).deletingLastPathComponent }

    /// The colour the status letter is drawn in, DERIVED from the letter rather than stored
    /// beside it. Two fields that must agree are two fields that can disagree, and this pair
    /// had no way to be wrong at only one of its six construction sites — so the answer is
    /// computed once, here, from the one field git actually reported.
    var tint: ColorToken {
        switch badge {
        case "A": return .green
        case "D", "U": return .red
        case "?": return .muted
        default: return .amber
        }
    }
}

/// How the changed-file list is laid out: a collapsible directory tree or a flat list
/// (file + dir). The user picks between them in the pane's chrome header.
///
/// Raw values because both ends of that picker are minted from this enum: the segments the
/// user sees and the value a click reports back arrive as strings, and taking them from the
/// cases themselves is what stops the two ends drifting apart. Declaration order IS the order
/// the segments draw in, so `allCases` is the only place that order is written down.
enum ChangesLayout: String, CaseIterable {
    case tree, flat

    /// The icon-only segment's glyph, and what VoiceOver reads for it.
    var symbolName: String { self == .tree ? "list.bullet.indent" : "list.dash" }
    var title: String { self == .tree ? "Tree" : "Flat" }
}

/// What the Changes pane contributes to the ONE chrome header the card draws.
///
/// Pure and outside the view for the same reason `DiffPaneHeader` is: choosing what a pane has
/// to say is arithmetic over the pane's own state, and once the items are chosen the drawing
/// has no decisions left in it. `ChangesLayout` is internal, so unlike Diff's private
/// `DiffStyle` it can be spoken here directly — which removes a Bool the caller could invert.
enum ChangesPaneHeader {
    /// - Parameters:
    ///   - branch: the checked-out branch, or `nil` when the workspace is not a repository.
    ///   - canRefresh: whether this pane loads git at all. The snapshot pane seeds a model and
    ///     never reads the working tree, so offering it a refresh would offer a button that
    ///     could not do anything.
    static func header(
        branch: String?,
        total: Int,
        layout: ChangesLayout,
        isLoading: Bool,
        canRefresh: Bool
    ) -> PaneHeader {
        var leading: [PaneHeaderItem] = [
            .image(id: "vcs", systemName: "arrow.trianglehead.branch", tint: .muted, tooltip: nil),
            // A workspace that is not a repository still opens this pane, and it still has to
            // name itself; the chrome title says what the pane IS, this says what it is OF.
            .label(
                id: "branch",
                text: branch ?? "CHANGES",
                weight: .semibold,
                color: .text,
                truncation: .middle,
                tooltip: nil
            ),
        ]
        // A zero would only restate the "Working tree clean" placeholder already filling the
        // body, and it would do it in the one strip where width is scarce.
        if total > 0 {
            leading.append(.badge(id: "count", text: "\(total)", tint: .muted, tooltip: nil))
        }

        var trailing: [PaneHeaderItem] = [
            .segmented(
                id: PaneHeaderCommand.changesLayout.rawValue,
                segments: ChangesLayout.allCases.compactMap {
                    // Icon-only, so the segment draws no words of its own. One authored
                    // string reaches both readers that need some: `PaneHeaderSegment` lends
                    // the spoken name to the hover text when no tooltip was written, which
                    // is how "Tree"/"Flat" survive the move out of the in-body picker.
                    PaneHeaderSegment(
                        value: $0.rawValue,
                        systemName: $0.symbolName,
                        accessibilityLabel: $0.title
                    )
                },
                selection: layout.rawValue,
                isEnabled: true,
                accessibilityID: nil
            ),
        ]
        if canRefresh {
            trailing.append(
                .iconButton(
                    id: PaneHeaderCommand.changesRefresh.rawValue,
                    systemName: "arrow.clockwise",
                    tint: .muted,
                    // Load-bearing, not cosmetic: a read is already in flight and a second one
                    // would race it. Disabling rather than hiding also keeps the header from
                    // reflowing every time the pane reloads.
                    isEnabled: !isLoading,
                    // The tooltip is what this control reads as once the width folds it into
                    // the overflow menu, where an untitled button would show its raw id.
                    tooltip: "Refresh",
                    accessibilityID: nil
                )
            )
        }

        return PaneHeader(leading: leading, trailing: trailing)
    }
}

/// Builds a directory tree from a flat list of changed files.
private enum TreeBuilder {
    final class Node {
        let name: String
        let path: String
        var subdirs: [String: Node] = [:]
        var files: [ChangeEntry] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        var sortedSubdirs: [Node] {
            subdirs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var sortedFiles: [ChangeEntry] {
            files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    static func build(_ entries: [ChangeEntry]) -> Node {
        let root = Node(name: "", path: "")
        for entry in entries {
            var node = root
            var prefix = ""
            if !entry.dir.isEmpty {
                for component in entry.dir.split(separator: "/").map(String.init) {
                    prefix = prefix.isEmpty ? component : prefix + "/" + component
                    if node.subdirs[component] == nil {
                        node.subdirs[component] = Node(name: component, path: prefix)
                    }
                    node = node.subdirs[component]!
                }
            }
            node.files.append(entry)
        }
        return root
    }
}

// MARK: - Model  @domain: repository-read

@MainActor
@Observable
final class ChangesModel {
    private(set) var isRepo = false
    private(set) var branch = "?"
    private(set) var repoRoot = ""
    private(set) var staged: [ChangeEntry] = []
    private(set) var changed: [ChangeEntry] = []
    private(set) var loaded = false
    private(set) var isLoading = false

    /// The workspace this model is currently showing — the one `load` last accepted, which is
    /// not necessarily the one the pane was created with.
    private(set) var loadedWorkspace: URL?
    private var task: Task<Void, Never>?

    var total: Int { staged.count + changed.count }

    init() {}

    /// Seeds a fully-resolved model without touching git — used only by the
    /// offscreen snapshot so a headless render has content.
    init(previewBranch: String, staged: [ChangeEntry], changed: [ChangeEntry]) {
        self.isRepo = true
        self.loaded = true
        self.branch = previewBranch
        self.staged = staged
        self.changed = changed
    }

    /// Re-reads the workspace this model is already showing.
    ///
    /// Refresh takes no workspace argument on purpose. Its caller is a header handler
    /// registered once from `.onAppear`, and `.onAppear` does not run again when the pane is
    /// handed a different root: `SpatialSlotCardView.configure` assigns `contentHost.rootView`
    /// in place rather than remounting the pane. A root captured at registration is therefore
    /// the root the pane had when it mounted, for as long as the pane lives — so the refresh
    /// button would silently re-read a repository the user stopped looking at. This model is
    /// the thing that knows which workspace it actually read, and asking it to repeat itself
    /// is the only phrasing of "refresh" that cannot go stale.
    ///
    /// A model that has never loaded — the seeded snapshot — has nothing to repeat, and is
    /// also the pane that publishes no refresh button in the first place.
    func reload() {
        guard let loadedWorkspace else { return }
        load(loadedWorkspace, force: true)
    }

    func load(_ workspace: URL, force: Bool = false) {
        if !force, loadedWorkspace == workspace, loaded { return }
        loadedWorkspace = workspace
        task?.cancel()
        isLoading = true
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GitStatusReader.read(workspace: workspace.path)
            }.value
            guard let self, !Task.isCancelled, self.loadedWorkspace == workspace else { return }
            self.isRepo = result.isRepo
            self.branch = result.branch
            self.repoRoot = result.root
            self.staged = result.staged
            self.changed = result.changed
            self.loaded = true
            self.isLoading = false
        }
    }
}

// MARK: - git reader (self-contained; porcelain v2, NUL-delimited)  @domain: repository-read

enum GitStatusReader {
    struct Result: Sendable {
        var isRepo = false
        var branch = "?"
        var root = ""
        var staged: [ChangeEntry] = []
        var changed: [ChangeEntry] = []
    }

    static func read(workspace: String) -> Result {
        var out = Result()
        let top = runGit(["rev-parse", "--show-toplevel"], in: workspace)
        guard top.status == 0 else { return out }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return out }
        out.root = root

        let status = runGit(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root
        )
        guard status.status == 0 else { return out }
        out.isRepo = true

        let records = status.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst(14))
                out.branch = name == "(detached)" ? "detached" : name
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") {
                let isRename = record.hasPrefix("2 ")
                let xy = Array(record.dropFirst(2).prefix(2))
                if xy.count == 2 {
                    let path = pathAfter(record, isRename ? 9 : 8)
                    add(&out, path: path, staged: xy[0], worktree: xy[1], untracked: false)
                }
                if isRename { index += 1 }  // consume the original-path token
            } else if record.hasPrefix("u ") {
                let path = pathAfter(record, 10)
                out.changed.append(ChangeEntry(path: path, badge: "U", staged: false, untracked: false))
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                out.changed.append(ChangeEntry(path: path, badge: "?", staged: false, untracked: true))
            }
            index += 1
        }
        return out
    }

    private static func add(_ out: inout Result, path: String, staged: Character, worktree: Character, untracked: Bool) {
        if staged != ".", staged != "?" {
            out.staged.append(ChangeEntry(path: path, badge: String(staged), staged: true, untracked: false))
        }
        if worktree != "." {
            out.changed.append(ChangeEntry(path: path, badge: String(worktree), staged: false, untracked: untracked))
        }
    }

    private static func pathAfter(_ record: String, _ n: Int) -> String {
        var count = 0
        let chars = Array(record)
        for i in chars.indices where chars[i] == " " {
            count += 1
            if count == n { return String(chars[(i + 1)...]) }
        }
        return ""
    }

    private static func runGit(_ args: [String], in dir: String) -> (status: Int32, stdout: String) {
        let output = GitCommand.run(args, in: dir)
        return (output.exceededLimit ? -1 : output.status, output.text)
    }
}

// MARK: - rows  @domain: row-list

/// Turns a loaded `ChangesModel` into the rows the shared list draws, plus the two lookups
/// a click needs to interpret a row id.
///
/// Pure, and outside the view, for the reason the header builder is: which rows exist is
/// arithmetic over the model, the layout and the collapsed set, and none of that needs a
/// window to be true. It is also the whole of what this pane still decides about drawing —
/// indent, hover, chevron and menu all belong to `TreeRowsView` now.
struct ChangesRowPlan {
    /// Row ids that name a section heading or a directory, so the click handler can tell
    /// "toggle me" from "open my diff" without re-deriving the tree.
    let items: [TreeRowItem]
    let entries: [String: ChangeEntry]
    let directories: Set<String>

    // These rows publish no `menu`, and that is a decision rather than an omission. The verbs
    // a changed file wants — reveal it in Finder, copy its path — already exist as the
    // canonical intents `file.reveal.v1` and `clipboard.write.v1`, so spelling them here would
    // mean new same-owner DIRECT behaviour, and `docs/architecture-interaction-boundaries.md`
    // records that this inventory already grew 3.21× in characters "ambient, not decided".
    // Adding to it is a reviewed edit, and reusing a row renderer is not the change that
    // earns one. What the shared row gives these files WITHOUT any of that: drag a row to
    // Finder or a terminal, which is the path verb a human reaches for most (T-086 carries
    // the question of the rest).

    static func build(
        staged: [ChangeEntry],
        changed: [ChangeEntry],
        layout: ChangesLayout,
        collapsed: Set<String>,
        selected: String?,
        repoRoot: String
    ) -> ChangesRowPlan {
        var plan = Builder(layout: layout, collapsed: collapsed, selected: selected, repoRoot: repoRoot)
        if !staged.isEmpty { plan.section("Staged", staged) }
        if !changed.isEmpty { plan.section("Changes", changed) }
        return ChangesRowPlan(
            items: plan.items,
            entries: plan.entries,
            directories: plan.directories
        )
    }

    private struct Builder {
        let layout: ChangesLayout
        let collapsed: Set<String>
        let selected: String?
        let repoRoot: String

        var items: [TreeRowItem] = []
        var entries: [String: ChangeEntry] = [:]
        var directories: Set<String> = []

        /// An absolute path, or nil when this model was seeded rather than read. Nil disables
        /// the row's drag-out and its Finder verbs, which is correct: a snapshot's paths name
        /// no file on this disk.
        func absolute(_ path: String) -> String? {
            repoRoot.isEmpty ? nil : (repoRoot as NSString).appendingPathComponent(path)
        }

        mutating func section(_ title: String, _ files: [ChangeEntry]) {
            items.append(TreeRowItem(
                kind: .sectionHeader,
                id: "section:" + title,
                label: title,
                depth: 0,
                icon: nil,
                accessory: RowAccessory(text: "\(files.count)", tint: .muted)
            ))
            if layout == .flat {
                for file in files { append(file, depth: 0, showDirectory: true) }
            } else {
                flatten(TreeBuilder.build(files), depth: 0, section: title)
            }
        }

        mutating func append(_ entry: ChangeEntry, depth: Int, showDirectory: Bool) {
            entries[entry.id] = entry
            items.append(TreeRowItem(
                id: entry.id,
                label: entry.name,
                detail: showDirectory && !entry.dir.isEmpty ? entry.dir : nil,
                depth: depth,
                icon: "doc.text",
                selected: selected == entry.id,
                accessory: RowAccessory(text: entry.badge, tint: entry.tint),
                path: absolute(entry.path)
            ))
        }

        mutating func flatten(_ node: TreeBuilder.Node, depth: Int, section: String) {
            for start in node.sortedSubdirs {
                var directory = start
                var name = directory.name
                // Collapse single-child chains (Sources / TenonApp / Canvas → one row).
                while directory.subdirs.count == 1,
                      directory.files.isEmpty,
                      let only = directory.sortedSubdirs.first
                {
                    name += "/" + only.name
                    directory = only
                }
                let id = section + ":" + directory.path
                directories.insert(id)
                let isCollapsed = collapsed.contains(id)
                items.append(TreeRowItem(
                    id: id,
                    label: name,
                    depth: depth,
                    icon: "folder.fill",
                    expanded: !isCollapsed,
                    path: absolute(directory.path)
                ))
                if !isCollapsed {
                    flatten(directory, depth: depth + 1, section: section)
                }
            }
            for file in node.sortedFiles {
                append(file, depth: depth, showDirectory: false)
            }
        }
    }
}

// MARK: - View  @domain: row-list

/// The Changes pane: the changed files of the working tree (staged + unstaged), grouped and
/// colour-coded, drawn by the same `TreeRowsView` the file explorer uses. Clicking a file
/// opens its diff in the tab's diff pane, or beside it — never a new tab.
struct ChangesPanelView: View {
    let store: WorkspaceStore?
    private let root: URL?
    private let autoLoad: Bool
    private let embedInScrollView: Bool
    /// Which pane this is, so its header contribution can be told apart from every other
    /// pane's in the one store the canvas reads.
    private let slotID: UUID
    /// Where the header goes UP. The already-projected value comes back DOWN through
    /// `SpatialSlotCardView.configure`; this is the other half of that loop.
    private let headerStore: PaneHeaderStore
    @State private var model: ChangesModel
    /// Unmoved: the pane still owns which layout it is showing. Putting the picker in the
    /// chrome moved pixels, not ownership — the store carries a value up and a typed command
    /// back down, and this stays the only place the answer lives.
    @State private var layout: ChangesLayout = .tree
    /// Directory rows the user has collapsed, keyed by "section:dirPath".
    @State private var collapsed: Set<String> = []
    /// The row the user last opened, so the list keeps showing which diff is on screen.
    @State private var selected: String?

    init(root: URL, slotID: UUID, headerStore: PaneHeaderStore, store: WorkspaceStore?) {
        self.root = root
        self.slotID = slotID
        self.headerStore = headerStore
        self.store = store
        self.autoLoad = true
        self.embedInScrollView = true
        _model = State(initialValue: ChangesModel())
    }

    /// Offscreen-snapshot init: a seeded model, no git load, no scroll container.
    init(previewModel: ChangesModel, slotID: UUID, headerStore: PaneHeaderStore) {
        self.root = nil
        self.slotID = slotID
        self.headerStore = headerStore
        self.store = nil
        self.autoLoad = false
        self.embedInScrollView = false
        _model = State(initialValue: previewModel)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TenonTheme.panel)
            .onAppear {
                if autoLoad, let root { model.load(root) }
                // The controls in the chrome report an item id; the router turns it back into
                // a typed command and this is where the pane acts on it.
                //
                // Only things that OUTLIVE a re-root are captured, because this closure does:
                // `.onAppear` runs once per mount while the canvas keeps handing the same
                // hosting view new roots, so anything read out of the view struct here is
                // frozen at mount time. `$layout` is a binding into `@State` and `model` is
                // `@State` itself; both address storage the pane keeps across every re-root,
                // and neither is a copy of a value that has since moved on.
                let selectedLayout = $layout
                let changes = model
                headerStore.onCommand(for: slotID) { command, value in
                    switch command {
                    case .changesLayout:
                        guard let next = value.flatMap(ChangesLayout.init(rawValue:)) else {
                            return
                        }
                        selectedLayout.wrappedValue = next
                    case .changesRefresh:
                        // No workspace captured: the model is what knows which one it read.
                        changes.reload()
                    case .diffStyle, .agentLensPresentation, .agentLensInspector, .agentLensAccount:
                        return
                    }
                }
            }
            .onChange(of: root) { _, newRoot in if autoLoad, let newRoot { model.load(newRoot, force: true) } }
            // Published from `.onChange`, never from `body`: writing to an observable during a
            // view update is what makes SwiftUI re-enter, and the store's equality guard is a
            // backstop for that mistake rather than a licence to make it. `initial: true` is
            // the pane's first publish, so the branch name is up before the first reload.
            .onChange(of: header, initial: true) { _, next in
                headerStore.publish(next, for: slotID)
            }
            .onDisappear { headerStore.clear(for: slotID) }
    }

    /// This pane's chrome contribution for its current state.
    ///
    /// Reading model state here registers the observation that makes the `.onChange` above
    /// fire — the read is in the view graph, the write is not.
    private var header: PaneHeader {
        ChangesPaneHeader.header(
            branch: model.isRepo ? model.branch : nil,
            total: model.total,
            layout: layout,
            isLoading: model.isLoading,
            canRefresh: autoLoad
        )
    }

    private var plan: ChangesRowPlan {
        ChangesRowPlan.build(
            staged: model.staged,
            changed: model.changed,
            layout: layout,
            collapsed: collapsed,
            selected: selected,
            repoRoot: model.repoRoot
        )
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded && model.isLoading {
            placeholder(icon: "arrow.clockwise", text: "Reading repository…")
        } else if !model.isRepo {
            placeholder(icon: "questionmark.folder", text: "Not a git repository")
        } else if model.total == 0 {
            placeholder(icon: "checkmark.circle", text: "Working tree clean")
        } else {
            let plan = plan
            TreeRowsView(
                items: plan.items,
                onSelect: { id, menuID in select(id, menuID, in: plan) },
                // No row of this pane is ever `editing`, so nothing can commit an edit.
                onSubmit: { _, _ in },
                scrolls: embedInScrollView
            )
        }
    }

    // MARK: interaction  @domain: row-list

    /// - Parameter menuID: which context-menu entry was picked. These rows publish no menu,
    ///   so it is always nil here; the parameter exists because the shared row list offers one
    ///   route back for a click and a menu pick alike.
    private func select(_ id: String, _ menuID: String?, in plan: ChangesRowPlan) {
        guard menuID == nil else { return }
        if plan.directories.contains(id) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        } else if let entry = plan.entries[id] {
            selected = id
            open(entry)
        }
    }

    private func open(_ entry: ChangeEntry) {
        guard let store, !model.repoRoot.isEmpty else { return }
        // Reuse the tab's diff pane if it exists, else open one beside — never a new tab.
        store.openContent(.diff(DiffRequest(
            source: .git(
                repoPath: model.repoRoot, path: entry.path,
                staged: entry.staged, untracked: entry.untracked, origPath: nil
            ),
            fileName: entry.name,
            title: entry.name + (entry.staged ? " (staged)" : "")
        )))
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TenonTheme.muted.opacity(0.6))
            Text(text)
                .font(TenonTheme.utilityFont(size: 10))
                .foregroundStyle(TenonTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
