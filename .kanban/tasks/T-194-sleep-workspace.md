# T-194: Sleep workspace and Move to Background
> Two workspace-lifecycle actions: Sleep frees a workspace's live PTYs/plugin-webviews with zero catalog change (wake is ordinary lazy re-materialization); Move to Background hides a workspace from the sidebar's main list while it keeps running.
- **priority**: medium
- **effort**: L

## Owner / files (agent lock)
- Session (this conversation), 2026-08-20. Executing `docs/superpowers/plans/2026-08-20-sleep-workspace.md`
  (spec: `docs/superpowers/specs/2026-08-20-sleep-workspace-design.md`), inline, task-by-task.
- Files: `Sources/TenonCore/Workspace.swift`, `Sources/TenonCore/WorkspaceStore.swift`,
  `Sources/TenonCore/CoreIntentName.swift`, `Sources/TenonCore/CoreIntentRules.swift`,
  `Sources/TenonCore/WorkspaceCatalogStore.swift`, `Sources/TenonApp/WorkspaceIntentProvider.swift`,
  `Sources/TenonApp/PluginWebSurfacePool.swift`, `Sources/TenonApp/TenonApp.swift`,
  `Sources/TenonApp/AppIntentRuntime.swift`, `Sources/TenonApp/ContentView.swift`,
  `Sources/TenonApp/WorkspaceSidebarView.swift`, `Sources/TenonApp/ShellChromeSnapshot.swift`,
  `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift` (new),
  `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`,
  `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`,
  `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`,
  `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift`,
  `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift`,
  `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift` (new),
  `docs/prds/workspace-shell.prd.md`.

## Context

Pre-claim check (2026-08-20): `git status --short` is completely clean. Several `Doing` board
rows (T-179, T-178, T-177, T-144, T-141, T-140, T-135) describe "Files held" including
`WorkspaceSidebarView.swift`/`ContentView.swift`/`TitleBarSnapshot.swift`, but none have a
matching uncommitted change in the tree — treating those claims as stale rather than live.
T-193 also notes "not committed" work touching `Workspace.swift`, likewise absent from the
current tree. Not investigated further; out of scope for this task. Proceeding since the tree
this task actually edits is clean.

## Criteria
- [ ] Task 1: `WorkspaceVisibility` + `Workspace.visibility` + `WorkspaceCatalog.setVisibility`
- [ ] Task 2: `WorkspaceStore.setVisibility`
- [ ] Task 3: register `workspace.sleep.v1` / `workspace.visibility.set.v1` in the intent catalog
- [ ] Task 4: `PluginWebSurfacePool.disposeSurfaces`
- [ ] Task 5: `WorkspaceSleepAction` + intent handlers
- [ ] Task 6: wire the real Sleep teardown into `TenonApp.swift` composition
- [ ] Task 7: persist `visibility` in `WorkspaceCatalogStore`
- [ ] Task 8: sidebar Sleep / Move to Background context-menu actions
- [ ] Task 9: filter sidebar to visible workspaces + reorder-index translation + Backgrounded section
- [ ] Task 10: `workspace-shell.prd.md` update
