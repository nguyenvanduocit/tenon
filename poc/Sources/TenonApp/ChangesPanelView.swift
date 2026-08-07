import AppKit
import Observation
import SwiftUI
import TenonCore

/// A changed file in the working tree, one row of the Changes panel.
struct ChangeEntry: Identifiable, Equatable, Sendable {
    let path: String
    /// Single-letter porcelain status (M/A/D/R/U/?).
    let badge: String
    let tint: ChangeTint
    /// True for the index (staged) side, false for the worktree side.
    let staged: Bool
    let untracked: Bool

    var id: String { (staged ? "s/" : "w/") + path }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String { (path as NSString).deletingLastPathComponent }
}

enum ChangeTint: Sendable {
    case added, removed, modified, untracked, conflict
    @MainActor
    var color: Color {
        switch self {
        case .added: return Color(nsColor: NSColor(hex: 0x61C28B))
        case .removed, .conflict: return Color(nsColor: NSColor(hex: 0xED6A5E))
        case .modified: return TenonTheme.amber
        case .untracked: return TenonTheme.muted
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

// MARK: - Model

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

// MARK: - git reader (self-contained; porcelain v2, NUL-delimited)

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
                out.changed.append(ChangeEntry(path: path, badge: "U", tint: .conflict, staged: false, untracked: false))
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                out.changed.append(ChangeEntry(path: path, badge: "?", tint: .untracked, staged: false, untracked: true))
            }
            index += 1
        }
        return out
    }

    private static func add(_ out: inout Result, path: String, staged: Character, worktree: Character, untracked: Bool) {
        if staged != ".", staged != "?" {
            out.staged.append(ChangeEntry(path: path, badge: String(staged), tint: tint(staged), staged: true, untracked: false))
        }
        if worktree != "." {
            out.changed.append(ChangeEntry(path: path, badge: String(worktree), tint: tint(worktree), staged: false, untracked: untracked))
        }
    }

    private static func tint(_ code: Character) -> ChangeTint {
        switch code {
        case "A": return .added
        case "D": return .removed
        case "?": return .untracked
        case "U": return .conflict
        default: return .modified
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

    private final class Box: @unchecked Sendable { var data = Data() }

    private static func runGit(_ args: [String], in dir: String) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }
}

// MARK: - View

/// The Changes pane: a kero-style list of changed files (staged + working tree),
/// grouped and colour-coded. Clicking a file opens its diff in the host's default
/// diff view in a NEW TAB (`SlotContent.diff` via `store.newTab`) — never carved
/// inline. Replaces the old raw `git diff` text dump.
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
    @State private var hovered: String?
    /// Unmoved: the pane still owns which layout it is showing. Putting the picker in the
    /// chrome moved pixels, not ownership — the store carries a value up and a typed command
    /// back down, and this stays the only place the answer lives.
    @State private var layout: ChangesLayout = .tree
    /// Directory rows the user has collapsed, keyed by "section:dirPath".
    @State private var collapsed: Set<String> = []

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
                let selected = $layout
                let changes = model
                headerStore.onCommand(for: slotID) { command, value in
                    switch command {
                    case .changesLayout:
                        guard let next = value.flatMap(ChangesLayout.init(rawValue:)) else {
                            return
                        }
                        selected.wrappedValue = next
                    case .changesRefresh:
                        // No workspace captured: the model is what knows which one it read.
                        changes.reload()
                    case .diffStyle, .agentLensPresentation, .agentLensInspector:
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

    @ViewBuilder
    private var content: some View {
        if !model.loaded && model.isLoading {
            placeholder(icon: "arrow.clockwise", text: "Reading repository…")
        } else if !model.isRepo {
            placeholder(icon: "questionmark.folder", text: "Not a git repository")
        } else if model.total == 0 {
            placeholder(icon: "checkmark.circle", text: "Working tree clean")
        } else if embedInScrollView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { list }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) { list }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var list: some View {
        if !model.staged.isEmpty { section("Staged", model.staged) }
        if !model.changed.isEmpty { section("Changes", model.changed) }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [ChangeEntry]) -> some View {
        sectionHeader(title, entries.count)
        if layout == .flat {
            ForEach(entries) { row($0, indent: 0, showDir: true) }
        } else {
            ForEach(treeRows(entries, section: title)) { treeRow($0) }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        Text("\(title.uppercased())  \(count)")
            .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 12)
            .padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder
    private func treeRow(_ node: TreeRow) -> some View {
        switch node {
        case .directory(let id, let name, let depth):
            let isCollapsed = collapsed.contains(id)
            Button {
                if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TenonTheme.muted)
                        .frame(width: 10)
                    Text(name)
                        .font(TenonTheme.utilityFont(size: 11))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 8 + CGFloat(depth) * 9)
                .padding(.trailing, 12)
                .frame(height: 22)
                .background(hovered == id ? TenonTheme.chromeRaised : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        case .file(let entry, let depth):
            row(entry, indent: CGFloat(depth) * 9 + 5, showDir: false)
        }
    }

    private func row(_ entry: ChangeEntry, indent: CGFloat, showDir: Bool) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(TenonTheme.utilityFont(size: 11))
                    .foregroundStyle(TenonTheme.text)
                    .lineLimit(1)
                if showDir, !entry.dir.isEmpty {
                    Text(entry.dir)
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // The status letter sits on the far right, like VS Code / GitHub.
                Text(entry.badge)
                    .font(TenonTheme.utilityFont(size: 11, weight: .semibold))
                    .foregroundStyle(entry.tint.color)
            }
            .padding(.leading, 8 + indent)
            .padding(.trailing, 12)
            .frame(height: 22)
            .background(hovered == entry.id ? TenonTheme.chromeRaised : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
    }

    // MARK: tree

    private enum TreeRow: Identifiable {
        case directory(id: String, name: String, depth: Int)
        case file(entry: ChangeEntry, depth: Int)
        var id: String {
            switch self {
            case .directory(let id, _, _): return id
            case .file(let entry, _): return entry.id
            }
        }
    }

    private func treeRows(_ entries: [ChangeEntry], section: String) -> [TreeRow] {
        var rows: [TreeRow] = []
        flatten(TreeBuilder.build(entries), depth: 0, section: section, into: &rows)
        return rows
    }

    private func flatten(_ node: TreeBuilder.Node, depth: Int, section: String, into rows: inout [TreeRow]) {
        for start in node.sortedSubdirs {
            var dir = start
            var name = dir.name
            // Collapse single-child chains (poc / Sources / TenonApp → one row).
            while dir.subdirs.count == 1, dir.files.isEmpty, let only = dir.sortedSubdirs.first {
                name += "/" + only.name
                dir = only
            }
            let id = section + ":" + dir.path
            rows.append(.directory(id: id, name: name, depth: depth))
            if !collapsed.contains(id) {
                flatten(dir, depth: depth + 1, section: section, into: &rows)
            }
        }
        for file in node.sortedFiles {
            rows.append(.file(entry: file, depth: depth))
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
