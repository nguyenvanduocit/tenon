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

## The rule, stated so it can be applied elsewhere

**Every boundary that can be asked for a size must answer it directly, because the fallback
answer is a full measurement of everything below.** Silence is not neutrality. Three
mechanisms turn one unanswered question into unbounded work, and this repository has hit all
three:

| Boundary | If it stays silent | Answer it with |
|---|---|---|
| `NSViewRepresentable` | SwiftUI asks AppKit, which runs `systemLayoutSizeFittingSize:` and walks the entire `NSView` subtree through `NSISEngine` | `sizeThatFits(_:nsView:context:)` returning the proposal |
| `NSHostingView` in AppKit | AppKit derives the frame from SwiftUI content, measuring scrolling rows nobody will see | `sizingOptions = []` |
| A container around lazy content | The container asks the `ScrollView` for an ideal size, which measures the whole list | an exact viewport, as `AgentSessionLayout` gives the account |

A fourth mechanism makes the others self-sustaining rather than merely slow: **measuring can
mutate.** `NSTextField` runs `_invalidateEffectiveFont` and `invalidateIntrinsicContentSize`
while being measured, so a sweep that walks text fields dirties the very pass that walked
them. That is the difference between an expensive layout and one that never finishes.

## The three times this has happened

- **T-091** — the first sighting. `Update.dispatchActions()` was ~100%
  `LazyLayoutViewCache.signalPrefetch()`, re-arming the update it was dispatched from; 11 GB
  resident, 10.4 GB swapped. Five reconstructions of the hosting shape all converged in a
  standalone harness, so the cause was not found and the mitigation shipped without it:
  pane hosts stopped publishing sizing options.
- **T-121** — the first root cause, found by sampling a real hang rather than by
  reconstruction. `SpatialCanvasView` declared no `sizeThatFits`, so the `ZStack` at
  `WorkspaceStageView.swift:36` and the infinite frame at `ContentView.swift:99` routed the
  question to AppKit: `AppKitPlatformViewHost.fittingSize` →
  `_populateEngineWithConstraintsForViewSubtree`, twelve levels deep across every card,
  **2395 of 3461 main-thread samples**. The canvas now returns the proposal, and that branch
  is absent from later samples.
- **Still open** — the app hangs again after T-121, with the same signature and a different
  shape: `_FlexFrameLayout.sizeThatFits` (2188), `LazyStack.measureEstimates` (1020),
  `AgentSessionLayout.placeSubviews` (537). ~22 timeline items took over 60 s in one layout
  pass, so something re-enters rather than merely costing a lot.

## Diagnosing a stall

The app records its own incident, and that record is better evidence than anything
reconstructed afterwards.

1. `~/Library/Application Support/Tenon/diagnostics/health.jsonl`. A `stall` record whose
   `beatSequence` never advances means the main runloop has not completed one turn. Watch
   `footprintMB` across `stall-continues` records: a steady climb is an autorelease pool that
   is never drained, which is the same fact seen from the other side.
2. `diagnostics/incidents/<runID>/<incidentID>/` holds `sample.txt` **taken at the moment of
   the stall**, plus `transitions.jsonl` — the last 128 typed transitions, which is where pane
   count, timeline item counts and snapshot rate can be read off.
