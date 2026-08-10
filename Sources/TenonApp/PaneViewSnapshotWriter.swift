// @domain: pane-chrome
import AppKit
import SwiftUI
import TenonCore

/// Turns any pane's content into a PNG with no window and no Screen Recording grant, then
/// exits.
///
/// `NSHostingView` + `layoutSubtreeIfNeeded` + `cacheDisplay` renders SwiftUI offscreen;
/// `screencapture` cannot help here, because this process has no capture permission and fails
/// with "could not create image from window". The runloop turns in the middle are not
/// decoration: a `ScrollView` lays its content out over real turns, and capturing before them
/// photographs an empty pane.
///
/// One writer for every snapshot subject — the diff, the changes panel, and any plugin view —
/// so a picture of one pane is taken exactly the way a picture of another is, and the timings
/// printed to stderr mean the same thing across all of them.
enum PaneViewSnapshotWriter {
    @MainActor
    static func write(
        _ view: some View,
        slot: WorkspaceSlot,
        title: String,
        headerStore: PaneHeaderStore,
        size: CGSize,
        to path: String
    ) -> Never {
        write(
            bare: PaneChromePreview(
                slot: slot,
                title: title,
                headerStore: headerStore
            ) { view },
            size: size,
            to: path
        )
    }

    /// The same capture with no pane around it, for shell chrome that is not a pane — the
    /// workspace sidebar and its footer. Wrapping those in a slot header would photograph a
    /// frame the app never draws around them.
    @MainActor
    static func write(bare view: some View, size: CGSize, to path: String) -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: size)
        let layoutStart = Date()
        hosting.layoutSubtreeIfNeeded()
        let firstLayout = Date().timeIntervalSince(layoutStart)
        // Give SwiftUI real runloop turns to lay out its ScrollView content and
        // commit its layer before the offscreen capture.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fail("no bitmap rep", code: 2)
        }
        let captureStart = Date()
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let capture = Date().timeIntervalSince(captureStart)
        FileHandle.standardError.write(
            Data(String(format: "snapshot: layout %.0f ms, capture %.0f ms\n",
                        firstLayout * 1000, capture * 1000).utf8)
        )
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("png encode failed", code: 3)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
            exit(0)
        } catch {
            fail("write failed: \(error)", code: 3)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(code)
    }
}
