// Measures the AppKit rule the tab strip depends on. Run it with:
//
//     swift scripts/drag-region-probe.swift
//
// Why this exists: three fixes for T-101 shipped, each internally correct, because the rule
// everyone reasoned from was false. macOS does *not* ask the hit-tested view whether a press
// in the title-bar band belongs to the window server. AppKit computes a **drag region** for
// the window ahead of time and uploads it to the server, which then starts the move on its
// own. `mouseDownCanMoveWindow` answers that region builder — and the builder honours a
// `false` only from an `NSControl` descendant. A plain `NSView` saying it changes nothing.
//
// A gesture test cannot observe this: `NSWindow.sendEvent` injects below the window server, so
// it drives the whole press-drag-release successfully while a hardware press still moves the
// window. `TabStripReorderTests` closes that by reading the region back for Tenon's own bar;
// this probe is the rule underneath, isolated — for a future macOS, or the next time someone
// reads `TabStripSurface.SurfaceView` and wonders why it is a control.
//
// It deliberately does NOT reproduce `ShellTitleBar`: a copy of the strip's layout would rot.
// It reproduces only the rule, with the window's own baseline as a two-sided oracle — the
// close button must be OUTSIDE the region (it is an NSButton, so it is carved out) and the
// empty title bar must be INSIDE it (that is what makes a window draggable at all). A run
// whose oracle fails measured nothing, whatever the rest of it printed.

import AppKit

/// The strip's surface, reduced to the overrides that matter, over both possible roots.
final class ProbeControl: NSControl {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class ProbeView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The second axis, and the one this probe missed the first time it was written.
///
/// Being an `NSControl` is necessary and not sufficient: the region builder carves out a
/// control that *accepts first responder* and leaves one that refuses inside the region. The
/// strip answered `false` there for a while — to hand the keyboard back to the terminal — and
/// that one line put every chip back under the window server while this probe, measuring a
/// control it no longer resembled, went on reporting that the rule held.
final class ProbeControlRefusingFirstResponder: NSControl {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

/// The region AppKit last uploaded to the window server, as rectangles in window coordinates.
func dragRegion(of window: NSWindow) -> [NSRect]? {
    let selector = NSSelectorFromString("_lastDragRegionDataDescription")
    guard window.responds(to: selector),
          let description = window.perform(selector)?.takeUnretainedValue() as? NSString
    else { return nil }

    let pattern = #"\{\{\s*([-\d.]+),\s*([-\d.]+)\s*\},\s*\{\s*([-\d.]+),\s*([-\d.]+)\s*\}\}"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let text = description as String
    return expression
        .matches(in: text, range: NSRange(location: 0, length: description.length))
        .compactMap { match in
            let numbers = (1 ... 4).compactMap { Double(description.substring(with: match.range(at: $0))) }
            guard numbers.count == 4 else { return nil }
            return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
}

/// One window carrying `subject` across the title-bar band, answered by the region.
func regionTakes(_ subject: NSView, label: String) -> Bool? {
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 900, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    // Across the band, clear of the traffic lights, leaving chrome to its right.
    subject.frame = NSRect(x: 240, y: 269, width: 400, height: 26)
    content.addSubview(subject)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))

    defer { window.orderOut(nil) }
    guard let region = dragRegion(of: window) else {
        print("  \(label): this macOS no longer exposes the drag region")
        return nil
    }

    let band = window.frame.height - 16
    let closeButton = NSPoint(x: 16, y: band)
    let chrome = NSPoint(x: window.frame.width - 60, y: band)
    let oracleHolds = !region.contains { $0.contains(closeButton) }
        && region.contains { $0.contains(chrome) }
    guard oracleHolds else {
        print("  \(label): ORACLE FAILED — region \(region) measures nothing")
        return nil
    }

    let subjectRect = subject.convert(subject.bounds, to: nil)
    return region.contains { $0.intersects(subjectRect) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("Does the window server's drag region cover a view that refuses window moves?")
let asView = regionTakes(ProbeView(), label: "NSView")
let asControl = regionTakes(ProbeControl(), label: "NSControl")
let asSilentControl = regionTakes(
    ProbeControlRefusingFirstResponder(),
    label: "NSControl refusing first responder"
)

for (label, taken) in [
    ("NSView                             ", asView),
    ("NSControl                          ", asControl),
    ("NSControl, acceptsFirstResponder=no", asSilentControl),
] {
    guard let taken else { continue }
    print("  \(label) with mouseDownCanMoveWindow=false → region \(taken ? "COVERS it (the server takes the press)" : "skips it (the app keeps the press)")")
}

if asView == true, asControl == false, asSilentControl == true {
    print("\nRule holds, on both axes: a view leaves the drag region only by being an NSControl")
    print("*and* accepting first responder. That is why TabStripSurface.SurfaceView is a control")
    print("and why it does not override acceptsFirstResponder — the keyboard is kept by not")
    print("calling super in the mouse path, which focuses nothing.")
    exit(0)
}
print("\nRule did NOT reproduce. TabStripSurface's shape rests on it — re-derive before trusting it.")
exit(1)
