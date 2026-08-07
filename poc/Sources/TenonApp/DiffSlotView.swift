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

private struct DiffProjection: Sendable {
    let hunks: [DiffHunk]
    let stat: (added: Int, removed: Int)
    let maxLineNumber: Int
    let unifiedRows: [DiffRow]
    let splitRows: [DiffRow]
}

/// Owns a diff pane's two sides. For an `.inline` request the text is already in
/// hand; for a `.git` request it resolves both blobs off-main (a generation guard
/// drops a stale load if the pane is asked to reload before the last finished). The
/// line diff itself is the pure `LineDiff` engine's job, computed once per content
/// change and cached — not per render, and the same for the `DiffRows` flattening
/// and the column measurements the lazy renderer needs.
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

    /// The flat row lists the lazy container scrolls, one per style.
    private(set) var unifiedRows: [DiffRow] = []
    private(set) var splitRows: [DiffRow] = []

    /// How wide the text column of each style has to be. A lazy container measures
    /// only the rows it builds, so it cannot discover that the widest line is a
    /// thousand rows below the viewport — core names the candidates and these are
    /// them, measured once with the row font.
    private(set) var unifiedTextWidth: CGFloat = 0
    private(set) var leftTextWidth: CGFloat = 0
    private(set) var rightTextWidth: CGFloat = 0

    private(set) var request: DiffRequest
    private var generation = 0
    private var task: Task<Void, Never>?

    var hasChanges: Bool { oldText != newText }

    init(request: DiffRequest) {
        self.request = request
    }

    func reload(_ newRequest: DiffRequest? = nil) {
        if let newRequest { request = newRequest }
        generation += 1
        let gen = generation
        task?.cancel()
        error = nil
        isLoading = true
        let pendingRequest = request
        task = Task { [weak self] in
            let resolved: ResolvedDiff
            switch pendingRequest.source {
            case .inline(let old, let new):
                resolved = ResolvedDiff(old: old, new: new)
            case .git(let repoPath, let path, let staged, let untracked, let origPath):
                resolved = await DiffGitLoader.load(
                    repoPath: repoPath, path: path,
                    staged: staged, untracked: untracked, origPath: origPath
                )
            }
            let projection = await Self.project(resolved)
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.apply(resolved, projection: projection)
        }
    }

    @concurrent
    private static func project(_ resolved: ResolvedDiff) async -> Result<DiffProjection, LineDiffError> {
        guard resolved.error == nil, !resolved.binary else {
            return .success(DiffProjection(
                hunks: [], stat: (0, 0), maxLineNumber: 1,
                unifiedRows: [], splitRows: []
            ))
        }
        do {
            let hunks = try LineDiff.boundedHunks(
                old: resolved.old,
                new: resolved.new,
                context: 3
            )
            return .success(DiffProjection(
                hunks: hunks,
                stat: LineDiff.stat(hunks),
                maxLineNumber: DiffRows.maxLineNumber(hunks),
                unifiedRows: DiffRows.unified(hunks),
                splitRows: DiffRows.split(hunks)
            ))
        } catch {
            return .failure(.tooComplex)
        }
    }

    private func apply(
        _ resolved: ResolvedDiff,
        projection: Result<DiffProjection, LineDiffError>
    ) {
        oldText = resolved.old
        newText = resolved.new
        error = resolved.error
        isBinary = resolved.binary
        isLoading = false
        guard case let .success(value) = projection else {
            error = "Diff is too complex to render safely"
            hunks = []
            unifiedRows = []
            splitRows = []
            return
        }
        hunks = value.hunks
        stat = value.stat
        maxLineNumber = value.maxLineNumber
        unifiedRows = value.unifiedRows
        splitRows = value.splitRows
        unifiedTextWidth = Self.measure(DiffRows.widestTexts(unifiedRows, column: .unified))
        leftTextWidth = Self.measure(DiffRows.widestTexts(splitRows, column: .left))
        rightTextWidth = Self.measure(DiffRows.widestTexts(splitRows, column: .right))
    }

    /// The row font, as AppKit sees it — the same monospaced face the SwiftUI rows
    /// draw with, so a measurement here is what the text finally occupies.
    private static let rowNSFont = TenonTheme.utilityNSFont(size: 11)

    private static func measure(_ texts: [String]) -> CGFloat {
        texts.reduce(CGFloat.zero) { widest, text in
            Swift.max(widest, (text as NSString).size(withAttributes: [.font: rowNSFont]).width)
        }
        .rounded(.up)
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
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
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
            while let chunk = try? stdout.fileHandleForReading.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {
                if !box.append(chunk, limit: maxBytes) {
                    process.terminate()
                    break
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? stderr.fileHandleForReading.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {}
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, box.snapshot)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        var snapshot: Data { lock.withLock { value } }

        func append(_ chunk: Data, limit: Int) -> Bool {
            lock.withLock {
                guard value.count + chunk.count <= limit else {
                    value = Data(repeating: 0, count: limit + 1)
                    return false
                }
                value.append(chunk)
                return true
            }
        }
    }
}

// MARK: - View

