# T-101: A tab drag reorders instead of moving the window
> Dragging a tab chip moves the whole window; the reorder T-096 shipped never starts.
- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-002` command-surfaces — `CMD-M-003` (tab reorder moves window frame),
  `CMD-FR-013`/`CMD-FR-014` (drag reorders), `CMD-FR-016` (empty chrome drags the window)

## Reported
2026-08-09 11:28, user, against the installed build from 10:13 (which already carries
`TabReorderMonitor` and `WindowChrome`'s `isMovable = false`):

- drag a tab → **the whole window moves**, the tab never reorders
- click a tab → selects it, normally
- drag the empty title bar → window moves, normally

## Root cause — the real one (measured, HIGH)

**macOS never asks the hit-tested view.** AppKit computes a *drag region* for the window,
uploads it to the window server, and the server starts the move from it — before the app is
consulted at all. `mouseDownCanMoveWindow` answers that region builder, and the builder
honours a `false` **only from an `NSControl` descendant**. That is how AppKit separates a
control from chrome, and why the traffic lights (`NSButton`) are the one baseline hole in the
region while ordinary SwiftUI content is not.

Read back through `NSWindow._lastDragRegionDataDescription` on a window reproducing the shipped
structure, with a two-sided oracle in every run — the close button must be *outside* the region,
the empty chrome *inside*:

| surface's superclass | chips in the drag region | hit test | oracle |
|---|---|---|---|
| `NSView` (what shipped three times) | **YES — the server takes the press** | `SurfaceAsView` | ✓ |
| `NSControl` | no — the app keeps it | `SurfaceAsControl` | ✓ |
| `NSView` + `window.isMovable = false` | no | `SurfaceAsView` | **✗ chrome lost its drag too** |

This is why every headless seam was green while the bug lived: hit-testing was right, event
delivery was right, the reorder rules were right, and `NSWindow.sendEvent` injects *below* the
window server, so no test that uses it can ever see this. The fix is one word —
`final class SurfaceView: NSControl` — and the three comments that stated the false rule are
corrected in the same change, because that premise is what generated three correct-looking
fixes.

It also retires the last row below: `isMovable = false` does close the path, by emptying the
region **including the chrome zone**, which is exactly the regression the oracle catches.

## Earlier account of the root cause (superseded, kept as the record of what misled three fixes)

The strip is drawn up into the window's title-bar band (`ContentView.swift`,
`.ignoresSafeArea(.container, edges: .top)`; bar 36 pt, system band 32 pt, chips span
5…31 pt from the window top — the whole chip is inside the band).

In that band macOS starts a **server-side window move** when the pointer travels, if the
view AppKit hit-tested answers `mouseDownCanMoveWindow == true`. Every AppKit view SwiftUI
builds under a chip answers exactly that — measured in a standalone probe against a real
`.windowStyle(.hiddenTitleBar)` window:

```
chip 0 centre: hit=PlatformGroupContainer mouseDownCanMoveWindow=true
chip 2 centre: hit=PlatformGroupContainer mouseDownCanMoveWindow=true
chain: PlatformGroupContainer < DocumentView < NSClipView < HostingScrollView
       < PlatformContainer < AppKitWindowHostingView < NSThemeFrame   (all true)
