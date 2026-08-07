// @domain: editor-and-diff
import AppKit
import STTextView
import SwiftUI

/// STTextView wrapped for SwiftUI: a real code editor — line-number gutter, current-line
/// highlight, tree-sitter colours, find bar — rather than a `Text` of the file's bytes.
///
/// Edits are reported through `onChange` so the owning view can track a dirty state and
/// save; the view never writes to disk itself.
struct SourceEditorView: NSViewRepresentable {
    let text: String
    let path: String
    /// Bumped by the document model when `text` changed for the SAME path (an external
    /// reload), so the view re-reads it without a path change — a path change alone
    /// decides nothing about disk content anymore.
    var revision: Int = 0
    let font: NSFont
    let wrapLines: Bool
    var onChange: (String) -> Void = { _ in }
    /// Per-slot state target (T-016): the coordinator records scroll/selection as they
    /// change and `makeNSView` restores them, so the pane's place survives its SwiftUI
    /// view being destroyed on a pane or tab switch. Nil (previews) disables both.
    var slotID: UUID?
    var editorStates: EditorPaneStateStore?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RestorableEditorScrollView()
        let textView = STTextView()
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // The window uses a full-size content view, so automatic insets would add a
        // titlebar-height top inset that misaligns the gutter numbers against the text
        // by one line.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // The gutter is a document-height floating subview that scrolls with the text.
        // Since macOS 14 NSViews no longer clip subviews by default, so without this the
        // scrolled-away line numbers draw outside the scroll view, over the header.
        scrollView.clipsToBounds = true
        TenonScrollbarStyle.apply(to: scrollView)

        // Configure typography before setting the text: the font/colour setters restyle
        // the whole document, and restyling after layout leaves stale layout fragments
        // that break gutter numbering.
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        textView.isIncrementalSearchingEnabled = true
        apply(to: textView, scrollView: scrollView)
        textView.text = text

        // Tree-sitter highlighting, added after the text is set so the plugin's initial
        // full-document parse — which runs when the view lands in a window — sees the
        // whole document.
        if let plugin = SyntaxHighlighting.plugin(for: path) {
            textView.addPlugin(plugin)
        }

        // Captured before the coordinator attaches, because its scroll observer starts
        // overwriting the stored state immediately.
        let restored = slotID.flatMap { editorStates?.state(for: $0, path: path) }
        if let location = restored?.selectionLocation {
            // Clamped to the loaded text: the file may have shrunk since the state
            // was recorded, and an out-of-range selection is a TextKit exception.
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(
                max(0, restored?.selectionLength ?? 0),
                limit - start
            )
            textView.textSelection = NSRange(location: start, length: length)
        }

        // Record which file this buffer holds *before* the first `updateNSView`, or that
        // pass sees `loadedPath == nil`, decides the file changed, and re-assigns the
        // same text — throwing away the selection the user is about to get.
        context.coordinator.loadedPath = path
        context.coordinator.loadedRevision = revision
        context.coordinator.configure(
            slotID: slotID,
            path: path,
            editorStates: editorStates
        )
        context.coordinator.attach(textView: textView, scrollView: scrollView)

        // Restore the saved scroll offset during the first layout pass — while the
        // frame is finally known but before the first paint — so the file opens
        // already at its saved position instead of visibly scrolling into place
        // (kero's `RestorableScrollView` shape).
        if restored?.scrollX != nil || restored?.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // setBoundsOrigin (not scroll(to:)) avoids clamping against a
                // content height that TextKit2 has only estimated so far.
                clipView.setBoundsOrigin(NSPoint(
                    x: restored?.scrollX ?? 0,
                    y: restored?.scrollY ?? 0
                ))
                scrollView.reflectScrolledClipView(clipView)
                // Lay out the viewport around the restored offset in this same
                // pass so the region is painted in place, not after a scroll.
                textView.needsLayout = true
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        context.coordinator.onChange = onChange
        apply(to: textView, scrollView: scrollView)
        // Only push text back in when the document itself changed underneath us —
        // assigning `text` restyles and re-lays out the entire document, and doing
        // that on every SwiftUI render would fight the user's typing.
        if context.coordinator.loadedPath != path {
            context.coordinator.loadedPath = path
            context.coordinator.loadedRevision = revision
            context.coordinator.configure(
                slotID: slotID,
                path: path,
                editorStates: editorStates
            )
            textView.text = text
        } else if context.coordinator.loadedRevision != revision {
            // The file changed on disk and the pane was clean: swap in the new text
            // while keeping the user's place, clamped to the new length.
            context.coordinator.loadedRevision = revision
            let selection = textView.textSelection
            let origin = scrollView.contentView.bounds.origin
            textView.text = text
            let limit = text.utf16.count
            let start = min(max(0, selection.location), limit)
            textView.textSelection = NSRange(
                location: start,
                length: min(max(0, selection.length), limit - start)
            )
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.needsLayout = true
        }
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the editor from
    /// the scroll view's `fittingSize`, which STTextView derives from the whole document
    /// — enormous for a large file, degenerate for an empty one — and that runaway
    /// measurement drives the window size into an unbounded layout loop.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }

