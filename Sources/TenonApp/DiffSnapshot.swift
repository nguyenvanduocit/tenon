// @domain: editor-and-diff
import AppKit
import SwiftUI
import TenonCore

/// Dev-only offscreen snapshots of the native diff/changes views, so they can be seen
/// — and timed — on a headless machine (no display / `screencapture`). Gated by env vars:
///
///     TENON_DIFF_SNAPSHOT=/path/out.png swift run tenon
///     TENON_CHANGES_SNAPSHOT=/path/out.png swift run tenon
///
/// The diff's two sides default to a small built-in sample; point
/// `TENON_DIFF_SNAPSHOT_OLD` / `TENON_DIFF_SNAPSHOT_NEW` at files to render a real one.
/// That is how a large diff gets measured here: the render reports its first layout pass
/// and its capture to stderr, and the first layout pass is exactly where a non-lazy
/// container would build every row.
///
/// Renders the real view through an offscreen `NSHostingView` + `cacheDisplay`, writes
/// the PNG, and exits before any window opens. Not part of normal operation.
enum DiffSnapshot {
    @MainActor
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["TENON_DIFF_SNAPSHOT"], !path.isEmpty { renderDiff(to: path) }
        if let path = env["TENON_CHANGES_SNAPSHOT"], !path.isEmpty { renderChanges(to: path) }
    }

    @MainActor
    private static func renderDiff(to path: String) {
        let old = """
        func resolveRepo(_ setting: String) -> String? {
            if setting.isEmpty { return nil }
            return setting
        }

        func status(in repo: String) -> [Entry] {
            let out = run(["status", "--porcelain"], in: repo)
            return out.split(separator: "\\n").map { Entry(line: String($0)) }
        }
        """
        let new = """
        func resolveRepo(_ setting: String) -> String? {
            let trimmed = setting.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "~", FileManager.default.fileExists(atPath: trimmed), isDirectory(trimmed) else { return nil }
            return trimmed
        }

        func status(in repo: String) -> [Entry] {
            let out = run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: repo)
            return out.split(separator: "\\0", omittingEmptySubsequences: true).compactMap { Entry(record: String($0)) }
        }
        """
        let env = ProcessInfo.processInfo.environment
        let oldText = env["TENON_DIFF_SNAPSHOT_OLD"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? old
        let newText = env["TENON_DIFF_SNAPSHOT_NEW"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? new
        let request = DiffRequest(
            source: .inline(oldText: oldText, newText: newText),
            fileName: "GitStatus.swift",
            title: "GitStatus.swift"
        )
        let slot = WorkspaceSlot(
            id: UUID(),
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .diff(request)
        )
        let headers = PaneHeaderStore()
        write(
            DiffSlotView(
                request: request,
                slotID: slot.id,
                headerStore: headers,
                startSplit: env["TENON_DIFF_SNAPSHOT_SPLIT"] != "0"
            ),
            slot: slot,
            title: request.title,
            headerStore: headers,
            size: CGSize(width: 900, height: 560),
            to: path
        )
    }

    @MainActor
    private static func renderChanges(to path: String) {
        let staged = [
            ChangeEntry(path: "Sources/TenonCore/LineDiff.swift", badge: "A", staged: true, untracked: false),
            ChangeEntry(path: "Sources/TenonApp/DiffSlotView.swift", badge: "M", staged: true, untracked: false),
        ]
        let changed = [
            ChangeEntry(path: "plugins/git/main.js", badge: "M", staged: false, untracked: false),
            ChangeEntry(path: "Sources/TenonCore/PluginRuntime.swift", badge: "M", staged: false, untracked: false),
            ChangeEntry(path: "Sources/TenonApp/ChangesPanelView.swift", badge: "?", staged: false, untracked: true),
            ChangeEntry(path: "docs/legacy-changes-view.md", badge: "D", staged: false, untracked: false),
        ]
        let model = ChangesModel(previewBranch: "main", staged: staged, changed: changed)
        let slot = WorkspaceSlot(
            id: UUID(),
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .changes
        )
        let headers = PaneHeaderStore()
        write(
            ChangesPanelView(previewModel: model, slotID: slot.id, headerStore: headers),
            slot: slot,
            title: "Changes — working tree",
            headerStore: headers,
            size: CGSize(width: 460, height: 620),
            to: path
        )
    }

    @MainActor
    private static func write(
        _ view: some View,
        slot: WorkspaceSlot,
        title: String,
        headerStore: PaneHeaderStore,
        size: CGSize,
        to path: String
    ) {
        PaneViewSnapshotWriter.write(
            view,
            slot: slot,
            title: title,
            headerStore: headerStore,
            size: size,
            to: path
        )
    }
}

/// The pane chrome, mounted a second time so an offscreen render still shows a pane's controls.
///
/// Every control a migrated pane used to draw in its own body now lives in the chrome header, so
/// a snapshot of the body alone would no longer show what the pane shows. This stacks the SAME
/// `PaneHeaderBar` — fed by the same pure `PaneHeaderProjection`, placed by the same
/// `PaneHeaderLayout.solve` — over the content. It is the shape `PluginNodeView` already has
/// between a pane and the modal overlay: one renderer, two mounts, and no second answer to
/// "what does a header look like" that could drift from the first.
///
/// One bar here, against the card's two. The card splits its run across two AppKit hosts so the
/// strip between them stays one contiguous pane-drag rectangle; a still image has nothing to
/// drag. Placements are card-space rects either way, so a single bar anchored at the strip's own
/// origin puts every control exactly where the card puts it.
///
/// The glyph, the title and the ✕ are drawn as static SwiftUI from the solver's rects rather
/// than from literals, so a snapshot is wrong in exactly the cases the card is wrong in.
/// The card's own close-control geometry (`SpatialSlotCardView.layout()`), restated because the
/// ✕ is host chrome the solver deliberately does not place — it only reserves room for it, so
/// that no accessory can ever sit under it.
///
/// A restatement documented as one is still a second copy, and a second copy nobody checks
/// drifts. These two numbers are therefore not private: `testTheSnapshotsCloseControlMatches`
/// `TheCardsOwnGeometry` reads the card's `layout()` and fails when they stop agreeing, so a
/// change to the ✕ that forgets the snapshot is caught by the suite instead of by whoever
/// next looks at a PNG. Hoisting them to one owner would be better still, and is not done
/// here only because the card is the owner and this change does not touch that file.
enum PaneChromeMetrics {
    static let closeWidth: CGFloat = 23
    static let closeInset: CGFloat = 27
}

struct PaneChromePreview<Content: View>: View {
    let slot: WorkspaceSlot
    let title: String
    var headerStore: PaneHeaderStore
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                chrome(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: TenonTheme.slotHeaderHeight)
            content
        }
        .background(TenonTheme.ink)
    }

    private func chrome(width: CGFloat, height: CGFloat) -> some View {
        let solution = PaneHeaderLayout.solve(
            header: PaneHeaderProjection.header(
                for: slot,
                published: headerStore.headers[slot.id],
                // The two snapshot subjects are built-in panes, so no plugin section can be
                // this slot's; passing the live list would be passing an array that cannot
                // match.
                pluginViewSections: []
            ),
            // No attention state offscreen: a snapshot renders a pane nobody is watching.
            showsDot: false,
            titleIdealWidth: titleIdealWidth,
            glyphSize: CGSize(width: 19, height: 12),
            titleHeight: 13,
            bounds: CGSize(width: width, height: height),
            headerHeight: height,
            metrics: .live
        )
        return ZStack(alignment: .topLeading) {
            Text(SlotPresentation.glyph(for: slot.content))
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
                .frame(width: solution.glyphRect.width, height: height, alignment: .leading)
                .offset(x: solution.glyphRect.minX)

            // `.zero` is the solver saying a flexible field took the gap, or that what is
            // left of it is too narrow to read — either way the name is not drawn.
            if solution.titleRect != .zero {
                Text(title)
                    .font(TenonTheme.interfaceFont(size: 10, weight: .medium))
                    .foregroundStyle(TenonTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: solution.titleRect.width, height: height, alignment: .leading)
                    .offset(x: solution.titleRect.minX)
            }

            PaneHeaderBar(
                placements: solution.placements,
                origin: .zero,
                isActive: true,
                perform: { _ in }
            )

            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TenonTheme.muted)
                .frame(width: PaneChromeMetrics.closeWidth, height: height)
                .offset(x: max(width - PaneChromeMetrics.closeInset, 0))
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(TenonTheme.chromeRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TenonTheme.line.opacity(0.72)).frame(height: 1)
        }
    }

    /// The width the pane's name would like, measured with the card's title font — the same
    /// number `title.intrinsicContentSize.width` gives the card, so the solver decides whether
    /// the name survives on the same evidence in both mounts.
    private var titleIdealWidth: CGFloat {
        (title as NSString)
            .size(withAttributes: [
                .font: TenonTheme.interfaceNSFont(size: 10, weight: .medium),
            ])
            .width
            .rounded(.up)
    }
}
