import AppKit
import Observation
import SwiftUI
import TenonCore

// MARK: - Content model

/// Both resolved sides of a diff, produced off the main actor.
private struct ResolvedDiff: Sendable {
    var old = ""
    var new = ""
    var error: String?
    var binary = false
}

/// Owns a diff pane's two sides. For an `.inline` request the text is already in
/// hand; for a `.git` request it resolves both blobs off-main (a generation guard
/// drops a stale load if the pane is asked to reload before the last finished). The
/// line diff itself is the pure `LineDiff` engine's job, computed once per content
/// change and cached — not per render.
@MainActor
@Observable
final class DiffContentModel {
    private(set) var oldText = ""
    private(set) var newText = ""
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var isBinary = false

    /// Computed once when the content changes (not per render).
    private(set) var hunks: [DiffHunk] = []
    private(set) var stat: (added: Int, removed: Int) = (0, 0)
    /// The largest line number shown, so the gutter is exactly as wide as it needs.
    private(set) var maxLineNumber = 1

    private(set) var request: DiffRequest
    private var generation = 0
    private var task: Task<Void, Never>?

    var fileName: String { request.fileName }
    var hasChanges: Bool { oldText != newText }

    init(request: DiffRequest) {
        self.request = request
        // Resolve at construction so a diff starts loading before `onAppear`.
        reload()
    }

    func reload(_ newRequest: DiffRequest? = nil) {
        if let newRequest { request = newRequest }
        generation += 1
        let gen = generation
        task?.cancel()
        error = nil

        switch request.source {
        case .inline(let old, let new):
            oldText = old
            newText = new
            isBinary = false
            isLoading = false
            recompute()
        case .git(let repoPath, let path, let staged, let untracked, let origPath):
            isLoading = true
            task = Task { [weak self] in
                let resolved = await DiffGitLoader.load(
                    repoPath: repoPath, path: path,
                    staged: staged, untracked: untracked, origPath: origPath
                )
                guard let self, self.generation == gen else { return }
                self.oldText = resolved.old
                self.newText = resolved.new
                self.error = resolved.error
                self.isBinary = resolved.binary
                self.isLoading = false
                self.recompute()
            }
        }
    }

    private func recompute() {
        hunks = LineDiff.hunks(old: oldText, new: newText, context: 3)
        stat = LineDiff.stat(old: oldText, new: newText)
        maxLineNumber = hunks.flatMap(\.lines).reduce(1) {
            Swift.max($0, Swift.max($1.oldNumber ?? 0, $1.newNumber ?? 0))
        }
    }
}

/// Resolves diff sides from git without touching the main actor. Self-contained
/// (no shared process helper) so this pane stays independent of the built-in slot
/// views. Content only — the diffing is `LineDiff`'s job.
private enum DiffGitLoader {
    private static let maxBytes = 4 << 20  // 4 MB — past this a text diff is not useful

    static func load(
        repoPath: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) async -> ResolvedDiff {
        await Task.detached(priority: .userInitiated) {
            var out = ResolvedDiff()
            let oldPath = origPath ?? path
            if staged {
                out.old = blob(spec: "HEAD:\(oldPath)", repo: repoPath, into: &out)
                out.new = blob(spec: ":\(path)", repo: repoPath, into: &out)
            } else if untracked {
                out.new = worktree(repo: repoPath, path: path, into: &out)
            } else {
                out.old = blob(spec: ":\(oldPath)", repo: repoPath, into: &out)
                if out.old.isEmpty {
                    out.old = blob(spec: "HEAD:\(oldPath)", repo: repoPath, into: &out)
                }
                out.new = worktree(repo: repoPath, path: path, into: &out)
            }
            return out
        }.value
    }

    private static func blob(spec: String, repo: String, into out: inout ResolvedDiff) -> String {
        let run = runGit(["show", spec], repo: repo)
        guard run.status == 0 else { return "" }
        return decode(run.data, into: &out)
    }

    private static func worktree(repo: String, path: String, into out: inout ResolvedDiff) -> String {
        let url = URL(fileURLWithPath: repo, isDirectory: true).appendingPathComponent(path)
        do {
            let data = try Data(contentsOf: url)
            if data.count > maxBytes { out.error = "File is too large to diff"; return "" }
            return decode(data, into: &out)
        } catch {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        }
    }

