// Measures how much of a window's bottom edge the resize gutter takes, and whether a tab
// chip drawn in the foot row clears it. Run it with:
//
//     swift scripts/internal/foot-strip-edge-probe.swift
//
// Why this exists: the tab strip can be drawn in the row across the bottom of the window, and
// the bottom few points of a window do not belong to the app at all — they hit-test to
// `NSThemeFrame`, which is what makes the window resizable by its edge. A chip drawn flush to
// that edge silently loses its lowest rows of pixels: the ✕ still draws, and a press near it
// starts a resize instead. Nothing in `swift test` can see this. `TabStripReorderTests` mounts
// windows and drives real presses, but it aims at chip centres, which are nowhere near the
// gutter — a suite can be entirely green while the bottom two points of every chip are dead.
//
// This is the mirror image of `drag-region-probe.swift`: that one measures what the window
// server takes from the TOP band, this one measures what `NSThemeFrame` takes from the BOTTOM
// edge. Neither rule is ours, both decide whether a pointer reaches the strip, and both are
// worth re-running on a new macOS.
//
// It deliberately does NOT reproduce `ShellTabStrip`: a copy of the strip's layout would rot.
// It reproduces the geometry the strip is laid out with — `TenonTheme.footTabStripHeight` and
// the 26-pt chip inside it — and asks AppKit where the app's own view starts answering.
//
// Exit 0 means a centred chip clears the gutter. Exit 1 means it does not, and the row needs
// to be taller — the numbers to change are in `TenonTheme`.

import AppKit

/// Kept in step with `TenonTheme` by hand, and printed on every run so a drift is visible in
/// the output rather than hidden in a pass. There is no import path from a script to the app.
let footRowHeight: CGFloat = 34
let chipHeight: CGFloat = 26

/// The strip's own surface, reduced to the one property that decides whether AppKit will let
/// it answer a press at all.
final class FootProbe: NSControl {
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let size = NSSize(width: 900, height: 300)
let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden

let content = NSView(frame: NSRect(origin: .zero, size: size))
let foot = FootProbe(
    frame: NSRect(x: 0, y: 0, width: size.width, height: footRowHeight)
)
content.addSubview(foot)
window.contentView = content
window.setFrameOrigin(NSPoint(x: -8_000, y: -8_000))
window.makeKeyAndOrderFront(nil)
window.contentView?.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

guard let frame = window.contentView?.superview else {
    FileHandle.standardError.write(Data("probe: the window has no frame view\n".utf8))
    exit(2)
}

/// Walk up from the very bottom of the window and find the first y the app's own view
/// answers for. Everything below it belongs to the resize gutter.
var gutter: CGFloat = 0
var firstAppY: CGFloat?
for tenths in 0...200 {
    let y = CGFloat(tenths) / 10
    let hit = frame.hitTest(NSPoint(x: size.width / 2, y: y))
    let isApp = hit === foot
    if isApp, firstAppY == nil { firstAppY = y }
    if !isApp, firstAppY == nil { gutter = y + 0.1 }
}

print("window          \(Int(size.width))x\(Int(size.height)), resizable, fullSizeContentView")
print("foot row        \(footRowHeight) pt, chip \(chipHeight) pt")
print(
    "gutter          bottom \(String(format: "%.1f", gutter)) pt hit-tests to "
        + "\(type(of: frame)) rather than the app"
)

guard let firstAppY else {
    FileHandle.standardError.write(
        Data("probe: the app's foot view never answers a hit test — measured nothing\n".utf8)
    )
    exit(2)
}
print("app answers at  y = \(String(format: "%.1f", firstAppY)) and above")

let clearance = (footRowHeight - chipHeight) / 2
print("chip clearance  \(clearance) pt below a centred chip")

if clearance > gutter {
    print("\nOK — a centred \(Int(chipHeight))-pt chip clears the gutter by "
        + "\(String(format: "%.1f", clearance - gutter)) pt.")
    exit(0)
} else {
    FileHandle.standardError.write(Data("""

        FAIL — a centred \(Int(chipHeight))-pt chip leaves \(clearance) pt below it and the \
        gutter takes \(String(format: "%.1f", gutter)). The chip's lowest pixels are a resize \
        handle. Raise TenonTheme.footTabStripHeight.

        """.utf8))
    exit(1)
}