    /// Guarded assignments: the font/colour setters restyle the whole document, and this
    /// runs on every SwiftUI render.
    private func apply(to textView: STTextView, scrollView: NSScrollView) {
        if textView.font != font {
            textView.font = font
        }
        let foreground = TenonTheme.textNS
        if textView.textColor != foreground {
            textView.textColor = foreground
        }
        let background = TenonTheme.panelNS
        if textView.backgroundColor != background {
            textView.backgroundColor = background
            scrollView.backgroundColor = background
        }
        textView.insertionPointColor = TenonTheme.amberNS
        textView.selectedLineHighlightColor = TenonTheme.textNS.withAlphaComponent(0.045)
        // false = wrap at the view width, true = expand horizontally.
        textView.isHorizontallyResizable = !wrapLines
        if let gutter = textView.gutterView {
            gutter.textColor = TenonTheme.mutedNS.withAlphaComponent(0.55)
            gutter.selectedLineTextColor = TenonTheme.textNS
        }
    }

    // `@preconcurrency`: STTextViewDelegate is not itself main-actor-isolated, but every
    // callback arrives on the main thread from AppKit. The attribute turns the isolation
    // mismatch into a runtime check instead of a Swift 6 hard error.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var onChange: (String) -> Void
        /// The file this view currently holds, so `updateNSView` can tell "the user
        /// typed" (leave the buffer alone) from "a different file arrived".
        var loadedPath: String?
        /// The document revision this view holds, so `updateNSView` can tell "SwiftUI
        /// re-rendered" from "the same file's text was reloaded from disk".
        var loadedRevision = 0
        private var slotID: UUID?
        private var statePath: String?
        private var editorStates: EditorPaneStateStore?
        private weak var textView: STTextView?
        private var scrollObserver: (any NSObjectProtocol)?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        /// Where scroll/selection recordings go. Keyed by slot AND path so a pane
        /// whose content changed cannot write under the previous file's name.
        func configure(
            slotID: UUID?,
            path: String,
            editorStates: EditorPaneStateStore?
        ) {
            self.slotID = slotID
            self.statePath = path
            self.editorStates = editorStates
        }

        func attach(textView: STTextView, scrollView: NSScrollView) {
            self.textView = textView
            textView.textDelegate = self
            // Scroll capture rides `reflectScrolledClipView` — AppKit's own "the clip
            // view moved" hook — rather than a bounds notification, so everything
            // stays on the main actor with no observer token to unregister.
            (scrollView as? RestorableEditorScrollView)?.onScrollChange = {
                [weak self] origin in
                guard let self,
                      let slotID = self.slotID,
                      let path = self.statePath
                else {
                    return
                }
                self.editorStates?.recordScroll(
                    for: slotID,
                    path: path,
                    x: origin.x,
                    y: origin.y
                )
            }
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            onChange(textView.text ?? "")
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView,
                  let slotID,
                  let path = statePath
            else {
                return
            }
            let selection = textView.textSelection
            editorStates?.recordSelection(
                for: slotID,
                path: path,
                location: selection.location,
                length: selection.length
            )
        }
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout pass —
/// before the first paint — so a restored file opens already scrolled to its saved
/// position instead of visibly jumping there afterward (ported from kero).
private final class RestorableEditorScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    /// Fired with the clip view's new origin every time the content scrolls —
    /// AppKit funnels user scrolls through `reflectScrolledClipView`.
    var onScrollChange: ((NSPoint) -> Void)?

    override func layout() {
        super.layout()
        if bounds.width > 0, bounds.height > 0, let restore = restoreOnFirstLayout {
            restoreOnFirstLayout = nil
            restore()
        }
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        onScrollChange?(cView.bounds.origin)
    }
}
