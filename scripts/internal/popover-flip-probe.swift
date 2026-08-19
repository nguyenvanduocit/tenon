// Measures the AppKit rule `SpatialCanvasNSView`'s empty-grid launcher depends on. Run it
// with:
//
//     swift scripts/internal/popover-flip-probe.swift
//
// Why this exists: the empty-grid launcher's popover was opening ABOVE a click instead of
// below it, worse the further down the canvas the click landed — a bug live-reported against
// a screenshot, not caught by any test, because `NSPopover.show(relativeTo:of:preferredEdge:)`
// is real window-server geometry that `NSWindow.sendEvent` injects below (the same class of
// gap `drag-region-probe.swift` and `foot-strip-edge-probe.swift` measure).
//
// The rule: `NSPopover` does not read `isFlipped` on the positioning view when it turns
// `preferredEdge` into a screen position — it always resolves the edge as if the view had
// AppKit's default bottom-left origin. `SpatialCanvasNSView` overrides `isFlipped` to `true`
// (top-left origin, matching the SwiftUI mental model its click handling already uses), so on
// that view `preferredEdge: .minY` opens the popover above the anchor by roughly the
// popover's own height, and `.maxY` is what actually opens it below. The anchor POINT itself
// is unaffected — `convert`/`convertToScreen` already account for `isFlipped` correctly — only
// the edge direction is inverted, which is why the bug reads as "the popover ignores where I
// clicked" rather than "the popover is offset by a fixed amount."
//
// Two-sided oracle: a plain (non-flipped) control view must show `.minY` opening below with a
// negligible top/click delta, proving the probe's own screen-position arithmetic is sound.
// Only then does the flipped view's measurement mean anything.

import AppKit

final class FlippedProbeView: NSView {
    override var isFlipped: Bool { true }
}

final class PlainProbeView: NSView {}

/// The popover's top-edge screen Y minus the click's screen Y, for one click, one
/// `preferredEdge`. Near zero means "opens right at the click, growing down" — a correctly
/// positioned launcher popover.
func topDelta(
    _ subject: NSView,
    clickPoint: CGPoint,
    edge: NSRectEdge,
    in window: NSWindow
) -> CGFloat {
    let screenPoint = window.convertPoint(toScreen: subject.convert(clickPoint, to: nil))
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    let vc = NSViewController()
    vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    vc.view.wantsLayer = true
    popover.contentViewController = vc
    popover.show(
        relativeTo: NSRect(x: clickPoint.x, y: clickPoint.y, width: 1, height: 1),
        of: subject,
        preferredEdge: edge
    )
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    let delta = (vc.view.window?.frame.maxY ?? .nan) - screenPoint.y
    popover.performClose(nil)
    return delta
}

func withProbeWindow<T>(height: CGFloat, subject: NSView, _ body: (NSWindow) -> T) -> T {
    let window = NSWindow(
        contentRect: NSRect(x: 300, y: 300, width: 900, height: height),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: height))
    subject.frame = content.bounds
    subject.autoresizingMask = [.width, .height]
    content.addSubview(subject)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
    defer { window.orderOut(nil) }
    return body(window)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let viewHeight: CGFloat = 700
let offsets: [CGFloat] = [50, 350, 650]
// A negligible delta at every offset means "opens right at the click" — the correctly
// positioned case. A grown delta at a large offset is the bug this probe exists to catch.
let tolerance: CGFloat = 4

print("Does NSPopover honour a flipped positioning view's preferredEdge?")

var plainOracleHolds = true
withProbeWindow(height: viewHeight, subject: PlainProbeView()) { window in
    for offset in offsets {
        // A plain view's own coordinate origin is at the bottom, so "below the top by
        // `offset`" is `viewHeight - offset` in its own bounds.
        let delta = topDelta(
            window.contentView!.subviews[0],
            clickPoint: CGPoint(x: 450, y: viewHeight - offset),
            edge: .minY,
            in: window
        )
        print("  control (isFlipped=false) .minY, \(Int(offset))pt below top → Δtop=\(Int(delta))")
        if abs(delta) > tolerance { plainOracleHolds = false }
    }
}
guard plainOracleHolds else {
    print("\nORACLE FAILED — the control view itself didn't open below at .minY; this probe's")
    print("own screen-position arithmetic measured nothing. Re-derive before trusting it.")
    exit(1)
}

var minYGrows = false
var maxYCorrect = true
withProbeWindow(height: viewHeight, subject: FlippedProbeView()) { window in
    let subject = window.contentView!.subviews[0]
    var minYDeltas: [CGFloat] = []
    for offset in offsets {
        let delta = topDelta(subject, clickPoint: CGPoint(x: 450, y: offset), edge: .minY, in: window)
        print("  flipped .minY (current bug), \(Int(offset))pt below top → Δtop=\(Int(delta))")
        minYDeltas.append(delta)
    }
    // The bug reproduces as a large, roughly-constant delta — the popover always opens
    // above by about its own height, which is what makes it look "more wrong" toward the
    // bottom of a tall canvas: near the top there's nowhere for that error to go, so
    // AppKit's on-screen clamping happens to pull it back close to correct.
    minYGrows = minYDeltas.allSatisfy { $0 > 100 }

    for offset in offsets {
        let delta = topDelta(subject, clickPoint: CGPoint(x: 450, y: offset), edge: .maxY, in: window)
        print("  flipped .maxY (fix), \(Int(offset))pt below top → Δtop=\(Int(delta))")
        if abs(delta) > tolerance { maxYCorrect = false }
    }
}

if minYGrows, maxYCorrect {
    print("\nRule holds: on a flipped positioning view, `.minY` opens the popover above the")
    print("click by roughly its own height, and `.maxY` is what actually opens it below.")
    print("`SpatialCanvasNSView.presentEmptyGridLauncher` uses `.maxY` because of this.")
    exit(0)
}
print("\nRule did NOT reproduce — re-derive `SpatialCanvasNSView`'s `preferredEdge` from")
print("this probe before trusting it; a future AppKit may have fixed the underlying bug.")
exit(1)
