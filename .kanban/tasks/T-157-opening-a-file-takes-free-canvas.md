# T-157: Opening a file takes free canvas instead of quartering the pane you are watching
> `WorkspaceStore.openContent` went straight to `splitActiveSlot`, so a half-width pane
> beside an empty half was cut to a quarter — and a pane under 6 columns opened nothing at all.

- **priority**: high
- **effort**: XS
- **requirements**: `FC-FR-014` (PRD-008 files-and-content)

## Root cause

`WorkspaceStore.openContent` (`Sources/TenonCore/WorkspaceStore.swift:250`) owned a second
placement policy: reuse a qualifying pane, otherwise `splitActiveSlot(.horizontal, …)`. The
one placement policy every other creation path shares lives in `Workspace.openSlot`
(`Sources/TenonCore/Workspace.swift:825-889`) and asks `SpatialLayout.bestEmptyRect` for free
canvas *before* it splits anything. Smart open never asked, so it halved the active pane
whatever the canvas looked like.

Two operator-visible failures, both reproduced as tests before the fix:

- A 6-column terminal with 6 empty columns beside it: the terminal was cut to 3 columns and
  the file placed at x=3, leaving the empty half untouched — the reported 1/2 → 1/4.
- A 4-column pane with 8 empty columns: `SpatialLayout.split` refuses a pane narrower than
  `minimumWidth * 2`, so the split returned nil and **no pane opened at all**; through
  `workspace.content.open.v1` that surfaces as `content-cannot-be-placed`.

The 1/2 creation maximum is the easiest way to reach that canvas state, not the cause: any
dragged border leaves the same free region.

## Fix

`openContent` reuses a qualifying pane, otherwise calls `addSlot(content:)` — the shared
policy, which also covers the empty-tab case the old first branch handled by hand.

## Criteria

- [x] Free canvas takes the new pane; the pane already open keeps its width
- [x] A full canvas still splits horizontally, as before
- [x] The new pane still obeys the creation maximum when it takes free canvas
- [x] `FC-FR-014`, its Gherkin scenarios, decision log, and a verification receipt updated
- [x] `swift test` 2243 / 0

## Owner / files (agent lock)

Released 2026-08-14 — task complete.
