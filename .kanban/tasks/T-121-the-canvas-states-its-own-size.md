# T-121: The canvas states its own size
> `SpatialCanvasView` declares no `sizeThatFits`, so every measurement of the stage runs an
> AppKit Auto Layout fitting-size sweep over the whole card tree — 69% of the CPU in a
> reproduced hang.

- **priority**: critical
- **effort**: S

## Owner / files (agent lock)
**RELEASED 2026-08-11 09:1x, session `75a73283`.** All free:
`Sources/TenonApp/Canvas/SpatialCanvasRepresentable.swift`,
`Tests/TenonAppStateTests/PaneHostingSizingTests.swift`,
`docs/prds/spatial-panes.prd.md`, `docs/prds/spatial-panes.feature`.

## The measurement

A live hang, reproduced by the user: an agent ran a long time in a terminal pane with Agent
Lens closed; opening Agent Lens froze the app. PID 24393, `sample` taken while stalled, plus
the app's own incident record at
`~/Library/Application Support/Tenon/diagnostics/incidents/2cb0ff1f-…/0001-ded16be7/`.

`beatSequence` stayed at 3147538 for the whole incident — the main runloop never completed a
single turn in over five minutes — while footprint climbed 550 → 2810 MB at ~500 MB/min and
CPU held 100%. It does not recover; the process was force-quit with the user's consent.

The stack names one shape, and it accounts for **2395 of 3461 main-thread samples (69%)**:

```
_ZStackLayout.sizeThatFits                  ← WorkspaceStageView.swift:36
 → LayoutProxy.dimensions(in:)
   → PlatformViewLayoutEngine.sizeThatFits  ← SpatialCanvasView (NSViewRepresentable)
     → ViewLeafView.layoutTraits()
       → AppKitPlatformViewHost.fittingSize
         → -[NSView systemLayoutSizeFittingSize:withHorizontalFittingPriority:…]
           → -[NSISEngine withBehaviors:performModifications:]
             → _populateEngineWithConstraintsForViewSubtree:   (12+ levels deep)
```

The `ZStack` at `WorkspaceStageView.swift:36` carries no
`.frame(maxWidth: .infinity, maxHeight: .infinity)`, so it must ask its child for an ideal
size. `SpatialCanvasView` answers nothing — `SpatialCanvasRepresentable.swift` declares only
`makeNSView`/`updateNSView`/`dismantleNSView` — so SwiftUI falls through to AppKit and asks
Auto Layout to compute a fitting size, which walks every card, every `NSHostingView` and
every `NSTextField` under the canvas. The walk itself dirties what it measures:
`-[NSTextFieldCell _invalidateEffectiveFont]` (92 samples) and
`-[NSTextField invalidateIntrinsicContentSize]` (26) sit inside the measuring pass.

Feeding it, under the same `AG::Graph::UpdateStack::update()`, is the lazy list T-091 named:
`LazySubviewPlacements.updateValue()` (981) → `LazyLayoutViewCache.updatePrefetchPhases()`
(453), whose `Update.Action` buffer is appended to non-uniquely, so
`_ArrayBuffer._consumeAndCreateNew(…growForAppend:)` copies the whole array on every append
(224 of its 232 samples) — the O(n²) that spends the memory.

Why the user's scenario is the trigger: the incident's `transitions.jsonl` records three
Agent Lens panes at 131 / 177 / … timeline items publishing snapshots about once a second.
That is the point where one fitting-size sweep can no longer finish before the next
invalidation arrives.

## Why T-091's fix did not reach it

T-091 set `PaneContentHost.sizingOptions = []` so a pane's own hosting view publishes no
intrinsic size, and added `LazyListSizingFitnessTests`. That fitness test scans for
`ZStack(` followed by a `ScrollView` within 40 lines. The stage writes `ZStack {`, and its
child is an `NSViewRepresentable` rather than a `ScrollView`, so the rule cannot see the
one shape that actually hung. `PaneHostingSizingTests` says of itself: *"This test does not
claim to prevent that loop; the reproduction is still open."* This task closes it.

## What the fix is

`SpatialCanvasView.sizeThatFits` returns the proposal. Silence was never neutral — it routed
the question to AppKit — so the canvas now says the only true thing about its size: it takes
what the stage gives it.

The measurement that separates this from a guess is in `PaneHostingSizingTests`, and it is
built as a control pair rather than an assertion about source: a representable declaring no
size is asked through Auto Layout (`intrinsicContentSize` queried), one declaring it is asked
**zero** times. Both were green on the first run, which is what makes the third test — the
production pin, red before the change — mean something.

The risk the fix introduces is that proposing nothing becomes occupying nothing.
`ContentView.swift:99` is exactly the `.frame(maxWidth: .infinity, maxHeight: .infinity)` at
the top of the hung stack, so `testAnsweringZeroIdealStillFillsTheStage` rebuilds that shape —
infinite frame, 1 pt rule, status bar — and measures that the canvas still receives every
remaining point.

## Observed, not acted on

Seven other `NSViewRepresentable`s in `Sources/TenonApp` declare no `sizeThatFits`:
`WindowChrome`/`WindowDragArea`, `WebPreviewSlotView`, `RightClickCatcher`/`TabStripSurface`,
`TenonScrollbarConfigurator`, `WebSurfaceView`, `GhosttyRepresentable`, `WindowFrameReporter`.
Only `SourceEditorView` did before this change. None of them is visible in the hung sample,
and the pane hosts around them already publish no sizing options, so nothing here justifies
touching them — but the terminal, the web surface and the file preview all sit inside pane
content, and the same question is being answered the same expensive way underneath them.
Worth a measurement of its own, not a speculative sweep.

## Criteria
- [x] A representable that declares no `sizeThatFits` is shown, by measurement rather than
      by assertion about source, to make an enclosing `ZStack` ask AppKit for a fitting size;
      one that declares it does not. — the control pair, both green on first run.
- [x] `SpatialCanvasView` declares `sizeThatFits` and returns the proposal.
- [x] The new assertions are red before the change and green after — the production pin was
      red at `PaneHostingSizingTests.swift:116`; `PaneHostingSizingTests` is now 7 / 0.
- [x] `swift test` full suite green: **1879 / 0** in 109.7 s.
- [x] `docs/prds/spatial-panes.prd.md` carries `SP-FR-027`, the delivery row, the decision, and
      a dated receipt; `.feature` carries two scenarios.
- [x] T-091's open reproduction is answered: reproduced, sampled, root cause named and fixed.
      What is NOT closed is stated below.

## Not verified

The fix has not been observed in a running app. Installing over the running Tenon replaces
the bundle every other session's panes live in, and the machine currently has agents working
in it — so the fix is proven offscreen and by the sample's own arithmetic, never by watching
the app stay responsive with three Agent Lens panes open. **The user's installed
`/Applications/Tenon.app` 0.1.0 still carries the defect until it is rebuilt.**

`SP-NFR-012` still holds and this task does not weaken it: a green harness is not a
reproduced fix. What changed is that the incident itself is now reproduced and sampled, so
the root cause rests on a measurement rather than on a shape argument. The remaining claim —
that removing the 69% branch is enough to make the loop converge — is inference from the
sample, not an observation of the app recovering.
