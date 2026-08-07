# Pane hosting: size flows one way

A pane's size is the canvas's answer. `SpatialSlotCardView.layout()` computes the card's
header height from its own bounds and gives the rest to the content host by setting
`contentHost.frame` outright. Nothing downstream of that frame is consulted, and nothing
reads a size back out of the pane.

`PaneContentHost.make` is where that arrangement is stated rather than merely practised.
An `NSHostingView` constructed plainly publishes `sizingOptions` of
`[.minSize, .intrinsicContentSize, .maxSize]` — it offers AppKit min, ideal, and max sizes
derived from the SwiftUI content it carries. For a pane that is an offer nobody should
take up: the frame is already decided, so the only effect of accepting it is cost.

The cost is not uniform. Asking a pane for an ideal height means asking its content how
tall it would like to be, and a pane whose content scrolls has no such height — answering
requires measuring rows the pane will never show. `PaneHostingSizingTests` pins both
halves: that a pane host publishes nothing, and that a plain hosting view would.

## What this is not

This is not a fix for the hang recorded in T-091, and it should not be cited as one. That
hang was a SwiftUI update that re-armed itself: `Update.dispatchActions()` running
`LazyLayoutViewCache.signalPrefetch()`, which requested the very update it was dispatched
from. The main thread therefore never returned from one runloop-observer call, the runloop
never drained its autorelease pool, and the process reached 11 GB with 10.4 GB swapped.

Five reconstructions of the pane's hosting shape — including one that nests
SwiftUI → AppKit → SwiftUI exactly as `SpatialCanvasView` → `SpatialCanvasNSView` →
`contentHost` does — all converged in a standalone harness. So content-derived sizing is
not sufficient to start that loop, and removing it is not known to prevent it. The
reproduction is still open; T-091 carries the falsification list so it is not repeated.

What this change does claim is narrower and measured: a pane no longer invites a
measurement that its own layout has already made unnecessary.
