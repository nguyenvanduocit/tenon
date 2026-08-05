# T-059: A pane drag never previews a position it cannot commit
> User screenshot (00:53): a dragged pane rendered half on top of its neighbour with the
> red invalid border, waiting for mouse-up to roll back. If the move is impossible, the
> pane must not move — the invalid overlapped state should be unrepresentable, not handled.
- **priority**: high
- **effort**: S

## Owner / files (agent lock)
Session caa656c9 (user-directed; filed straight to Doing past the ed76fd97 pair — no file
overlap with T-054/T-055 locks). Claiming:
- poc/Sources/TenonApp/SpatialCanvasView.swift
- poc/Tests/TenonAppStateTests/SpatialCanvasInteractionTests.swift

## Root cause
`SpatialCanvasInteractionCoordinator.update` stores whatever transaction the pointer
produces, valid or not, and `SpatialCanvasNSView.drag` renders `preview.proposal`
unconditionally — so an invalid move draws the pane overlapping its neighbour
(red border via `setPreviewValidity(false)`), and only mouse-up rolls it back.

## Decision
The coordinator only ever holds a valid preview: an invalid candidate keeps the last
valid one (the pane stops at the wall), and a drag whose first step is invalid holds the
baseline (the pane does not move at all). Release commits what is displayed. With invalid
previews unrepresentable, the red-border machinery (`setPreviewValidity`,
`previewIsValid`) is dead code and is deleted, test included.

## Criteria
- [ ] An invalid move/resize candidate never becomes the preview; the last valid preview (or baseline) stays displayed
- [ ] Releasing over an invalid spot commits the held valid position; a drag with no valid step rolls back
- [ ] The invalid-preview red border path is deleted end to end
- [ ] Full `swift test` green