```

The window server therefore owns the mouse stream before `TabReorderMonitor`'s pan
recognizer reaches its six-point threshold. A press that never travels is still delivered,
which is why clicking a tab still selects it.

Two things this rules out, both measured:

- `window.isMovable = false` does **not** close this path. It survives in the live window
  (probe read it back `false` at t+0.2 … t+3.0 s), it is in the running build (the binary
  carries `TabReorderMonitor` symbols, and both edits predate the 10:13 install), and the
  window still moves.
- A representable in `.background` cannot take the press: SwiftUI resolves the point to the
  chip and returns its own container. Probed both ways — `.background` → `PlatformGroupContainer`,
  `.overlay` returning `self` → `SurfaceView, mouseDownCanMoveWindow=false`.

## Second report: "not work, now the + does not press either" (17:2x)

Against the build installed at 17:22 over `/Applications/Tenon.app` (which carries
`TabStripSurface`). The `+` was inside the same `HStack` the surface covered, so the surface
answered for it and the button heard nothing. That is a defect the classification below
should have prevented: taking the pointer means owning every meaning of it, so the surface
must be drawn over exactly the region whose meanings it implements — the chips — and stop
there.

The report also broke the deadlock in evidence. Three measurements followed, and two of them
overturned earlier conclusions of mine:

1. **Hit-testing is right, including inside `ScrollView`.** A probe built the same way the
   strip is built resolves every point on the chips to `SurfaceView`,
   `mouseDownCanMoveWindow=false`, while identity/`+`/quick commands resolve to SwiftUI.
2. **Synthetic events do reach views** — `window.sendEvent` delivers `down`, nine `dragged`,
   and `up` to the surface, through the scroll view. The earlier reading ("`downs=0`, no
   headless seam exists for delivery") was wrong, and that wrong reading is what left two
   fixes resting on a human report.
3. So the whole gesture is now a test:
   `testARealPressAndDragOnTheStripMovesTheTabItStartedOn` mounts the shipped `ShellTitleBar`
   over a real `WorkspaceStore` in a real hidden-titlebar window, presses inside the first
   chip, drags to the end of the strip, releases — and asserts the workspace's tab order
   changed. It passes.

That test also found a crash the earlier design carried: `dismantleNSView` → `abandonDrag()`
wrote `@State` from inside `GraphHost.invalidate()`, which is a fatal exclusivity violation,
not a late update. Every teardown of the strip mid-hover hit it. The release now lands on the
next turn of the run loop.

## Fix — first attempt, and why it failed

The strip got an AppKit surface in `.overlay` that answered `mouseDownCanMoveWindow` with
`false`, but claimed the point **only while a primary-button event was dispatching**
(`NSApplication.shared.currentEvent?.type`). Shipped to staging; the user dragged; the window
still moved.

The lesson is exact: a view that is not the hit-test result at *every* moment is not the
hit-test result at whichever moment macOS uses to decide that the band under the pointer
belongs to the window server. Half-ownership of a region is no ownership.

## Fix — what the row does now

The title bar's four zones each state who owns their pointer, in `ShellTitleBar`'s own
documentation, because the classification is a property of the views and nothing else
records it:

| Zone | Owner | A drag there |
|---|---|---|
| the chips | `TabStripSurface` — one AppKit view over the chips, and nothing else | reorders the tab |
| empty chrome | `WindowDragArea` — `performDrag`, so double-click still zooms | moves the window |
| identity (icon, wordmark, unseen count, sidebar toggle) | SwiftUI | moves the window |
| the `+` launcher | SwiftUI | moves the window |
| quick commands | SwiftUI | moves the window |

The last three are a decision, not an omission: they are chrome carrying a control, and
dragging chrome is what a title bar is for. The chips are the one zone where that default is
wrong, so they take the pointer away from the window server **unconditionally** — and pay for
what they took:

- press that travels six points → reorder (T-096's rules, untouched);
- press that does not → `TabReorder.press` resolves select-or-close against the close
  control's *reported* extent, so no layout is restated anywhere;
- pointer at rest → the surface reports which chip is under it and the chip lights from that,
  because a chip inside the band cannot notice a pointer that never reaches it;
- secondary click and accessibility are untouched: `RightClickCatcher` watches the event
  stream through a local monitor rather than hit-testing, and the surface is invisible to
  assistive technology (`isAccessibilityElement() == false`, `accessibilityHitTest` → nil).

## What headless evidence can and cannot reach

The hit-test contract is assertable and asserted, and this time the *composition* is too:
`testAChipCentreHitTestsToTheStripSurfaceInsideARealTitleBarWindow` mounts the shipped chips
in a real hidden-titlebar window, finds the shipped surface, proves it spans the chips, and
asserts that the centre of the strip hit-tests to it with `mouseDownCanMoveWindow == false`.
**That test fails for the first attempt** — with no event in flight the gated version returned
`nil` — so the regression now has a headless seam instead of only a human one.

Delivery *inside the app* is now asserted too, and that is new:
`testARealPressAndDragOnTheStripMovesTheTabItStartedOn` drives `NSWindow.sendEvent` — AppKit's
own entry point for a press — through the shipped bar and asks the workspace whether the tab
moved. The claim it replaces ("synthetic events never arrive, measured `downs=0`") was simply
wrong; the events had been built without a valid `windowNumber` against a window that was
never key.

What remains out of reach is the **window server**: whether macOS hands a *hardware* press to
that view instead of starting a window move before the app sees anything. This process holds
no Accessibility grant to post real events, and
`testDraggingATabReordersItWithoutMovingTheWindow` — the XCUITest — passed against the
mechanism the user's hands falsified, so it is not evidence either. That single question is
what a human drag answers, and it is the only one left.

## Criteria
- [x] Dragging a tab reorders it and the window frame does not change — **accepted by the user**
      on the staging build of 2026-08-10 09:29 ("kéo thả ok rồi, tab có thay đổi"), after the
      `acceptsFirstResponder` override was removed.
      The earlier acceptance on the 19:16 build of 2026-08-09 ("work rất tốt") was real but did
      not describe what shipped: the override was added between that build and the installed
      one, and it put every chip back under the window server. An acceptance names a binary,
      not a tree — that is why the receipts now record which binary each one was given against.
- [x] The `+` opens the launcher — it is outside the surface, and a test holds it there
- [x] The strip never takes the keyboard from the terminal — `NSControl` accepts first
      responder where `NSView` does not, so the surface hands that part back
- [x] Clicking a tab still selects it; clicking ✕ still closes it — driven through
      `NSWindow.sendEvent` on the shipped bar, asserted against the workspace
- [x] Hover ends when the pointer leaves, so no chip stays lit behind a pointer that has gone
- [x] Tearing the strip down mid-hover defers its release out of SwiftUI's teardown — asserted
      on *when*, not merely that
- [ ] Right-click still opens the tab launcher — `RightClickCatcher` declines the left-mouse
      hit (asserted), but the launcher opening is not driven end to end
- [ ] Dragging the empty title bar still moves the window, double-click still zooms — the
      region oracle proves the chrome stayed inside the drag region, which is the mechanism;
      the gesture itself is XCUITest-only and that target needs an app host
- [ ] VoiceOver move actions and spoken position unchanged
- [x] A press-and-drag driven through `NSWindow.sendEvent` on the shipped bar moves the tab
- [x] Tearing the strip down mid-hover no longer writes `@State` inside SwiftUI's teardown
- [x] `swift test` green — full suite **1696 / 0** at 12:1x
- [x] PRD-002 delivery matrix, risk, decision log, and receipts corrected; catalog row updated

## Third report: the window still moves (2026-08-10 02:0x)

User, against the running build — pid 98322, `/Applications/Tenon.app`, installed 20:49 on
2026-08-09, started 21:06. Dragging a chip **moves the whole window**; the reorder never
starts. Same symptom the `NSControl` change was accepted for at 19:16.

Measured before touching anything, so the fix is not what is missing:

| Question | Answer | How |
|---|---|---|
| Does the AppKit rule still hold on this macOS? | yes, exit 0 | `swift scripts/drag-region-probe.swift` |
| Is the source still a control? | yes | `ShellTitleBar.swift:945` `final class SurfaceView: NSControl` |
| Is the suite green? | 14 / 0 | `swift test --filter TabStripReorderTests` |
| Does the *running binary* carry it? | yes | `otool -oV /Applications/Tenon.app/…/Tenon` → `_TtCV8TenonApp15TabStripSurface11SurfaceView`, `superclass _OBJC_CLASS_$_NSControl` |

So the shipped build has the fix and the symptom survives it.

**The seam that was supposed to catch this measures nothing.**
`testTheChipsAreOutsideTheDragRegionTheWindowServerMovesTheWindowFrom`
(`TabStripReorderTests.swift:317`) computes `region`, asserts the chrome oracle, and then
asserts `TabStripSurface.SurfaceView.isSubclass(of: NSControl.self)` — a **type check** under
a measurement's name. The chips' rect is never compared against the region. The board line
claiming it "asserts a chip's centre is outside it" was describing a test that does not exist,
which is how a green suite and a moving window coexisted a second time.

## Root cause of the third report — the rule has a second axis

`acceptsFirstResponder = false`, added beside the `NSControl` change to hand the keyboard back
to the terminal, **puts the control back inside the drag region**. The region builder carves
out a control that accepts first responder and leaves one that refuses. Varying only the
responder overrides on the same window, same oracle:

```
NSControl, mouseDownCanMoveWindow=false only : covered=false   ← outside the region
+ acceptsFirstResponder = false              : covered=TRUE    ← back inside it
+ acceptsFirstMouse = true                   : covered=false   ← irrelevant
what TabStripSurface.SurfaceView shipped     : covered=TRUE    ← the user's symptom
```

**The premise under that override was never true.** Probed directly: with the property left
alone, a press driven at the surface leaves a first-responder-holding stand-in still holding
first responder. AppKit focuses no view on a press by itself — only a control that calls
`makeFirstResponder` from its own mouse path, and `SurfaceView.mouseDown` never calls `super`.
So the fix is to **delete the override**; the keyboard stays where it was for a different
reason than the one assumed, and that reason is now what the test asserts.

## Why the suite could not see it, twice

Two independent blindnesses, both now closed:

1. **The region test asserted a type, not a region.**
   `testTheChipsAreOutsideTheDragRegionTheWindowServerMovesTheWindowFrom` computed `region`,
   checked the chrome oracle, then asserted `SurfaceView.isSubclass(of: NSControl.self)`. The
   chips' rect was never compared to anything. It now measures the shipped surface.

2. **The harness never put the strip in the title-bar band.** `.ignoresSafeArea(.container,
   edges: .top)` inside the hosting view does not reach it: measured through the surface's own
   frame, the strip sat at `y 212…238` while the region ends at `268` — 62pt below the band,
   so *any* question this file asked about the band was answered about empty content. `mount`
   now pins the row to the top of the window at `TenonTheme.titleBarHeight`, and the region
   test carries a third oracle that fails if it ever drifts back down.

With both closed the test failed first — strip at `y 253…279` intersecting region rect
`(3, 268, 894, 9)` — which is the first time the suite has reproduced this defect at all.

`scripts/drag-region-probe.swift` had the same false comfort: its `ProbeControl` carried no
responder override, so it measured a control the app no longer resembled and kept reporting
that the rule held. It now runs both axes and prints all three outcomes.

## Sharper report from the user, 09:2x — the region is time-varying

Against the same unfixed production build, the failure is not uniform:

- click a chip, release, **leave the pointer where it is**, then press and drag → **reorders**
- press and drag straight away, without that preceding click → **the window moves**
- release, move the pointer somewhere else, press and drag → **the window moves**

The most likely reading, and it is **MEDIUM until a hand confirms it**: AppKit invalidates the
window's drag region whenever the view tree changes and re-uploads it a moment later. A click
selects a tab, SwiftUI rebuilds the strip, and for the instant before the new region reaches
the window server there is no region there to take the press — so the app gets it and the
reorder runs. Moving the pointer fires `hovered`, which rebuilds and re-uploads a region that
(with the override in place) covers the chips again, and the server resumes taking presses.

This is consistent with the measured root cause rather than a separate defect: a region that
*permanently* excludes the chips has no window in which the answer can differ. What it does
say is that the fix has to be checked with **all three** gestures, because the first one
already appeared to work before it.

## The diagnosis, read off the two binaries

```
nm -a … | rg 'TabStripSurfaceV0E4ViewC[0-9]+(acceptsFirstResponder|mouseDownCanMoveWindow)'