private enum DiffStyle: String, CaseIterable, Identifiable {
    case unified, split
    var id: String { rawValue }
    var label: String { self == .unified ? "Unified" : "Split" }
}

/// What the diff pane contributes to the ONE chrome header the card draws.
///
/// Pure, and deliberately outside the view: every rule a header has is a decision about the
/// pane's own state, and once the items are chosen the drawing has no decisions left in it.
/// Keeping the decision here is what lets it be swept headlessly, which is the fitness test
/// `docs/tdd.md` sets for any rule that would otherwise only be checkable by looking at a
/// window.
///
/// The style is taken as `isSplit` rather than as a `DiffStyle`, because `DiffStyle` is this
/// pane's private state vocabulary and stays private — the same two-valued shape
/// `DiffSlotView.init(startSplit:)` has always spoken. Both ends of the picker are still minted
/// from `DiffStyle` itself, inside this function, so the values the router resolves cannot
/// drift from the cases the view stores.
enum DiffPaneHeader {
    static func header(
        isLoading: Bool,
        hasChanges: Bool,
        isBinary: Bool,
        added: Int,
        removed: Int,
        isSplit: Bool
    ) -> PaneHeader {
        // Counts exist only once the diff has resolved to text that actually differs. A
        // loading pane has not counted yet, a binary file has nothing countable, and an
        // unchanged file's "+0 −0" only restates the "No changes" placeholder already filling
        // the body.
        let stats: [PaneHeaderItem] = !isLoading && hasChanges && !isBinary
            ? [
                .badge(id: "added", text: "+\(added)", tint: .green, tooltip: nil),
                .badge(id: "removed", text: "−\(removed)", tint: .red, tooltip: nil),
            ]
            : []

        return PaneHeader(
            leading: stats,
            // Never conditional: a diff can be read either way at any moment, including while
            // it loads, so hiding the picker would make the pane briefly un-switchable for a
            // reason no reader could see.
            trailing: [
                .segmented(
                    id: PaneHeaderCommand.diffStyle.rawValue,
                    segments: DiffStyle.allCases.compactMap {
                        PaneHeaderSegment(value: $0.rawValue, label: $0.label)
                    },
                    selection: (isSplit ? DiffStyle.split : .unified).rawValue,
                    isEnabled: true,
                    accessibilityID: nil
                ),
            ]
        )
    }
}

/// The host's default diff view: a native, high-performance diff renderer any plugin
/// opens with `workspace.tab.create.v1` and diff content. No WebView.
///
/// It paints only the changed hunks (plus context) — a two-line edit in a 10k-line
/// file draws a handful of rows — and, of those, only the rows on screen: the pure
/// `DiffRows` projection flattens (hunks × lines) into one list keyed by line number,
/// which a `LazyVStack` scrolls. A diff of any size costs a viewport, not a file.
///
/// The width that laziness gives up is bought back from the content: `DiffRows` names
/// the widest candidate lines per column and the model measures those, so the scroll
/// extent is right on the first frame instead of growing as rows are built. Unified
/// scrolls a long line horizontally; split gives each side its own column, so a long
/// line on one side never widens the other.
struct DiffSlotView: View {
    private let request: DiffRequest
    /// Which pane this is, so its header contribution can be told apart from every other
    /// pane's in the one store the canvas reads.
    private let slotID: UUID
    /// Where the header goes UP. The already-projected value comes back DOWN through
    /// `SpatialSlotCardView.configure`; this is the other half of that loop.
    private let headerStore: PaneHeaderStore
    @State private var model: DiffContentModel
    /// Unmoved: the pane still owns which style it is showing. Putting the picker in the
    /// chrome moved pixels, not ownership — the store carries a value up and a typed command
    /// back down, and this stays the only place the answer lives.
    @State private var style: DiffStyle