    private static func decode(_ data: Data, into out: inout ResolvedDiff) -> String {
        if data.count > maxBytes { out.error = "File is too large to diff"; return "" }
        if data.contains(0) { out.binary = true; return "" }
        guard let text = String(data: data, encoding: .utf8) else { out.binary = true; return "" }
        return text
    }

    /// Drains stdout and stderr concurrently so a chatty stderr cannot deadlock a
    /// large stdout read.
    private static func runGit(_ args: [String], repo: String) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repo, isDirectory: true)
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
        do { try process.run() } catch { return (-1, Data()) }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, box.value)
    }

    private final class OutputBox: @unchecked Sendable { var value = Data() }
}

// MARK: - View

private enum DiffStyle: String, CaseIterable, Identifiable {
    case unified, split
    var id: String { rawValue }
    var label: String { self == .unified ? "Unified" : "Split" }
}

/// The host's default diff view: a native, high-performance diff renderer any plugin
/// opens with `workspace.tab.create.v1` and diff content. It paints only the changed
/// hunks (plus context) — a two-line edit in a 10k-line file draws a handful of rows.
/// No WebView. Unified scrolls a long line horizontally; split gives each side a fixed
/// half-width column and truncates, so a long line on one side never balloons the other.
struct DiffSlotView: View {
    private let request: DiffRequest
    @State private var model: DiffContentModel
    @State private var style: DiffStyle

    init(request: DiffRequest, startSplit: Bool = false) {
        self.request = request
        _model = State(initialValue: DiffContentModel(request: request))
        _style = State(initialValue: startSplit ? .split : .unified)
    }

