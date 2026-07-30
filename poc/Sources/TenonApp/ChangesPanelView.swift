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

/// How the changed-file list is laid out: a flat list (file + dir) or a collapsible
/// directory tree. The user toggles between them in the panel header.
enum ChangesLayout { case flat, tree }

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

    private var loadedWorkspace: URL?
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
    @State private var model: ChangesModel
    @State private var hovered: String?
    @State private var layout: ChangesLayout = .tree
    /// Directory rows the user has collapsed, keyed by "section:dirPath".
    @State private var collapsed: Set<String> = []

    init(root: URL, store: WorkspaceStore?) {
        self.root = root
        self.store = store
        self.autoLoad = true
        self.embedInScrollView = true
        _model = State(initialValue: ChangesModel())
    }

    /// Offscreen-snapshot init: a seeded model, no git load, no scroll container.
    init(previewModel: ChangesModel) {
        self.root = nil
        self.store = nil
        self.autoLoad = false
        self.embedInScrollView = false
        _model = State(initialValue: previewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TenonTheme.panel)
        .onAppear { if autoLoad, let root { model.load(root) } }
        .onChange(of: root) { _, newRoot in if autoLoad, let newRoot { model.load(newRoot, force: true) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.branch")
                .font(.system(size: 10))
                .foregroundStyle(TenonTheme.muted)
            Text(model.isRepo ? model.branch : "CHANGES")
                .font(TenonTheme.utilityFont(size: 10, weight: .semibold))
                .foregroundStyle(TenonTheme.text)
                .lineLimit(1)
            if model.total > 0 {
                Text("\(model.total)")
                    .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(TenonTheme.chromeRaised, in: Capsule())
            }
            Spacer()
            layoutToggle
            if autoLoad {
                Button { if let root { model.load(root, force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TenonTheme.muted)
                .disabled(model.isLoading)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(TenonTheme.chromeRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(TenonTheme.line).frame(height: 1) }
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            toggleButton(.tree, icon: "list.bullet.indent", help: "Tree")
            toggleButton(.flat, icon: "list.dash", help: "Flat")
        }
    }

    private func toggleButton(_ mode: ChangesLayout, icon: String, help: String) -> some View {
        Button { layout = mode } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(layout == mode ? TenonTheme.amber : TenonTheme.muted.opacity(0.55))
                .frame(width: 22, height: 18)
                .background(
                    layout == mode ? TenonTheme.amber.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(help)
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
        store.showDiff(DiffRequest(
            source: .git(
                repoPath: model.repoRoot, path: entry.path,
                staged: entry.staged, untracked: entry.untracked, origPath: nil
            ),
            fileName: entry.name,
            title: entry.name + (entry.staged ? " (staged)" : "")
        ))
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
