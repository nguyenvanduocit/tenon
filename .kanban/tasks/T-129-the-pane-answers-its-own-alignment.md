# T-129: The pane answers its own alignment
> `AgentSessionLayout` leaves `explicitAlignment` to the default, and the default answers by
> placing the whole transcript. A live sample of the hung app puts 1409 of 7457 main-thread
> samples in exactly that answer.

- **priority**: critical
- **effort**: M
- **prd**: `TENON-PRD-012` (`docs/prds/agent-lens.prd.md`)

## Owner / files (agent lock)
Session `9fe92d11`, claimed 2026-08-11 16:0x.

- `Sources/TenonApp/AgentLensView.swift` — `AgentSessionLayout` only
- `Tests/TenonAppStateTests/AgentSessionLayoutAlignmentTests.swift`
- `docs/design-pane-hosting.md`

T-127 released these at 14:2x. The three tasks still shown in `Doing` (T-120, T-123, T-124)
lost their sessions at 10:43 and are marked stale on the board; none of them names these files.

## The mechanism, from a live sample rather than a fixture

`sample` of PID 11917 taken 2026-08-11 15:5x while the app was hung — 97.6% CPU, RSS 77 MB,
which is far earlier in the hang than either previous capture. Main thread, 7457 samples:

```
_FlexFrameLayout.placement(of:in:)                     1465
 └ FrameLayoutCommon.commonPlacement                   1449
   └ ViewDimensions.subscript.getter                   1449   ← the frame asks for a guide
     └ LayoutEngineBox.explicitAlignment               1449
       └ UnaryLayoutEngine.childPlacement              1443   ← the answer re-enters placement
         └ _FlexFrameLayout.placement                  1441
           └ ViewDimensions.subscript.getter           1421
             └ Layout.explicitAlignment … in conformance AgentSessionLayout   1409
               └ static ViewLayoutEngine.defaultAlignment                     1406
                 └ ViewLayoutEngine.childGeometries                           1404
                   └ AgentSessionLayout.placeSubviews  1390   ← places the whole ScrollView
```

`rg -n "explicitAlignment" Sources/` returns nothing: `AgentSessionLayout`
(`AgentLensView.swift:362`) implements `sizeThatFits` and `placeSubviews` and leaves the
alignment requirement to the protocol's default. For a custom `Layout` that default is not a
cheap read of the layout's size — the sample shows it routed through `defaultAlignment` →
`childGeometries` → the layout's own `placeSubviews`, and `placeSubviews:398` places the
account content, which is the `ScrollView`/`LazyVStack` holding the transcript.

The second hot branch is the bill for it: `LazySubviewPlacements.updateValue` (1732) →
`LazyStack.place` → `_ViewList_Node.applyNodes` → `ForEachList.applyNodes` →
`DynamicViewList.WrappedList.applyNodes` recursing. That is list-node application over the
whole `ForEach`, not row measurement.

## Why T-127 recorded this hypothesis as dead

T-127 tested it and wrote it up as refuted, keeping
`testAnsweringAlignmentDirectlyChangesNothing` executable with the note "anyone reaching for
this override again should first make this test show a difference." Two things in that fixture
made a difference impossible to see:

1. **The control returns `nil`.** `AlignmentAnsweringLayout.explicitAlignment`
   (`AgentSessionLayoutAlignmentTests.swift:487, :497`) answers `nil` for both axes, and `nil`
   is the protocol's way of saying "I have no explicit guide — use the default". So the control
   and the production type take the same expensive path. Measuring them equal was correct and
   meant nothing.
2. **The counter counts the wrong verb.** `CountingRow` increments only in `sizeThatFits`
   (`:407`). Sizes are cached — T-127 measured the cache hitting — while the sample's cost is
   in `applyNodes`/`place`. A fixture can hold row *measurements* flat while row *placements*
   multiply.

T-127's own conclusion is what makes this reopening legitimate rather than a re-litigation:
"an offscreen `NSHostingView` fixture cannot reproduce this. Sample the real process; build a
fixture only to test a mechanism the sample has already named." The sample has now named one.

