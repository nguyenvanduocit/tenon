# T-088: New pane focus stops oscillating
> Creating a pane from an empty-space context menu must settle focus once, instead of the new and previous panes stealing it back from each other forever.

- **priority**: high
- **effort**: M

## Reproduction
1. Focus panel A.
2. Right-click an empty area and create a new panel.
3. Observe panel A and the new panel repeatedly alternate focus without further input.

## Criteria
- [ ] The reproduction path no longer starts a focus loop: after creating the panel, focus settles and remains stable without further user input.
- [ ] The newly created panel becomes the focused panel exactly once and is ready to receive keyboard input.
- [ ] The previously focused panel cannot reclaim focus from a stale context-menu, appearance, selection, or workspace-reconciliation callback.
- [ ] Creating panels through other entry points keeps its existing focus behavior, and ordinary clicks can still move focus between panels.
- [ ] Focused-view keyboard controls remain same-owner DIRECT/local control under `docs/architecture-interaction-boundaries.md`; the fix does not add a public intent or capability.
- [ ] A regression test drives the empty-space context-menu creation path and proves that focus transitions are bounded and stop after the new panel is selected.

## Notes
The failure is not merely a wrong final selection: it is a self-sustaining feedback loop between
two panels. The regression should therefore observe transitions after creation, not only assert
which panel is focused at one instant.
