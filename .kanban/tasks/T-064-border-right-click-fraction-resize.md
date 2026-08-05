# T-064: A pane border answers a right-click with the sizes you would drag it to
> Resizing a pane today costs a drag. The border already carries the resize cursor and
> the resize semantics; a right-click there offers the same resize as three exact
> destinations — 1/3, 1/2, full — so the common case is one gesture instead of a
> pixel-accurate drag.
- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
Released — session 6b62625a finished 20:1x. No file is claimed by this task.

The `SpatialCanvasView.swift` overlap with T-059 (session caa656c9) landed clean: this
task's four hunks (`SpatialSlotCardView.menu(for:)`, the new callback property, one line
in `makeCard`, the `resizeContextMenu` builder) and T-059's `update`/preview-validity
rewrite sit side by side in the working tree with no lost edits, confirmed by reading the
combined diff.

## Decision
The border's menu is the border's drag, expressed as three destinations.

- **The grabbed edge decides the axis.** East/west → width; north/south → height; a
  corner → both. This is the axis that edge already resizes under a drag.
- **The opposite edge stays fixed**, exactly as when dragging that edge. Right-clicking
  the east border and picking 1/2 keeps `x` and sets `width` to 6.
- **A fraction is of the canvas**, not of the pane's current size: 1/3 → 4 columns,
  1/2 → 6, full → 12, so "1/2" means the same size wherever the pane sits.
- **`SpatialLayout.resize(_:slotID:direction:fraction:)` converts the fraction to the
  delta that reaches it and calls the existing delta-based `resize`.** Neighbour
  coupling, detachment, clamping, and validity are inherited rather than re-derived —
  one typed implementation of "resize", two ways to name the destination.
- **A destination that changes nothing yields an invalid transaction**, matching
  `fillWidth`'s precedent, so the menu can disable it without diffing rects itself.

## Criteria
- [x] `SpatialLayout.resize(…, fraction:)` sets the grabbed edge to 1/3, 1/2, full with
      the opposite edge fixed, on both axes and on corners — pinned headless
- [x] It couples neighbours and refuses impossible destinations exactly as a drag does
- [x] A no-op destination and an unknown slot are invalid transactions
- [x] `SpatialCanvasInteractionCoordinator.menu(for:)` answers the resize menu on a
      border, the pane menu on the header, and nothing on the body — pinned headless
- [x] The border's contextual menu is wired, offers 1/3 · 1/2 · Full, and disables what
      the layout would refuse
- [x] Full `swift test` green

## Evidence
- `swift build` clean; `swift test` 982/982 green (60s), run after the last edit.
- Five mutation proofs, each caught by the new tests: dropping the west negation, dropping
  the north negation, removing the no-op guard, `oneThird` returning a half (2/2/2/6
  failures respectively), and `menu(for:)` answering `.pane` on a border (8 failures).
  Source restored byte-identical after each.
- Not asserted: the AppKit seam from a right-click's window coordinates to
  `onRequestResizeMenu`. Per `docs/tdd.md` that layer is smoke-launch territory — the
  routing rule it delegates to is pinned in `SpatialCanvasGestureTests`.

## Re-verification (session 55842f49, 20:3x)

A second session re-ran the bar rather than inheriting the numbers above: `swift build`
exit 0 (only the two pre-existing GhosttyKit vendor-symbol warnings) and full
`swift test` **982 / 0** in 60.5 s. The chain was read end to end in the working tree —
`SpatialLayout.swift:531` converts fraction to delta with the no-op and unknown-slot
guards intact, `Workspace.swift:985` → `WorkspaceStore.swift:200` →
`SpatialCanvasView.swift:562` builds the 1/3 · 1/2 · Full menu with each item enabled
straight off the layout's own `isValid`, and `SpatialCanvasView.swift:1038` routes a
border right-click to it. Diff is 422 insertions / 38 deletions across 6 files, still
uncommitted.

The board line was moved Doing → Done as part of this pass; it had been left in Doing
already marked DONE, and a task line in the wrong column reads to the next agent as free
work. No source file was touched — `SpatialCanvasView.swift` is live under T-065.
