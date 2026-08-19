// @domain: command-surface
import AppKit
import SwiftUI

/// Reports where a view sits in *screen* coordinates.
///
/// A popover anchored to a control has to know how much of the display is left in the
/// direction it opens, and the display is the only frame both ends of that question share:
/// window space cannot tell a control near the bottom of a tall window from one near the top
/// of a short one, and that difference is exactly what decides how tall a launcher list may
/// grow. `WindowFrameReporter` answers the drop-routing question in window space; this
/// answers the screen-room question in screen space, and the two are deliberately separate
/// rather than one reporter converting on demand.
struct ScreenFrameReporter: NSViewRepresentable {
    let report: (CGRect) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.report = report
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.report = report
        view.publish()
    }

    final class ReporterView: NSView {
        var report: (CGRect) -> Void = { _ in }

        /// Never the answer to a hit test: this observes geometry and takes no pointer.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            publish()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            publish()
        }

        func publish() {
            guard let window else { return }
            report(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
