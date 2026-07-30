# T-036: Plugin view state stays with its workspace
> A File Browser opened in one workspace appears to follow the currently selected workspace,
> so switching away and back mutates what the original workspace's browser displays.

- **priority**: high
- **effort**: M
- **owner**: UNCLAIMED

## Reproduction
1. Open workspace A and open File Browser there.
2. Switch to workspace B.
3. Observe the File Browser state while B is selected.
4. Switch back to workspace A.
5. Observe that the browser follows the selected workspace rather than preserving an
   independently owned state for A.

## Actual
- File Browser content/state appears to be rebound when the selected workspace changes.
- Returning to a workspace changes the browser back again, suggesting shared global state
  or updates routed without workspace/view-instance identity.

## Expected
- A plugin view's state belongs to the workspace/pane/view instance that opened it.
- Switching workspaces does not mutate inactive workspaces' File Browser state.
- Returning to workspace A restores exactly the state A had before the switch.

## Investigation notes
- Confirm whether the defect affects only File Browser or all plugin views.
- Distinguish a shared plugin runtime from accidentally shared view state; sharing a runtime
  must not imply sharing per-workspace view-instance state.
- Classify any interaction change using `docs/architecture-interaction-boundaries.md` before
  changing its transport or public surface.

## Criteria
- [ ] Add a deterministic regression that opens equivalent plugin views in two workspaces,
      switches between them, and proves their state is independent
- [ ] Every view update is routed with sufficient workspace/pane/view-instance identity
- [ ] Inactive workspaces are not mutated merely because the global selection changed
- [ ] File Browser follows its owning workspace root while retaining per-instance UI state
- [ ] Check other shipped plugin views for the same cross-workspace leakage
- [ ] `swift build` and the relevant test suites pass
