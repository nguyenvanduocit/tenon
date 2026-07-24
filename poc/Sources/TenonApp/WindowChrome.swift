import AppKit
import SwiftUI

/// Sets the window background and keeps window-background dragging off, so the only
/// draggable region is the title bar's `WindowDragArea` — the spatial canvas keeps
/// its own pointer drags.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = .tenonInk
        window.isMovableByWindowBackground = false
    }
}

/// A backmost, chrome-colored layer that lets the user drag the window by the empty
/// parts of the title bar. Interactive controls layered in front handle their own
/// clicks; only the gaps fall through to this view.
struct WindowDragArea: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = DraggableView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = color.cgColor
    }

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