## Criteria
- [x] `CountingRow` counts placements as well as measurements, and the existing tests keep
      asserting what they asserted before.
- [x] The control answers alignment with a real value derived from `bounds` alone, so the
      comparison is between an answered guide and a computed one rather than between two
      spellings of the default.
- [x] `AgentSessionLayout` answers `explicitAlignment` on both axes from `bounds` without
      placing or measuring any subview — `testEveryBoxGuideIsAnsweredFromTheBoundsAlone`.
- [x] The fixture's verdict is recorded honestly rather than argued away.
- [ ] **NOT DONE — the user chose not to spend a rebuild on it.** The reading it draws is
      unchanged, photographed at both pane widths.
- [ ] **NOT DONE — same decision.** Verified on the running app by a second `sample`. The fix
      is landed on the evidence of two samples of the *unfixed* app; nobody has yet sampled a
      *fixed* one. Whoever next reproduces the hang should sample first and check whether the
      `explicitAlignment` branch is absent, the way T-121's fix was confirmed absent from
      `hang2.txt`. Until then this is a mechanism removed, not a hang cured.

## What the fixture could and could not settle

The differential test this task set out to write **cannot be written**, and finding that out is
part of the result. With the control answering in numbers rather than `nil`, the fixture asks
**8 alignment questions**, all 8 reach the override, and the row counts stay **16 either way**
— measurements and placements both. Offscreen, the default path's `placeSubviews` hits the size
cache, so removing it saves nothing there. T-127 measured 534 of 534 lookups *missing* in the
hung process, which is why the same code is free in a fixture and ruinous in the app.

So the assertion that shipped is the one a fixture can prove — every box guide is answered from
`bounds`, so the default is never reached for it — and
`testAnsweringAlignmentOffscreenChangesNeitherCount` keeps the offscreen equality executable as
a tripwire rather than as a verdict.

## Two samples, twenty minutes apart

PID 11917, hung from ~15:41, still spinning at 16:17. Unlike every earlier capture the
footprint does **not** climb — RSS 77 MB → 61 MB across the two samples, against 2.8 GB and
+500 MB/min in the T-121/T-127 hangs. This one is a pure CPU cycle with no allocation growth,
which is what a repeated layout with no attributed-string minting looks like.

| Frame | 15:5x (of 7457) | 16:1x (of 5715) |
|---|---|---|
| `LazySubviewPlacements.updateValue` | 1732 · 23.2% | 1107 · 19.4% |
| `explicitAlignment … in conformance AgentSessionLayout` | 1409 · 18.9% | 1014 · 17.7% |
| `AgentSessionLayout.placeSubviews` | 1390 · 18.6% | 994 · 17.4% |
| `AgentSessionLayout.sizeThatFits` | 3 · 0.0% | 7 · 0.1% |

The load-bearing number is the third row against the second: **1390 of 1409, and 994 of 1014.**
`placeSubviews` is reached almost only through `explicitAlignment`. The pane places its whole
transcript to answer alignment guides, not to draw anything — and `sizeThatFits`, the honest
reason to place, accounts for 0.1%.

## Non-goals
- The remaining hang, if this is not all of it. The sample's other branch
  (`LazySubviewPlacements`) is measured here but not touched.
- `.textSelection`, footer jitter, and anchored placement: T-127 killed all three with
  measurements, and nothing in this sample revives them.

## Status at hand-off

Landed and green, verified as far as a headless suite can verify it, and **not confirmed on a
running app**. The 20% branch it removes is measured in two samples of the hung process; the
remaining ~20% (`LazySubviewPlacements.updateValue`) is untouched and may be enough to hang on
its own.

Suite at 16:2x: **1927 tests, 11 failures, none in this task's scope** —
`AgentReadingOptionsTests` (8, T-123), `InteractionBoundaryFitnessTests` (2, T-124's
`PaletteRowChrome`), `AgentTranscriptPathTests` (1, T-126). All three owning sessions are dead
and their work is uncommitted. `AgentSessionLayoutAlignmentTests` **9 / 0**.
