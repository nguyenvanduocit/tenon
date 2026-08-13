# T-144: A tab moves while you are still dragging it

> The strip previews a reorder with a caret and commits it on release. Kero moves the chips
> live, under the pointer, and the operator asked for that shape. Taking it also takes the
> AppKit surface that owns every press in the strip back out of the design.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-002` command-surfaces — `CMD-FR-012`, `CMD-FR-013`, `CMD-FR-015`,
  `CMD-FR-016`, `CMD-FR-019`, `CMD-NFR-005`, `CMD-GM-001`
- **reference**: `references/kero` — `ContentView.swift:1090-1097, 1250-1267` (the gesture and
  the live swap), `WindowChrome.swift:57-60, 125-135` and `keroApp.swift:26-29` (its window
  route, which this task deliberately does **not** copy — see the measurement below)

## Owner / files (agent lock)

**CLAIMED by session `0f61f4b1` 2026-08-13 13:5x.** Fourth card in Doing, over the WIP limit,
by explicit operator decision — the request came with the reference implementation named. None
of these files is held by T-141, T-140, or T-135.

- `Sources/TenonApp/ShellTitleBar.swift`
- `Sources/TenonCore/TabReorder.swift`
- `Tests/TenonAppStateTests/TabStripReorderTests.swift`
- `Tests/TenonCoreTests/TabReorderTests.swift`
- `scripts/internal/drag-region-probe.swift`
- `docs/prds/command-surfaces.prd.md`, `docs/prds/command-surfaces.feature`

## What kero does, and what of it is safe to take

Three layers, and only the top two survive measurement here:

1. **Its window route (rejected).** `window.isMovable = false` + `.windowBackgroundDragBehavior(.disabled)`,
   with window dragging handed back to one `WindowDragGesture()`. Measured on macOS 26.4:
   `isMovable = false` empties the drag region completely — **0 rects, chrome included** — which
   is the regression T-101 recorded. Kero pays for that with `WindowDragGesture`, which is
   **macOS 15.0+**, and `Package.swift:19` puts Tenon's floor at macOS 14. Copying this layer
   would cost the deployment floor and `CMD-FR-016` both.
2. **Chips own their own pointer (taken).** Ordinary SwiftUI chips carrying their own buttons,
   hover, and a `DragGesture`.
3. **The reorder is live (taken).** The tab moves as the pointer crosses another chip, animated,
   rather than a caret marking where a release would put it.

Layer 2 is reachable without layer 1, and that is the finding this task rests on. The drag
region is **not** front-view-wins: a carving `NSControl` keeps its rect out of the region from
any z position, including behind the movable container SwiftUI flattens the chips into.
Measured with the same `_lastDragRegionDataDescription` oracle the probe uses (close button
outside the region, chrome inside):

| arrangement | chips | chrome |
|---|---|---|
| control alone | outside region | inside |
| control **in front of** a movable container (today's `.overlay`) | outside region | inside |
| control **behind** a movable container (`.background`) | **outside region** | **inside** |
| control as superview of a movable container | outside region | inside |
| inert carver behind (hitTest → nil), not a key view, not an a11y element | **outside region** | **inside** |
| the same carver with `isHidden = true` | covered by region | inside |
| `window.isMovable = false`, no carver | outside region | **outside — region empty** |

So the surface stops owning presses and becomes a region carver in `.background`: the window
keeps `isMovable`, empty chrome keeps `performDrag` with system snapping, and the chips get
their clicks back from SwiftUI. The last row is the control that says the measurement depends
on the view rather than on luck.

## What shipped, and what the third layer cost

Layer 3 shipped whole. **Layer 2 did not, and the reason is measured rather than argued.**

A SwiftUI `DragGesture` in an `NSHostingView` swallows a synthetic `leftMouseDown` into a
nested event-tracking loop that only a real `NSApp.run()` feeds. Driven three ways — through
`window.sendEvent` (the route this file's own tests use), `NSApp.sendEvent`, and a prefilled
event queue pumped by hand — it either never fires at all or **blocks the process past a 20 s
watchdog**, with and without app activation, with and without a `Button` under it. In a shared
`Tests/` target that is not a missing assertion, it is every concurrent agent's `swift test`
hanging. Kero can hold this shape because kero verifies by hand (`kero/CLAUDE.md`: *"Build, run
the app, exercise the change"*); this repo's bar is `swift test`, and T-101 is the record of what
an unprovable gesture costs here — three internally correct fixes shipped before anyone measured.

So `TabStripSurface` keeps the primary-button stream, and with it the chips' clicks, closes, and
hover. The z-order finding above is not used by the shipped design; it is kept because it is what
turned "kero's shape is impossible here" into "kero's shape is possible and still not worth it",
and the next person to ask deserves the measurement rather than the conclusion.

## Evidence

`swift test --filter "TabReorderTests|TabStripReorderTests"` **40 / 0**; full `swift test`
**2102 / 0** in 141 s, 2026-08-13. `swift scripts/internal/drag-region-probe.swift` exit 0 on
macOS 26.4 before the change, so the mechanism the chips rest on was confirmed still standing
rather than assumed.

## Criteria

- [x] A drag across a neighbour moves the tab **during** the drag, not on release —
      `testTheTabHasAlreadyMovedBeforeTheDragIsReleased`, red first at "still in the original
      order with the button down"
- [x] A press under the threshold still selects; a press on the ✕ still closes — unchanged seam,
      `testAPressThatDoesNotTravelSelectsTheChipUnderIt`, `testAPressOnTheCloseControlClosesThatTab`
- [x] Hover lights the chip the pointer rests on — unchanged seam, `testTheSurfaceReportsTheEndOfAHover`
- [x] Releasing beyond the strip's admitted vertical band restores the order the drag started
      from — `testReleasingBelowTheStripRestoresTheOrderTheDragStartedFrom`, and one move does it
- [x] A leftward drag lands correctly too — `testADragBackToTheStartMovesTheTabTheOtherWay`, the
      direction no test in the file had ever driven and the one the feedback loop is not
      symmetric in
- [x] The loop settles over uneven chips — `testASweepAcrossUnevenChipsMovesTheTabOnlyTheWayThePointerIsGoing`,
      pure core, re-laying the row after every move
- [x] Empty chrome still drags the window and honours the double-click preference — `WindowChrome`
      untouched, `isMovable` untouched
- [x] The chips are still outside the drag region —
      `testTheChipsAreOutsideTheDragRegionTheWindowServerMovesTheWindowFrom`, plus
      `scripts/internal/drag-region-probe.swift` exit 0 on macOS 26.4
- [x] The `+` launcher still opens; clicking a chip still leaves the keyboard with the terminal
- [x] `CMD-FR-013`/`CMD-FR-015` restated for a live reorder, the caret non-goal retired, two
      decision-log rows with the measurements, evidence row, delivery matrix, receipts, change
      history
- [ ] **Owed: a hardware drag on an installed build.** The suite proves the row ends in the new
      order; whether a person can follow which chip went where at 0.12 s is not a headless
      question, and `TENON_TAB_STRIP_SNAPSHOT` photographs one frame of it, not the motion
