# T-127: What the samples ruled out, and the waste they found on the way
> The hang survived T-121. Three candidate mechanisms were measured and all three failed to
> reproduce; three unrelated CPU defects were confirmed and fixed.

- **priority**: critical
- **effort**: L

## Owner / files (agent lock)
Session `75a73283`.

- `Sources/TenonApp/AgentLensSources.swift`
- `Sources/TenonApp/AgentMilestoneSpan.swift` (new)
- `Sources/TenonApp/AgentTimelineView.swift`
- `Sources/TenonApp/Canvas/SpatialSlotCardView.swift`
- `Tests/TenonAppStateTests/AgentSessionLayoutAlignmentTests.swift` (new)
- `Tests/TenonAppStateTests/TextSelectionLayoutTests.swift` (new)
- `Tests/TenonAppStateTests/AgentMilestoneSpanTests.swift` (new)
- `Tests/TenonAppStateTests/SlotAccessibilityValueTests.swift`
- `Tests/TenonAppStateTests/AgentLensTests.swift`
- `docs/design-pane-hosting.md`, `docs/README.md`

## The hang is still open, and this is what it is not

The user reproduced it twice on the installed build. The second reproduction ran **with**
T-121's fix, and the sample proves the fix works: `AppKitPlatformViewHost.fittingSize` and
`_populateEngineWithConstraintsForViewSubtree` are **absent** from `hang2.txt`, where they had
been 2395 of 3461 samples. The remaining hang has the same signature — `beatSequence` frozen
at 1519664, CPU 100%, footprint climbing — and a different shape.

A nine-lens audit of the whole app produced three candidate mechanisms. **Each came with a
test that would separate it, and all three tests came back negative.** Measured, not argued:

| Candidate | Claim | Measurement | Verdict |
|---|---|---|---|
| A2 | footer height jitters, so the ScrollView's size-cache key never repeats (534/534 lookups inside `makeValue`) | a footer drifting 0.4 pt costs the same row measurements as a steady one, over two settled passes, with the fixture's own jitter asserted | **dead** |
| A1 | `.textSelection(.enabled)` mounts an `NSTextField` whose `updateNSView` invalidates intrinsic size — a mutation inside an update | selectable prose leaves `needsLayout` exactly as plain prose does, and the fixture verifiably mounts the extra `NSTextField` | **dead** |
| A3 | `place(at:anchor:)` resolves the anchor by measuring, so the lazy content is measured on every placement | four placements at identical bounds cost exactly one placement's row measurements | **dead** |

A1's death is the one worth stating plainly: it would have removed selectable text from nine
sites, and selection is a real affordance under VISION.md's evidence-linked compression tenet.
The measurement bought that back.

**A3's contradiction is real even though its fix is not needed.** `place(at:anchor:)` does
resolve the anchor through `LayoutProxy.dimensions`, so the comment at `AgentLensView.swift:479-482`
— "neither a ZStack nor an ordinary StackLayout can ask the lazy content for an ideal size
during the host's pass" — states a conclusion the profiler disproves. What makes it survivable
is that the cache hits. The comment is left for whoever takes the hang next, because correcting
it means editing `AgentLensView.swift` on a claim this task did not act on.

## What reconstruction cannot do

Counting T-091's five, this investigation has now failed to reproduce the loop **ten times**,
each fixture closer to production than the last: `AgentSessionLayout` over a real
`ScrollView`/`LazyVStack`, 160 rows, ragged row heights, a real `TextField` composer, and the
reading column copied modifier for modifier from `AgentLensView.swift:525-528`. Row
measurements tracked the viewport every time.

The conclusion is about method, and it is in `docs/design-pane-hosting.md` so the next session
does not spend a day rediscovering it: **an offscreen `NSHostingView` fixture cannot reproduce
this.** The dynamic half is missing — snapshots arriving about once a second per pane,
`scrollTo` running against arriving content, wrapped `Text` whose height depends on the width
being negotiated. Sample the real process; build a fixture only to test a mechanism the sample
has already named.

## Fixed on the way — three confirmed defects, none of them the hang

- **`/bin/ps` forked per pane every 750 ms, forever.** `resolve` derived the provider verdict on
  every discovery tick, and deriving it means `proc_pidpath` plus a blocking `/bin/ps` fork.
  `stop()` is reached only from `AgentLensPool.retainOnly`, so a pane in a background workspace
  kept paying. The verdict is a property of the foreground process and is now derived exactly
  when that process changes, one entry per surface, bounded at 128.
  Red first: three resolutions of one unchanged terminal derived it 3 times.
- **Accessibility strings rebuilt on every pointer event.** `applyFrames` calls
  `updateAccessibilityValue` for every displayed card — from `layout()`, from every `configure`,
  and from `drag(to:)` on every `.leftMouseDragged`. Unlike the `card.frame` assignment beside
  it, which AppKit short-circuits, this did a UUID interpolation and one or two
  `String(localized:)` lookups every time. Both strings are pure functions of the rect, so the
  guard is exact. This is the one finding a person could feel, as stutter during a resize drag.
- **A `DateFormatter` per milestone row per body pass.** Construction dominates its own use by
  roughly 60×, and `metadata` read `span` twice inside a `ViewThatFits`. Now one shared
  formatter behind `AgentMilestoneSpan`, read once per body.

**Deliberately not fixed: `AgentTimelineDigest.insufficiency`** materializes and double-sorts
the session inside a view body to choose between two sentences. It is genuine redundancy, but
it is sub-millisecond, off by default, and `AgentTimelineDigest.swift` is dirty with another
task's unfinished timeline work in exactly that region. Lowest value, highest collision risk.

## Criteria
- [x] Each hang candidate is settled by a measurement rather than by reading a stack.
- [x] Every new assertion is red before its change and green after, or is a control whose
      fixture is itself asserted.
- [x] The three confirmed defects are fixed with tests.
- [x] What reconstruction cannot do is written down where the next session will read it.
- [ ] The hang itself. Still open, with instrumentation as the recommended next move: the app
      already records `transitions.jsonl` at a stall, and what it does not record is which pane
      was drawing and how many passes it had run.