3. Read the sample as a tree, not as text. Parse the indentation, compute **self time** (a
   node's count minus the sum of its direct children), and follow the heaviest chain to the
   Tenon frames. Do not stop at the first plausible frame: in the 2026-08-11 sample the first
   `Lazy*` frame belonged to the 28% branch while the 69% branch was above it.
4. A hang is a cycle. Name the edge that closes it — a mutation performed inside a
   measurement, an action enqueued by the pass dispatching it — not merely the most expensive
   frame.

## Measured, and refuted

Both of these read as obvious fixes and neither is one. They are kept here because the cost of
proposing them again is a day.

- ~~**Overriding `explicitAlignment` on `AgentSessionLayout`.**~~ **Superseded 2026-08-11 by
  T-129 — the refutation was an artefact of its own control.** That control returned `nil` from
  both overrides, and `nil` is precisely how the protocol says "no explicit guide, use the
  default", so the comparison ran the expensive path against itself and equal counts were
  guaranteed. With a control that answers in numbers the override is verifiably reached — the
  fixture asks 8 alignment questions and all 8 are answered off `bounds` — and the offscreen
  counts still do not move, 16 either way, because the default path's `placeSubviews` hits the
  size cache there. What that measures is the fixture, not the app: the 15:5x sample of the
  hung process puts **1409 of 7457** main-thread samples inside `_FlexFrameLayout.placement` →
  `explicitAlignment` → `defaultAlignment` → `childGeometries` →
  `AgentSessionLayout.placeSubviews`, with the cache missing. The override shipped on the
  sample's evidence, and `testAnsweringAlignmentOffscreenChangesNeitherCount` keeps the
  offscreen equality executable as a tripwire.
- **Content-derived sizing as a sufficient cause of T-091.** Five reconstructions, including
  one nesting SwiftUI → AppKit → SwiftUI exactly as the canvas does, all converged.
- **Footer jitter missing the ScrollView's size cache.** `placeSubviews` derives
  `contentHeight = bounds.height - footerHeight` and places the account at it, so that value is
  the cache key — and the hung sample shows **534 of 534 lookups inside `makeValue`**, every one
  a miss. A footer drifting by 0.4 pt across two settled passes costs exactly the same row
  measurements as a steady one. The fixture asserts its own jitter, so the negative is real.
- **`.textSelection(.enabled)` re-arming the pass that draws it.** Its macOS backing invalidates
  intrinsic content size from inside `updateNSView`, which is a mutation inside an update.
  Selectable prose nonetheless leaves `needsLayout` exactly as plain prose does, at one element
  and at forty — and the fixture verifies that selection really does mount the extra
  `NSTextField`, so the comparison has something to compare. This one mattered: acting on it
  would have deleted selectable evidence from nine sites.
- **`place(at:anchor:)` re-measuring the lazy content on every placement.** The mechanism is
  real — anchor resolution calls `LayoutProxy.dimensions` even for `.topLeading` — but four
  placements at identical bounds cost exactly one placement's measurements, because the cache
  hits. Note that this makes the comment at `AgentLensView.swift:479-482` wrong on its
  conclusion while right on its premise.
- **Any static layout shape as a sufficient cause of the 2026-08-11 hang.** Five more
  reconstructions converged, each closer to production than the last: `AgentSessionLayout`
  over a real `ScrollView`/`LazyVStack`; 160 rows; rows of ragged height; a real `TextField`
  composer in the footer; and finally the reading column copied modifier for modifier from
  `AgentLensView.swift:525-528` — two paddings and two frames with non-default alignments,
  the exact `_FlexFrameLayout`/`_PaddingLayout` nest the sample shows. Row measurements
  tracked the viewport in every one of them.

**Reconstruction has now failed ten times across two investigations, and it is not the tool
for this.** A hang needs the dynamic half — snapshots arriving about once a second per pane,
`scrollTo` running against arriving content, real wrapped `Text` whose height depends on the
width being negotiated — and a fixture assembled by hand has none of it. Sample the real
process and read what it is doing; build a fixture only to test a mechanism the sample has
already named.

The lesson under all of it: **being expensive in a sample is not the same as being the
cause.** A frame's weight says where time went, not why the pass repeated.

T-129 adds the converse, which is the more expensive mistake: **a negative from a fixture is
only as strong as the control and the verb it counts.** Two failures compounded here for a
day. The control expressed "answers its own alignment" as `nil`, which is the same instruction
as "does not" — so it never varied the thing under test, and no assertion could have caught
that because both sides were correct. And the counter incremented in `sizeThatFits` only, while
the sample's second hot branch is `LazyStack.place` → `applyNodes` down the whole `ForEach` —
sizes are cached, placements are not, so a fixture can hold measurements flat while the list is
walked again. Before recording a refutation, assert that the fixture exercised the mechanism:
count the questions asked, not only the answers' cost.

## Test seams

- `PaneHostingSizingTests` — pane hosts publish no sizing options; the canvas answers the size
  it is proposed; a representable that answers nothing is measured through Auto Layout while
  one that answers is not; answering zero ideal still fills the stage.
- `LazyListSizingFitnessTests` — forbids `ZStack` → `ScrollView` → lazy container. Note its
  reach: it scans for `ZStack(` and a `ScrollView` within forty lines, so it cannot see
  `ZStack {` or a lazy list behind a representable — which is exactly the shape that hung in
  T-121.
- `AgentSessionLayoutAlignmentTests` — the row-measurement cost of one pane layout across list
  length, ragged row heights, the production reading column, footer jitter and repeated
  placements; plus the refuted alignment override. These are bounds worth keeping: they say the
  static shape is honest, so a future regression that makes layout cost track the list instead
  of the viewport turns them red.
- `TextSelectionLayoutTests` — whether selectable prose leaves a layout pending after a settled
  update, with a fixture check that `.textSelection(.enabled)` mounts its AppKit backing at all.
