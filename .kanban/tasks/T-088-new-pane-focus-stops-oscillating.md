# T-088: New pane focus stops oscillating
> Creating a pane from an empty-space context menu must settle focus once, instead of the new and previous panes stealing it back from each other forever.

- **priority**: high
- **effort**: M

## Reproduction
1. Focus panel A.
2. Right-click an empty area and create a new panel.
3. Observe panel A and the new panel repeatedly alternate focus without further input.

## Root cause (HIGH — reproduced headlessly, not inferred)

Two edges, each correct alone, formed a cycle with no fixed point.

- **model → AppKit.** `.slotFocused(X)` schedules `SurfacePool.focusSurface(X)`, which moves
  first responder to that pane (`TenonApp.swift`, the `onEvents` fan-out).
- **AppKit → model.** `becomeFirstResponder` → `onFocusGained` → `onSlotFocusGained(X)` →
  `store.focusSlot(X)` (`GhosttySurface.swift:809-818`, `SurfacePool.swift`, `TenonApp.swift`).

`Workspace.focusSlot` (`Workspace.swift:788-819`) refuses only a pane that is *already*
active. So when two focus commands for **different** panes are in flight at once, each one
finds the model pointing at the other, flips it, and emits a fresh `.slotFocused` — which
schedules a fresh command. Two in, two out, forever.

The empty-space launcher creates exactly that state: `Workspace.addSlot(id:content:at:)`
(`Workspace.swift:520-540`) focuses the pane it creates, while the popover dismissal hands
AppKit first responder back to the pane the person was leaving.

**Reproduced, with the loop visible.** `PaneFocusSettlementTests` with both bounds removed
prints the alternation verbatim — `A, B, A, B, …`, 49 model writes in 50 run-loop turns —
and the competing-command test measures 24 transitions against a bound of 1. With the bounds
in place: 0 and 1.

## The fix — three rules, all three load-bearing

`PaneFocusRouting` (new) holds both edges so they cannot drift apart, and is what
`TenonApp.wire` now calls instead of two inline closures.

1. **A host-driven focus is not news.** `SurfacePool.focusSurface` raises
   `isApplyingModelFocus` around the responder change it causes, and the report is dropped.
   A focus command can no longer manufacture the event that re-issues it. This is what cuts
   the cycle.
2. **A stale command does not execute.** `PaneFocusRouting.scheduleFocusCommand` re-reads
   `catalog.activeSlotID` after its turn of delay and does nothing if the model moved on.
   The last model write wins regardless of the order two commands happen to run in.
3. **An overlay's responder restoration is not a choice.** `SurfacePool.isOverlayOwningFocus`
   is raised by `SpatialCanvasNSView` while the launcher popover owns the key window, and
   lowered on close *after* re-asserting the model's focus. Without this the cycle stops but
   settles on the pane the person was leaving, because AppKit's restoration is the last
   writer. Rules 1 and 2 give criterion 1; rule 3 gives criteria 2 and 3.

`onFocusGained` moved from a `GhosttySurface`-only cast onto the `TerminalSurface` protocol,
on the same opt-in terms `onPwdChange` already uses. Focus is a fact of the responder chain,
not of the emulator — and it is what lets `StubTerminalSurface` carry the cycle so the bug is
reproducible with no window.

## Criteria
- [x] The reproduction path no longer starts a focus loop: after creating the panel, focus settles and remains stable without further user input.
- [x] The newly created panel becomes the focused panel exactly once and is ready to receive keyboard input.
- [x] The previously focused panel cannot reclaim focus from a stale context-menu, appearance, selection, or workspace-reconciliation callback.
- [x] Creating panels through other entry points keeps its existing focus behavior, and ordinary clicks can still move focus between panels.
- [x] Focused-view keyboard controls remain same-owner DIRECT/local control under `docs/architecture-interaction-boundaries.md`; the fix does not add a public intent or capability.
- [x] A regression test drives the empty-space context-menu creation path and proves that focus transitions are bounded and stop after the new panel is selected.

## Notes
The failure is not merely a wrong final selection: it is a self-sustaining feedback loop between
two panels. The regression should therefore observe transitions after creation, not only assert
which panel is focused at one instant.

`PaneFocusSettlementTests` does exactly that: it counts every write the surface→model edge
makes and bounds the count, rather than sampling which pane is focused at one instant.

### What is measured and what is reasoned

Measured: the cycle, its unboundedness, and that all three rules are required (each was
removed in turn and the suite went red). Reasoned: that the popover *dismissal* is what
restores first responder to the previous pane in the live app — the mechanism is AppKit's,
the code cannot observe it headlessly, and criterion 3 names this class of callback
explicitly. Rule 3 is written so it holds for any responder change during the overlay's
lifetime, which does not depend on that reading being exactly right.
