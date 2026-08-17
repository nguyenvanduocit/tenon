# T-172: The identity popover's grids stop short of their own edge

> The mark and tint grids are laid out in `.fixed` columns, so they occupy only as much
> width as their contents need and dump the remainder against the right inset.

- **priority**: medium
- **effort**: S
- **PRD**: `TENON-PRD-001` workspace-shell — `WS-NFR-006` (design/density)

## Owner / files (agent lock)

Released 2026-08-16 18:3x — the work is done and the files are free.

## What was measured

The popover is 320 pt wide with a 14 pt inset, so its content box is 292 pt.

| block | occupies | left over |
| --- | --- | --- |
| mark grid, 8 columns | 8×28 + 7×6 = 266 pt | 26 pt |
| tint grid, 7 columns | 7×28 + 6×6 = 232 pt | **60 pt** |
| Upload Custom Icon | ~165 pt, sized by its label | ~127 pt |

Source: `WorkspaceIdentityViews.swift:18,22-24` (width, swatch, spacing, inset),
`:262-266` and `:364-368` (`GridItem(.fixed(swatch))`), `:50-55` (`tintColumns = 7`).
Photographed before the change at 320×393 pt: the tint row ends at 240 pt of a 306 pt
content edge.

The column counts are not the defect — 7 tint columns is the deliberate 7+6 balance
(`:46-48`), and 8 mark columns is 24 spread evenly over 3 rows. The defect is that a
`.fixed` column cannot grow, so neither grid ever reaches its own right edge.

The existing tests could not see it: they assert `occupied <= content`
(`WorkspaceIdentityFormTests.swift:45,73`), which forbids overflow and permits any
amount of slack.

## Criteria

- [x] A test measured on the rendered pixels, not recomputed from the metrics the view
      lays out from — `testASwatchRowIsSpreadEvenlyAcrossThePopoversContentWidth` red at
      `leading 7.0 pt` against `trailing 67.0 pt`, green after
- [x] Both grids span the full content width; swatches stay 28 pt and the leftover width
      becomes `columnSpacing(for:)` — 9.71 pt between marks, 16 pt between tints
- [x] Upload Custom Icon spans the same width, so the section reads as one block
- [x] Before/after snapshots taken through `TENON_IDENTITY_SNAPSHOT`
- [x] `workspace-shell.prd.md` carries the decision row and a dated receipt

## What shipped

`columnSpacing(for:)` derives the gap from the width a row is laid out in, so the width a
row is given is the width it gives back. Marks and tints now go through one
`swatchGrid(columns:)` — the two `LazyVGrid` blocks were identical apart from their column
count, and one layout is what lets a single rendered measurement stand for both.

The two older assertions were replaced rather than added to: `occupied <= content` forbade
overflow and permitted 60 pt of slack, which is the defect it was sitting next to. What
stands in its place is the density floor it was really reaching for —
`columnSpacing(for:) >= swatchSpacing`, so a future column count cannot pack a row tighter
than the form draws anywhere else.

Full suite **2279 / 0**. One earlier run reported a single failure that did not reappear in
either of the two runs after it; it was in neither the popover nor its tests.
