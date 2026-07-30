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
    @State private var model = FileDocumentModel()

    var body: some View {
        // No header of its own: the pane chrome already names the file. Unsaved and
        // error state float over the top-right corner instead, where they cost no
        // vertical space and are absent whenever there is nothing to say.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.panel)
            .overlay(alignment: .topTrailing) { statusBadge }
            .task(id: path) {
                await model.load(path)
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
                font: TenonTheme.utilityNSFont(size: 12),
                wrapLines: false,
                onChange: { model.edited($0) }
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

    private(set) var state: State = .loading
    private(set) var isDirty = false
    private(set) var error: String?
    /// The file `state` actually holds. The view compares this against the path it was
    /// handed, so it never paints one file's text under another's name.
    private(set) var path: String?
    /// What is on disk as far as we know, so a save is a no-op when nothing changed.
    private var saved = ""
    private var pending = ""

    @ObservationIgnored
    private let io: FileDocumentIO

    @ObservationIgnored
    private var documentGeneration = UUID()

    /// Bigger than this and the editor would be holding a log file, not source. TextKit
    /// copes, but nothing good comes of opening a 200 MB file in a pane.
    private static let byteLimit = 8_000_000

    init(io: FileDocumentIO = .live) {
        self.io = io
    }

    func load(_ newPath: String) async {
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
            error = nil
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
        switch result {
        case let .text(text):
            saved = text
            pending = text
            state = .text(text)
        case let .image(image):
            state = .image(image)
        case let .unavailable(reason):
            state = .unavailable(reason)
        }
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
        state = .unavailable(loadError.localizedDescription)
    }
}
