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
    let font: NSFont
    let wrapLines: Bool
    var onChange: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
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

        // Record which file this buffer holds *before* the first `updateNSView`, or that
        // pass sees `loadedPath == nil`, decides the file changed, and re-assigns the
        // same text — throwing away the selection the user is about to get.
        context.coordinator.loadedPath = path
        context.coordinator.attach(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        context.coordinator.onChange = onChange
        apply(to: textView, scrollView: scrollView)
        // Only push text back in when the file itself changed underneath us — assigning
        // `text` restyles and re-lays out the entire document, and doing that on every
        // SwiftUI render would fight the user's typing.
        if context.coordinator.loadedPath != path {
            context.coordinator.loadedPath = path
            textView.text = text
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
        private weak var textView: STTextView?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func attach(textView: STTextView) {
            self.textView = textView
            textView.textDelegate = self
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            onChange(textView.text ?? "")
        }
    }
}
