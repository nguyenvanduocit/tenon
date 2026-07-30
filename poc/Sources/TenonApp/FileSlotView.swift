import AppKit
import CoreGraphics
import Observation
import SwiftUI
import TenonCore

/// One file open as a pane (`SlotContent.file`) — a real editor: STTextView with a
/// line-number gutter, tree-sitter colours, the system find bar, and ⌘S to save.
///
/// Host-native, like the diff view: the file explorer is a plugin, but what it opens
/// into belongs to the host, so no plugin ever handles a document type (invariant 2).
struct FileSlotView: View {
    let path: String
    /// The pane this view fills. Together with `path` it keys the per-slot editor
    /// state, so scroll/selection/unsaved edits survive the view being destroyed on
    /// a pane switch — and never leak into a pane showing a different file.
    let slotID: UUID
    let editorStates: EditorPaneStateStore
    @State private var model = FileDocumentModel(
        watchFiles: FileDocumentModel.liveWatchFiles
    )

    var body: some View {
        // No header of its own: the pane chrome already names the file. Unsaved and
        // error state float over the top-right corner instead, where they cost no
        // vertical space and are absent whenever there is nothing to say.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.panel)
            .overlay(alignment: .topTrailing) { statusBadge }
            .task(id: path) {
                let slotID = slotID
                model.onBufferStateChange = { [weak model, weak editorStates] in
                    guard let model, let editorStates,
                          let currentPath = model.path
                    else {
                        return
                    }
                    editorStates.recordBuffer(
                        for: slotID,
                        path: currentPath,
                        pendingText: model.isDirty ? model.pendingSnapshot : nil,
                        savedTextHash: model.savedTextHash,
                        conflicted: model.hasDiskConflict
                    )
                }
                await model.load(
                    path,
                    restoring: editorStates.state(for: slotID, path: path)
                )
            }
            // ⌘S lives on a hidden button rather than a menu command so it belongs to
            // the pane that owns the file, not to the window.
            .background {
                Button("") {
                    Task {
                        await model.save()
                    }
                }
                    .keyboardShortcut("s", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let error = model.error {
            Text(error)
                .font(TenonTheme.interfaceFont(size: 9))
                .foregroundStyle(Color.red.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(TenonTheme.chromeRaised, in: Capsule())
                .padding(8)
        } else if model.hasDiskConflict {
            // The file moved on disk under unsaved edits. The buffer stays — the
            // user's work outranks the disk — and this says so out loud instead of
            // letting ⌘S overwrite in silence.
            Text("Changed on disk — ⌘S keeps your version")
                .font(TenonTheme.interfaceFont(size: 9))
                .foregroundStyle(TenonTheme.amber)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(TenonTheme.chromeRaised, in: Capsule())
                .padding(8)
                .help(
                    "Another program edited this file while you had unsaved "
                        + "changes. Saving keeps what you see here."
                )
        } else if model.isDirty {
            Circle()
                .fill(TenonTheme.amber)
                .frame(width: 6, height: 6)
                .padding(9)
                .help("Unsaved changes — ⌘S to save")
        }
    }

    @ViewBuilder
    private var content: some View {
        // `path` changes a render before the keyed task starts loading it, so for one
        // frame the model still holds the previous file. Rendering that frame would hand
        // the editor OLD text under the NEW path — and since the editor only re-reads its
        // text when the path changes, the stale content would then stick. Wait for the model.
        if model.path != path {
            Color.clear
        } else {
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        switch model.state {
        case .loading:
            Color.clear
        case .text(let text):
            SourceEditorView(
                text: text,
                path: path,
                revision: model.revision,
                font: TenonTheme.utilityNSFont(size: 12),
                wrapLines: false,
                onChange: { model.edited($0) },
                slotID: slotID,
                editorStates: editorStates
            )
            // A different file is a different document: rebuild the text view rather
            // than mutating one that holds another file's undo stack and selection.
            .id(path)
        case .image(let image):
            ScrollView([.vertical, .horizontal]) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            VStack(spacing: 7) {
                Image(systemName: "doc.questionmark")
                    .font(.title2)
                Text(reason)
                    .font(TenonTheme.interfaceFont(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(TenonTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// `PathWatcher` serialises start/stop and its FSEvents callback through its own
/// queue, so calling `stop()` from the watch token's deinit on any thread is safe;
/// this box states that to the compiler.
private struct UncheckedSendableWatcher: @unchecked Sendable {
    let watcher: PathWatcher
}

/// Reads a file, classifies it (text / image / can't show this), and owns the edit +
/// save cycle. A binary blob rendered as text is worse than saying so, which is why the
/// classification is explicit rather than a lossy decode.
@MainActor
@Observable
final class FileDocumentModel {
    enum State {
        case loading
        case text(String)
        case image(CGImage)
        case unavailable(String)
    }

    /// Builds the watch behind `reloadAfterExternalChange`. `nil` means the model does
    /// not watch — the default, so tests that only exercise load/save never touch
    /// FSEvents; the shell passes `liveWatchFiles` explicitly.
    typealias WatchFiles = @MainActor (
        _ path: String,
        _ onChange: @escaping @Sendable () -> Void
    ) -> EditorFileWatchToken?

    private(set) var state: State = .loading
    private(set) var isDirty = false
    private(set) var error: String?
    /// The file `state` actually holds. The view compares this against the path it was
    /// handed, so it never paints one file's text under another's name.
    private(set) var path: String?
    /// The file changed on disk while this pane held unsaved edits. The buffer stays —
    /// the user's work outranks the disk — and ⌘S resolves the conflict their way.
    private(set) var hasDiskConflict = false
    /// Bumped when the loaded text changed for the SAME path (an external reload), so
    /// the editor view knows to re-read `state`'s text without a path change.
    private(set) var revision = 0
    /// What is on disk as far as we know, so a save is a no-op when nothing changed.
    private var saved = ""
    private var pending = ""

    /// The live unsaved buffer and its disk baseline, exposed so the owning view can
    /// mirror them into the per-slot `EditorPaneStateStore` on every publication.
    var pendingSnapshot: String { pending }
    var savedTextHash: Int { saved.hashValue }

    /// Fires whenever the unsaved-buffer state changes (edit, save, restore, external
    /// reload/conflict) — the owning view's hook for persisting it per slot.
    @ObservationIgnored
    var onBufferStateChange: (() -> Void)?

    @ObservationIgnored
    private let io: FileDocumentIO

    @ObservationIgnored
    private let watchFiles: WatchFiles?

    @ObservationIgnored
    private var watchToken: EditorFileWatchToken?

    /// Per-slot state handed to `load`, applied only when the read lands for the
    /// path it was captured for.
    @ObservationIgnored
    private var pendingRestore: EditorPaneState?

    @ObservationIgnored
    private var documentGeneration = UUID()

    /// Bigger than this and the editor would be holding a log file, not source. TextKit
    /// copes, but nothing good comes of opening a 200 MB file in a pane.
    private static let byteLimit = 8_000_000

    init(io: FileDocumentIO = .live, watchFiles: WatchFiles? = nil) {
        self.io = io
        self.watchFiles = watchFiles
    }

    /// Re-reads the file after its watcher reported a change and applies
    /// `ExternalFileChange.action` to decide what happens to the pane.
    func reloadAfterExternalChange() async {
        guard let path, case .text = state else { return }
        let generation = documentGeneration
        let request = FileDocumentReadRequest(
            path: path,
            byteLimit: Self.byteLimit
        )
        guard let result = try? await io.read(request),
              !Task.isCancelled,
              path == self.path,
              generation == documentGeneration,
              case let .text(diskText) = result
        else {
            return
        }

        switch ExternalFileChange.action(
            diskText: diskText,
            savedText: saved,
            isDirty: isDirty
        ) {
        case .ignore:
            return
        case .reload:
            saved = diskText
            pending = diskText
            state = .text(diskText)
            hasDiskConflict = false
            revision += 1
        case .conflict:
            // The user's buffer outranks the disk: nothing is pushed at the editor.
            // The baseline still advances so a repeat of the same event is quiet,
            // and a buffer that happens to equal the new disk text is simply clean.
            saved = diskText
            isDirty = pending != diskText
            hasDiskConflict = isDirty
        }
        publishBufferState()
    }

    func load(
        _ newPath: String,
        restoring: EditorPaneState? = nil
    ) async {
        if path == newPath {
            guard case .loading = state else {
                return
            }
        }

        let generation = UUID()
        documentGeneration = generation
        path = newPath
        isDirty = false
        error = nil
        state = .loading
        saved = ""
        pending = ""
        hasDiskConflict = false
        watchToken = nil
        pendingRestore = restoring?.path == newPath ? restoring : nil

        let request = FileDocumentReadRequest(
            path: newPath,
            byteLimit: Self.byteLimit
        )
        do {
            let result = try await io.read(request)
            try Task.checkCancellation()
            accept(
                result,
                path: newPath,
                generation: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            accept(
                error,
                path: newPath,
                generation: generation
            )
        }
    }

    func edited(_ text: String) {
        pending = text
        isDirty = text != saved
        if !isDirty {
            // The buffer now matches the disk exactly, so there is nothing left to
            // be in conflict about.
            hasDiskConflict = false
        }
        publishBufferState()
    }

    func save() async {
        guard isDirty, let path else { return }

        let generation = documentGeneration
        let snapshot = pending
        do {
            try await io.write(
                FileDocumentWriteRequest(path: path, text: snapshot)
            )
            guard path == self.path,
                  generation == documentGeneration
            else {
                return
            }
            saved = snapshot
            isDirty = pending != snapshot
            // Our text is what is on disk now; whatever changed it before, the user
            // chose to overwrite it, so the conflict is resolved their way.
            hasDiskConflict = false
            error = nil
            publishBufferState()
        } catch is CancellationError {
            return
        } catch {
            guard path == self.path,
                  generation == documentGeneration
            else {
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func accept(
        _ result: FileDocumentReadResult,
        path expectedPath: String,
        generation: UUID
    ) {
        guard !Task.isCancelled,
              path == expectedPath,
              documentGeneration == generation
        else {
            return
        }
        let restore = pendingRestore
        pendingRestore = nil
        switch result {
        case let .text(text):
            saved = text
            if let restoredPending = restore?.pendingText {
                // The pane left with unsaved edits: they come back, and the buffer
                // is compared against what is on disk NOW — the disk having moved
                // underneath the buffer is exactly the conflict case.
                pending = restoredPending
                isDirty = restoredPending != text
                hasDiskConflict = isDirty && (
                    restore?.conflicted == true
                        || restore?.savedTextHash.map { $0 != text.hashValue }
                        ?? false
                )
                state = .text(restoredPending)
            } else {
                pending = text
                state = .text(text)
            }
            publishBufferState()
            startWatching(expectedPath)
        case let .image(image):
            state = .image(image)
        case let .unavailable(reason):
            state = .unavailable(reason)
        }
    }

    private func publishBufferState() {
        onBufferStateChange?()
    }

    private func startWatching(_ path: String) {
        guard let watchFiles else { return }
        // Assigning releases the previous token, whose deinit cancels its watch —
        // one live watch per pane, always the current file's.
        watchToken = watchFiles(path) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reloadAfterExternalChange()
            }
        }
    }

    /// The production watch: the EXISTING `PathWatcher` (T-018's FSEvents wrapper) on
    /// the file's parent directory, non-recursive, filtered to the file's name.
    /// Matching by name rather than full path sidesteps FSEvents' `/private` path
    /// aliasing; a spurious trigger is harmless because `reloadAfterExternalChange`
    /// compares content before acting. An overflow re-reads for the same reason.
    static let liveWatchFiles: WatchFiles = { path, onChange in
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let watcher = PathWatcher(
            path: url.deletingLastPathComponent(),
            recursive: false,
            label: "tenon.editor-file-watcher",
            onOverflow: onChange,
            onChange: { paths in
                guard paths.contains(where: {
                    ($0 as NSString).lastPathComponent == fileName
                }) else {
                    return
                }
                onChange()
            }
        )
        guard watcher.start() else { return nil }
        let box = UncheckedSendableWatcher(watcher: watcher)
        return EditorFileWatchToken { box.watcher.stop() }
    }

    private func accept(
        _ loadError: any Error,
        path expectedPath: String,
        generation: UUID
    ) {
        guard !Task.isCancelled,
              path == expectedPath,
              documentGeneration == generation
        else {
            return
        }
        pendingRestore = nil
        state = .unavailable(loadError.localizedDescription)
    }
}