    private static let addedFG = Color(nsColor: NSColor(hex: 0x61C28B))
    private static let removedFG = Color(nsColor: NSColor(hex: 0xED6A5E))
    private static let addedBG = Color(nsColor: NSColor(hex: 0x61C28B)).opacity(0.10)
    private static let removedBG = Color(nsColor: NSColor(hex: 0xED6A5E)).opacity(0.10)
    private static let rowFont = TenonTheme.utilityFont(size: 11)
    private static let rowHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TenonTheme.panel)
        .onAppear { model.reload() }
        .onChange(of: request) { _, newRequest in model.reload(newRequest) }
    }

    // MARK: control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            Text(model.fileName)
                .font(TenonTheme.utilityFont(size: 10, weight: .semibold))
                .foregroundStyle(TenonTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if !model.isLoading, model.hasChanges, !model.isBinary {
                Text("+\(model.stat.added)").foregroundStyle(Self.addedFG)
                Text("−\(model.stat.removed)").foregroundStyle(Self.removedFG)
            }
            Spacer(minLength: 8)
            Picker("", selection: $style) {
                ForEach(DiffStyle.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .labelsHidden()
        }
        .font(TenonTheme.utilityFont(size: 9))
        .foregroundStyle(TenonTheme.muted)
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(TenonTheme.chromeRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(TenonTheme.line).frame(height: 1) }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            DiffSkeletonView()
        } else if model.isBinary {
            placeholder(icon: "doc.badge.gearshape", text: "Binary file — no text diff")
        } else if let error = model.error {
            placeholder(icon: "exclamationmark.triangle", text: error)
        } else if !model.hasChanges {
            placeholder(icon: "checkmark.circle", text: "No changes")
        } else {
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) { rowsBody }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    /// The gutter is exactly wide enough for the largest line number, so a small
    /// file's numbers sit close to the code instead of behind a fixed-width margin.
    private var gutterWidth: CGFloat {
        CGFloat(String(model.maxLineNumber).count) * 8 + 6
    }

    @ViewBuilder
    private var rowsBody: some View {
        if style == .unified {
            ForEach(Array(model.hunks.enumerated()), id: \.offset) { _, hunk in
                hunkHeader(hunk)
                unifiedRows(hunk)
            }
        } else {
            splitGrid
        }
    }

    /// Split view. One `Grid` so each side gets its OWN column width — the widest
    /// line on that side — instead of forcing them equal. A long added line makes
    /// only the new column wide; the old column stays as narrow as its content, and
    /// the whole grid scrolls horizontally so nothing is truncated.
    private var splitGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(model.hunks.enumerated()), id: \.offset) { _, hunk in
                GridRow { hunkHeader(hunk).gridCellColumns(3) }
                ForEach(Array(pair(hunk.lines).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        splitCell(row.left, side: .left)
                        // Fixed height too — a height-flexible divider would make the
                        // whole GridRow flexible and let the grid stretch the rows apart.
                        Rectangle().fill(TenonTheme.line).frame(width: 1, height: Self.rowHeight)
                        splitCell(row.right, side: .right)
                    }
                }
            }
        }
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        Text(hunk.header)
            .font(Self.rowFont)
            .foregroundStyle(TenonTheme.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.amber.opacity(0.06))
    }

    // MARK: unified

    private func unifiedRows(_ hunk: DiffHunk) -> some View {
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
            HStack(spacing: 0) {
                // One line-number column (new side, or old for a deletion) — the sign
                // already tells the side, so a second empty column isn't needed.
                Text((line.newNumber ?? line.oldNumber).map(String.init) ?? "")
                    .foregroundStyle(TenonTheme.muted.opacity(0.55))
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                Text(sign(line.kind))
                    .frame(width: 9, alignment: .center)
                    .foregroundStyle(fg(line.kind))
                    .padding(.trailing, 6)
                Text(line.text.isEmpty ? " " : line.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(line.kind == .context ? TenonTheme.text : fg(line.kind))
                    .textSelection(.enabled)
                    .padding(.trailing, 14)
            }
            .font(Self.rowFont)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(bg(line.kind))
        }
    }

    // MARK: split

    private enum SplitSide { case left, right }

    private func splitCell(_ line: DiffLine?, side: SplitSide) -> some View {
        HStack(spacing: 0) {
            if let line {
                gutter(side == .left ? line.oldNumber : line.newNumber)
                Text(line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(line.kind == .context ? TenonTheme.text : fg(line.kind))
                    .textSelection(.enabled)
                    .padding(.trailing, 12)
            } else {
                Color.clear.frame(width: 0)
            }
        }
        .font(Self.rowFont)
        // `maxWidth: .infinity` makes the cell fill its Grid column (so the row tint
        // spans it); the text is `fixedSize`, so the column is exactly as wide as the
        // widest line on THIS side — independent of the other side. Height is fixed
        // (min == max), or the flexible 1px divider would stretch the rows apart.
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(line.map { bg($0.kind) } ?? TenonTheme.ink.opacity(0.22))
    }

    /// Pairs a hunk's lines for side-by-side view: a run of removals aligns with
    /// the run of additions that follows it; context sits on both sides.
    private func pair(_ lines: [DiffLine]) -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(DiffLine?, DiffLine?)] = []
        var i = 0
        while i < lines.count {
            switch lines[i].kind {
            case .context:
                rows.append((lines[i], lines[i]))
                i += 1
            case .removed:
                var removed: [DiffLine] = []
                while i < lines.count, lines[i].kind == .removed { removed.append(lines[i]); i += 1 }
                var added: [DiffLine] = []
                while i < lines.count, lines[i].kind == .added { added.append(lines[i]); i += 1 }
                for j in 0..<max(removed.count, added.count) {
                    rows.append((j < removed.count ? removed[j] : nil, j < added.count ? added[j] : nil))
                }
            case .added:
                var added: [DiffLine] = []
                while i < lines.count, lines[i].kind == .added { added.append(lines[i]); i += 1 }
                for line in added { rows.append((nil, line)) }
            }
        }
        return rows
    }

    // MARK: pieces

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(Self.rowFont)
            .foregroundStyle(TenonTheme.muted.opacity(0.55))
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.horizontal, 6)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TenonTheme.muted.opacity(0.6))
            Text(text)
                .font(TenonTheme.utilityFont(size: 10))
                .foregroundStyle(TenonTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sign(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private func fg(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return Self.addedFG
        case .removed: return Self.removedFG
        case .context: return TenonTheme.muted
        }
    }

    private func bg(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return Self.addedBG
        case .removed: return Self.removedBG
        case .context: return .clear
        }
    }
}

/// Code-shaped gray bars while a diff resolves, so opening one never flashes empty.
private struct DiffSkeletonView: View {
    private static let widths: [CGFloat] = [0.42, 0.62, 0.30, 0.55, 0.38, 0.50, 0.24, 0.46]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<20, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(TenonTheme.muted.opacity(0.08))
                    .frame(width: 360 * Self.widths[index % Self.widths.count], height: 9)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
