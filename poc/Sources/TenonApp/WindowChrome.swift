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

/// A backmost, chrome-colored layer that gives the empty parts of the title bar the
/// behaviour of a system one: drag moves the window, double-click zooms or minimises
/// it per the user's System Settings choice. Interactive controls layered in front
/// handle their own clicks; only the gaps fall through to this view.
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
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // The drag is driven from `mouseDown` rather than `mouseDownCanMoveWindow`,
        // which hands the press to the window server and so never delivers the
        // second click a title bar answers with zoom/minimise. `performDrag` keeps
        // the system drag itself — snapping, tiling, spaces — identical.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }

            guard event.clickCount < 2 else {
                performDoubleClickAction(on: window)
                return
            }

            window.performDrag(with: event)
        }

        /// System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to".
        /// The key is absent until the user changes it away from the zoom default.
        private func performDoubleClickAction(on window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                window.performZoom(nil)
            }
        }
    }
}
