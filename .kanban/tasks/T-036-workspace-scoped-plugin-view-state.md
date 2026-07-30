# T-036: Plugin view state stays with its workspace
> A File Browser opened in one workspace appears to follow the currently selected workspace,
> so switching away and back mutates what the original workspace's browser displays.

- **priority**: high
- **effort**: M
- **owner**: DONE — term_3992d7fa-84c6-4274-87ab-5a15f3dc5be9 (Orca worker), lock RELEASED. Files touched: poc/plugins/{file-explorer,git,claude-sessions}/main.js, poc/Tests/TenonCoreTests/{WorkspaceScopedViewStateTests.swift (NEW), FileExplorerPluginTests.swift}, docs/design-plugin-view-instances.md. PluginHost.swift and all other Swift host code untouched.

## Root cause (verified 2026-07-30)
Not the shared runtime — that is by design and unchanged. Three shipped views rode that
runtime as SINGLETONS with module-global state, and each also subscribed
`workspace.selected` to rebind that one state to the newly selected workspace:
- `file-explorer` registered without `instanced:true` (old `main.js:15`) and its
  `workspace.selected` handler (old `main.js:358`) retargeted the single tree — wiping
  `expanded`/`selectedPath` — to the selected workspace's root. This is the reported bug.
- `git` (old `main.js:440,507`): same shape (`repoPath = null; refresh()` on selection).
- `claude-sessions` (old `main.js:312,350`): same shape (rescan on selection).
- `browser` was already instanced (T-012); `view-gallery` has no workspace-dependent
  state, its shared body is deliberate.
T-030's focus-following (`workspace.slot-focused`/`pane.cwd-changed`) was a CONTRIBUTING
path — the global `followedRoot` also dragged the singleton toward whichever pane got
focus after a switch — but the primary path was the explicit `workspace.selected` rebind.

## Fix
All three views adopt the T-012 instance model (`register({instanced:true})`, state keyed
by instanceID) and resolve their root/repo/project from the workspace that OWNS the pane,
mapped pane→tab→workspace through the existing public `workspace.state.v1` — no new
`tenon` member, no host change, no transport reclassification. Focus-following is filtered
per instance by owning `workspaceId`; a `workspace.changed` handler re-resolves ownership
so a pane moved between workspaces rebinds correctly. The git STATUS BAR alone still
follows selection+focus globally — one global surface, selection-scoped by design.

## Criteria
- [x] Add a deterministic regression that opens equivalent plugin views in two workspaces,
      switches between them, and proves their state is independent
      (`WorkspaceScopedViewStateTests`, 4 tests: file-explorer deep incl. expansion
      survival, git repo binding, claude-sessions project binding, instancing sweep)
- [x] Every view update is routed with sufficient workspace/pane/view-instance identity
      (`views.set(view, body, instanceID)` everywhere; events filtered per instance)
- [x] Inactive workspaces are not mutated merely because the global selection changed
      (asserted after `workspace.selected` + `workspace.changed` emits, both directions)
- [x] File Browser follows its owning workspace root while retaining per-instance UI state
- [x] Check other shipped plugin views for the same cross-workspace leakage
      (git + claude-sessions fixed; browser already instanced; view-gallery's shared body
      asserted as deliberately singleton)
- [x] `swift build` and the relevant test suites pass — build exit 0, `swift test`
      **657/657, 0 failures** (baseline 653 + the 4 new regressions)

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
