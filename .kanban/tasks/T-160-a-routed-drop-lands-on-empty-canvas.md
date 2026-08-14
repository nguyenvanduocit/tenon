# T-160: A routed drop lands on empty canvas
> Dragging a pane onto another tab must accept that tab's empty grid regions, not only its existing panes.
- **priority**: high
- **effort**: M
- **requirements**: `SP-FR-014` (PRD spatial-panes)

## Problem (operator report, 2026-08-14)
Kéo một pane từ tab này sang tab khác: khi tab đích còn chỗ trống, phải thả được vào
chỗ trống đó. Hiện tại không được.

Root cause, verified: the routed cross-tab drag path only resolves a body target when
the pointer is over an existing card (`SpatialCanvasNSView.swift:752-754`); empty grid
space leaves `bodyTarget` nil, and release cancels the whole gesture
(`SpatialCanvasNSView.swift:866-870`). The workspace model has no "move slot into tab
at a chosen empty rect" operation — only auto-placement (`Workspace.moveSlot(_:toTab:)`,
`Workspace.swift:1166`) and beside-split (`Workspace.swift:1241`).

## Design
- `SpatialLayout.move(_:slotID:toRect:)` — same-tab routed drop adopts the hole's rect.
- `SpatialLayout.insertAt(_:newSlotID:rect:)` — cross-tab admission at an exact rect,
  mirroring `insertBeside`.
- `Workspace.moveSlot(_:toTab:at:)` — detach + admit at the rect, same event sequence
  as the beside variant; refusal leaves the catalog untouched.
- Routed drag branch resolves empty regions through the same
  `SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget` geometry the
  empty-canvas click launcher uses (sizing `.unlimited`: a move is not a creation —
  chip-drop placement is already uncapped).
- `RoutedPaneDropTarget` gains a destination enum: `.beside(slotID:edge:)` |
  `.emptyRegion(GridRect)`.

## Criteria
- [x] Core: `SpatialLayout.move(toRect:)` and `insertAt` validate bounds/overlap/minimums; red first (4 assertion failures against compiling stubs).
- [x] Core: `Workspace.moveSlot(_:toTab:at:)` places at the exact rect with the beside-variant event sequence (shared `admitMovedSlot`); occupied rect refuses with no mutation.
- [x] App: routed drag over a fillable empty region of the revealed tab sets an `.emptyRegion` body target, highlights the hole's committed frame, and commits on release.
- [x] App: a cell with no valid hole still resolves to no target and release still cancels.
- [x] Extra, forced red by the first full-suite run: `RoutedPaneDrag.reachedTabBar` gates every routed body drop, so an intervening-mutation-stale gesture stays dead (`testRejectedStaleGestureRendersTheAuthoritativeStoreGeometry` red → green).
- [x] PRD: SP-FR-014 restated, empty-canvas scenario added to spatial-panes.feature, decision log + receipt + change history.
- [x] Full suite green — **2273 / 0** (2026-08-14 16:0x, with T-161's in-flight edits present in the tree).

## Owner / files (agent lock)
Released 2026-08-14 16:0x — task complete.
