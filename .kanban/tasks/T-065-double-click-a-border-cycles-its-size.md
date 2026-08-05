# T-065: Double-clicking a pane border cycles it through that border's sizes
> The border's right-click menu (T-064) names three sizes. A double-click on the same
> border should reach them without the menu: go Full, and once Full, keep stepping —
> 1/2, 1/3, back to Full — so the fastest resize is two clicks with no target to hit.
- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
Released — session 6b62625a finished 20:4x. No file is claimed by this task.

The `SpatialCanvasView.swift` overlap with T-059 landed clean again: T-059's territory
(`update`, `drag`, the preview-validity deletion) was already settled in the tree, and this
task's hunks are `SpatialCanvasPress`, `press(region:clickCount:)`,
`SpatialSlotCardView.mouseDown`, one callback property, and one line in `makeCard`.

## Decision
**The cycle is Full → 1/2 → 1/3 → Full**, stepping from whichever of the three the pane
currently sits on. A pane on none of them goes Full — that is the plain "double-click
makes it full" the user asked for, and every subsequent step is defined from there.

- **A destination the layout refuses is skipped, not attempted.** The cycle continues to
  the next size that yields a valid transaction, so a border never answers a double-click
  by doing nothing when some size was reachable.
- **The edge decides the axis**, identical to T-064: east/west → width, north/south →
  height, a corner → both, and a corner "sits on" a fraction only when both axes do.
- **`SpatialLayout.cycleExtent` is built from `resize(…, fraction:)`**, so the sizes a
  double-click reaches and the sizes the right-click menu lists are the same three by
  construction — one vocabulary, two ways to reach it.
- **A resize edge now answers a second click** instead of starting another drag. The rule
  the header already follows (a double-click means a size, not a gesture) becomes the
  rule for every region that owns a size.

## Consequence recorded, not hidden
The cycle position is read from the pane's current size, so it keeps no memory. That makes
every double-click deterministic and always visible, but it means a pane **already sitting
exactly on 1/2 steps to 1/3 rather than to Full** — the option's preview showed a
6-column pane going Full first, which only a remembered cycle position could deliver. The
option text the user chose says "each double-click steps to the next size", and a
remembered position would have to be stored per pane and per axis, survive restore, and go
stale whenever a drag resizes the pane behind its back. Stateless was taken; flagged to the
user in the same breath as delivery.

## Criteria
- [x] `SpatialLayout.cycleExtent` steps Full → 1/2 → 1/3 → Full on both axes and on
      corners, and sends a pane sitting on no fraction to Full — pinned headless
- [x] A step the layout refuses is skipped for the next valid one; a pane with no valid
      step yields an invalid transaction
- [x] `press(region:clickCount:)` answers a double-click on a border with its cycle and
      keeps the single click's drag — pinned headless
- [x] The double-click is wired through the card to `WorkspaceStore`
- [x] Full `swift test` green

## Evidence
- `swift build` clean; `swift test` **989 / 0** (was 982), re-run after the last edit.
- Five mutation proofs, each caught by a named test: cycle order swapped to 1/3-before-1/2
  (3 failures), the invalid step no longer skipped (4), a corner sized on one axis instead
  of both (4), an unsized pane starting at 1/2 instead of Full (4), and `press` answering
  a border double-click with `.begin` instead of the cycle (8). `SpatialLayout.swift`
  restored byte-identical via a `cmp`-checked backup; `SpatialCanvasView.swift` mutated and
  reverted by exact inverse in-place rewrite, never a whole-file restore, because peers
  hold that file.
- Not asserted: the AppKit seam from a real double-click to `onCycleExtent` — smoke-launch
  territory per `docs/tdd.md`; the rule it delegates to is pinned in
  `SpatialCanvasGestureTests`.