    init(
        request: DiffRequest,
        slotID: UUID,
        headerStore: PaneHeaderStore,
        startSplit: Bool = false
    ) {
        self.request = request
        self.slotID = slotID
        self.headerStore = headerStore
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
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TenonTheme.panel)
            .task(id: request) { model.reload(request) }
            // The picker in the chrome reports an item id; the router turns it back into a
            // typed command and this is where the pane acts on it. The binding is captured
            // rather than `self`, because the handler outlives the body evaluation that
            // registered it.
            .onAppear {
                let selected = $style
                headerStore.onCommand(for: slotID) { command, value in
                    guard command == .diffStyle,
                          let next = value.flatMap(DiffStyle.init(rawValue:))
                    else { return }
                    selected.wrappedValue = next
                }
            }
            // Published from `.onChange`, never from `body`: writing to an observable during
            // a view update is what makes SwiftUI re-enter, and the store's equality guard is
            // a backstop for that mistake rather than a licence to make it. `initial: true`
            // is the pane's first publish, so a diff that never changes still shows its
            // picker.
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
        DiffPaneHeader.header(
            isLoading: model.isLoading,
            hasChanges: model.hasChanges,
            isBinary: model.isBinary,
            added: model.stat.added,
            removed: model.stat.removed,
            isSplit: style == .split
        )
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Keyed on the row's own id — line numbers, not list position.
                        // A lazy container recycles rows, and an index key would give
                        // every row below a change a new identity on each reload.
                        ForEach(rows) { row in
                            rowBody(row)
                        }
                    }
                    .frame(width: Swift.max(contentWidth, geo.size.width), alignment: .topLeading)
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// The flat row list for the selected style, flattened once by the model.
    private var rows: [DiffRow] {
        style == .unified ? model.unifiedRows : model.splitRows
    }

    /// The gutter is exactly wide enough for the largest line number, so a small
    /// file's numbers sit close to the code instead of behind a fixed-width margin.
    private var gutterWidth: CGFloat {
        CGFloat(String(model.maxLineNumber).count) * 8 + 6
    }

    // Row padding, named because the row builders and the content width both depend
    // on it: a literal changed in one place and not the other silently clips a line
    // or leaves dead space to scroll through.
    private static let unifiedGutterPad: CGFloat = 8
    private static let signColumn: CGFloat = 9
    private static let signGap: CGFloat = 6
    private static let unifiedTextTrail: CGFloat = 14
    private static let splitGutterPad: CGFloat = 6
    private static let splitTextTrail: CGFloat = 12
    private static let dividerWidth: CGFloat = 1

    private static let unifiedChrome =
        unifiedGutterPad * 2 + signColumn + signGap + unifiedTextTrail
    private static let splitCellChrome = splitGutterPad * 2 + splitTextTrail

    private var leftCellWidth: CGFloat { gutterWidth + Self.splitCellChrome + model.leftTextWidth }
    private var rightCellWidth: CGFloat { gutterWidth + Self.splitCellChrome + model.rightTextWidth }

    /// How wide the scrollable content is: the widest row, from the measured column
    /// widths. A lazy container has never seen the rows it hasn't built, so the
    /// scroll extent comes from the content rather than from what is on screen.
    private var contentWidth: CGFloat {
        style == .unified
            ? gutterWidth + Self.unifiedChrome + model.unifiedTextWidth
            : leftCellWidth + Self.dividerWidth + rightCellWidth
    }

    @ViewBuilder
    private func rowBody(_ row: DiffRow) -> some View {
        switch row.content {
        case .header(let header):
            hunkHeader(header)
        case .line(let line):
            unifiedRow(line)
        case .pair(let left, let right):
            splitRow(left: left, right: right)
        }
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(Self.rowFont)
            .foregroundStyle(TenonTheme.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.amber.opacity(0.06))
    }

    // MARK: unified

    private func unifiedRow(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // One line-number column (new side, or old for a deletion) — the sign
            // already tells the side, so a second empty column isn't needed.
            Text((line.newNumber ?? line.oldNumber).map(String.init) ?? "")
                .foregroundStyle(TenonTheme.muted.opacity(0.55))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.leading, Self.unifiedGutterPad)
                .padding(.trailing, Self.unifiedGutterPad)
            Text(sign(line.kind))
                .frame(width: Self.signColumn, alignment: .center)
                .foregroundStyle(fg(line.kind))
                .padding(.trailing, Self.signGap)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(line.kind == .context ? TenonTheme.text : fg(line.kind))
                .textSelection(.enabled)
                .padding(.trailing, Self.unifiedTextTrail)
        }
        .font(Self.rowFont)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(bg(line.kind))
    }

    // MARK: split

    private enum SplitSide { case left, right }

    /// One side-by-side row. Each side gets its OWN measured column width — the
    /// widest line on that side — instead of forcing them equal: a long added line
    /// widens only the new column, the old column stays as narrow as its content,
    /// and the pane scrolls horizontally so nothing is truncated.
    private func splitRow(left: DiffLine?, right: DiffLine?) -> some View {
        HStack(spacing: 0) {
            splitCell(left, side: .left, width: leftCellWidth)
            // Fixed height too — a height-flexible divider would make the whole row
            // flexible and let the stack pull the rows apart.
            Rectangle().fill(TenonTheme.line)
                .frame(width: Self.dividerWidth, height: Self.rowHeight)
            splitCell(right, side: .right, width: rightCellWidth)
        }
        .frame(height: Self.rowHeight)
    }

    private func splitCell(_ line: DiffLine?, side: SplitSide, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let line {
                gutter(side == .left ? line.oldNumber : line.newNumber)
                Text(line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(line.kind == .context ? TenonTheme.text : fg(line.kind))
                    .textSelection(.enabled)
                    .padding(.trailing, Self.splitTextTrail)
            } else {
                Color.clear.frame(width: 0)
            }
        }
        .font(Self.rowFont)
        // Explicit width so the two columns line up across rows the container has
        // never built together. Height is fixed (min == max), or the flexible 1px
        // divider would stretch the rows apart.
        .frame(width: width, alignment: .leading)
        .frame(minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(line.map { bg($0.kind) } ?? TenonTheme.ink.opacity(0.22))
    }

    // MARK: pieces

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(Self.rowFont)
            .foregroundStyle(TenonTheme.muted.opacity(0.55))
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.horizontal, Self.splitGutterPad)
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