/Applications/Tenon.app        (the build the user dragged)  → acceptsFirstResponder, mouseDownCanMoveWindow
/Applications/Tenon Staging.app (rebuilt from this fix)      → mouseDownCanMoveWindow
```

The override the user's window moves from is present in the exact binary the report was
filed against, and absent from the one to be tested.

## Third blindness, in a different file

`InteractionBoundaryFitnessTests` line 655 *required* the override:

```swift
XCTAssertTrue(titleBar.contains("override var acceptsFirstResponder: Bool { false }"),
              "and the strip must hand back the keyboard focus NSControl would otherwise take")
```

So the tree carried a fitness test demanding the defect. It now asserts the opposite — no
`acceptsFirstResponder` override at all — plus `canBecomeKeyView: Bool { false }`, which was
measured on the same oracle and leaves the view outside the region, so the strip stays out of
the Tab key-view loop without paying for it.

## Owner / files (agent lock)

Claimed 2026-08-10 02:1x by session `f673eeeb`:

- `Sources/TenonApp/ShellTitleBar.swift`
- `Tests/TenonAppStateTests/TabStripReorderTests.swift`
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` (the tab-strip block only)
- `scripts/drag-region-probe.swift`
- `docs/prds/command-surfaces.prd.md` (decision log + receipts rows only)

Previously released 2026-08-09 19:3x by session `aae57603`; the work below is uncommitted.
