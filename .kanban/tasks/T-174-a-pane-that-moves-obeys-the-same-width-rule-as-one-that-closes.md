# T-174: A pane that moves obeys the same width rule as one that closes

> Automatic layout reads the configured maximum width on every cross-tab move — the tab
> the pane left and the tab it lands in — through one shared removal routine instead of a
> second copy of `closeSlot`.

- **priority**: high
- **effort**: M
- **requirements**: `SP-FR-004`, `SP-FR-006`

## Owner / files (agent lock)

DONE 2026-08-17 by session `f1269a59`; every file released. Files touched:
`Workspace.swift`, `WorkspaceStore.swift`, `NewPaneSizingTests.swift`,
`spatial-panes.prd.md`, `spatial-panes.feature`.

## The report

Closing a pane grows its neighbour only as far as the configured maximum. Dragging that
same pane out to a new tab grows the neighbour to the full canvas, and the pane itself
lands full-width in the tab it arrives in. Two ways of removing a pane from a tab, two
different widths.

## Root cause

The policy travels as an optional parameter with a default — `sizing: NewPaneSizing =
.unlimited` — so obeying it is opt-in per call site, and the cross-tab move family never
opts in:

- `Workspace.swift:1615` — `detachSlot` calls `SpatialLayout.close(_:slotID:)` with no
  `maximumAbsorbedWidth`, where `closeSlot` passes `sizing.maximumColumns` at `:962`.
- `Workspace.swift:1122` — `moveSlotToNewTab` hardcodes `rect: fullGridRect`, where
  `openSlot` narrows with `sizing.fitting(fullGridRect)` at `:837`.
- `WorkspaceStore.swift:286-306` — no `moveSlot*` reads `newPaneSizing`, while
  `closeSlot`/`addSlot`/`splitSlot`/`newTab`/`duplicateSlot` all do.

`closeSlot` (`:952-1012`) and `detachSlot` (`:1608-1643`) are also near-verbatim copies of
one another for ~30 lines; they differ in the cap and in whether the result is emitted as
events or returned to a caller.

## The rule this settles on

Automatic layout obeys the maximum; geometry a person named does not.

| Path | Capped |
|---|---|
| source tab reflow after the pane leaves | yes — same fact as a close |
| `moveSlotToNewTab` (drop on the tab bar) | yes — nobody named a frame |
| `moveSlot(_:toTab:)` auto-placement (drop on a tab chip) | yes — nobody named a frame |
| `moveSlot(_:toTab:at:)` (drop on a highlighted empty region) | no — the highlight promised that frame |
| `moveSlot(_:toTab:beside:edge:)` (drop on a pane edge) | no — the edge named the frame |

This narrows the 2026-08-14 decision (`spatial-panes.prd.md`) from "a move is not a
creation" to "a move *into a frame the person chose* is not a creation". Its stated reason —
the highlight must promise exactly the committed frame — survives intact, because it only
ever applied to the two drops that draw a frame.

## Criteria

- [x] Closing a pane and dragging it to another tab leave the surviving neighbour the same width
- [x] A pane dropped on the tab bar lands at the configured maximum in its new tab
- [x] A pane dropped on a highlighted empty region still adopts that region exactly
- [x] One removal routine serves both `closeSlot` and `detachSlot`
- [x] `SP-FR-004`/`SP-FR-006` restated and a decision row appended to `spatial-panes.prd.md`
- [x] `swift test` green

## Result

`removeSlot` replaces `detachSlot`; `closeSlot` fell from 61 lines to 32 and the two
departures now reflow through one implementation. `moveSlotToNewTab`, chip-drop
auto-placement, and every source-tab reflow read the preference; the two drops that draw a
highlight still adopt their promised frame. `NewPaneSizingTests` 27 / 0, full suite
**2284 / 0**.

Owed: a hardware drag on an installed build. The suite proves the widths, not the gesture,
and installing over the running app would destroy other sessions' panes.
