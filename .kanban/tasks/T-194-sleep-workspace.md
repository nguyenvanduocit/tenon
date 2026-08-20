# T-194: Sleep workspace and Move to Background
> Two workspace-lifecycle actions: Sleep frees a workspace's live PTYs/plugin-webviews with zero catalog change (wake is ordinary lazy re-materialization); Move to Background hides a workspace from the sidebar's main list while it keeps running.
- **priority**: medium
- **effort**: L

## Owner / files (agent lock)
- **DONE 2026-08-20 by this session; files released.** Full suite **2430 / 0**. Not pushed
  (10 commits ahead of `origin/main`; local `main` only, per this repo's direct-commit
  workflow).
- Files touched, now released: `Sources/TenonCore/Workspace.swift`,
  `Sources/TenonCore/WorkspaceStore.swift`, `Sources/TenonCore/RecentStore.swift` (unplanned:
  `WorkspaceEvent`'s exhaustive `workspaceID` switch), `Sources/TenonCore/CoreIntentName.swift`,
  `Sources/TenonCore/CoreIntentRules.swift`, `Sources/TenonCore/WorkspaceCatalogStore.swift`,
  `Sources/TenonApp/WorkspaceIntentProvider.swift`, `Sources/TenonApp/PluginWebSurfacePool.swift`,
  `Sources/TenonApp/TenonApp.swift`, `Sources/TenonApp/AppIntentRuntime.swift`,
  `Sources/TenonApp/ContentView.swift`, `Sources/TenonApp/WorkspaceSidebarView.swift`,
  `Sources/TenonApp/ShellChromeSnapshot.swift`, `Sources/TenonApp/SidebarSnapshot.swift`
  (unplanned: second `WorkspaceSidebarView`/`ContentView` construction site),
  `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift` (new),
  `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`,
  `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`,
  `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`,
  `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift`,
  `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift`,
  `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift` (new),
  `Tests/TenonAppStateTests/WorkspaceSidebarVisibilityTests.swift` (new),
  `docs/prds/workspace-shell.prd.md`, `docs/prds/workspace-shell.feature`.

## Context

Pre-claim check (2026-08-20): `git status --short` is completely clean. Several `Doing` board
rows (T-179, T-178, T-177, T-144, T-141, T-140, T-135) describe "Files held" including
`WorkspaceSidebarView.swift`/`ContentView.swift`/`TitleBarSnapshot.swift`, but none have a
matching uncommitted change in the tree — treating those claims as stale rather than live.
T-193 also notes "not committed" work touching `Workspace.swift`, likewise absent from the
current tree. Not investigated further; out of scope for this task. Proceeding since the tree
this task actually edits is clean.

Mid-session, T-195 (a genuinely live peer session) repeatedly raced this task's builds with
its own in-flight edits to `PaletteOverlay.swift`/`PaletteRowChrome.swift`/
`EmptyPaneOfferings.swift`/`WorkspaceStageView.swift` (transient "modified during the build" /
compile errors). Never touched their files; waited and retried each time until they settled.

## Criteria
- [x] Task 1: `WorkspaceVisibility` + `Workspace.visibility` + `WorkspaceCatalog.setVisibility`
- [x] Task 2: `WorkspaceStore.setVisibility`
- [x] Task 3: register `workspace.sleep.v1` / `workspace.visibility.set.v1` in the intent catalog
- [x] Task 4: `PluginWebSurfacePool.disposeSurfaces`
- [x] Task 5: `WorkspaceSleepAction` + intent handlers
- [x] Task 6: wire the real Sleep teardown into `TenonApp.swift` composition
- [x] Task 7: persist `visibility` in `WorkspaceCatalogStore`
- [x] Task 8: sidebar Sleep / Move to Background context-menu actions
- [x] Task 9: filter sidebar to visible workspaces + reorder-index translation + Backgrounded section
- [x] Task 10: `workspace-shell.prd.md` update

## Outcome (2026-08-20)

**Shipped**, `WS-FR-037`/`WS-FR-038`. Sleep is host-only — zero `Workspace` domain change,
implemented by narrowing the set passed to `SurfacePool.retainOnly` /
`PluginWebSurfacePool.disposeSurfaces` (new method). The real teardown is late-bound
(`WorkspaceSleepAction.perform`), assigned only after `PluginHost` exists in
`AppComposition.init`, because `PluginHost.init` needs `intentRuntime.kernel` — the sidebar's
Sleep button and `workspace.sleep.v1` both call the same instance. Move to Background is an
ordinary `Workspace.visibility` mutation modeled on `removeWorkspace`'s active-handoff shape.
Sidebar drag-to-reorder now operates entirely in visible-workspace-list space, translating to
the catalog's absolute index only at the final `store.moveWorkspace` call
(`absoluteWorkspaceIndex(forVisibleDestination:in:)`) — proven against an interleaved
backgrounded workspace by `WorkspaceSidebarVisibilityTests`.

Two deviations from the plan, both flagged in the PRD decision log: the sidebar
sleep-indicator badge was descoped (operator-confirmed via `AskUserQuestion` — no workspace-
keyed state exists to hang it on today); Sleep's confirmation trigger uses
`SurfacePool.terminalProcessSnapshot(...).liveTerminalCount > 0` rather than tab-close's exact
idle-vs-running distinction, to avoid a second off-main inspection path.

Six build failures the plan did not foresee, all fixed the same session: two more exhaustive
`WorkspaceEvent` switches (`RecentStore.workspaceID`, `PluginHost.emit`'s bus mapping) needed
the new case; two more places pinned the intent-catalog's exact count beyond the four
anticipated (`testConcurrentInstallCompilesIntoAuthoritativeKernelExactlyOnce`'s
revision/definition/contract/dispatchRule counts,
`testAudienceExposureProviderAndResourcePoliciesAreCoherent`'s explicit per-lane `Set`
literal); `PluginWebSurfacePool` needed a genuinely new method (spec said "no signature
change" — corrected in the plan before implementation); a second `WorkspaceSidebarView`/
`ContentView` construction site in `SidebarSnapshot.swift` needed the new parameter.

Full suite **2430 / 0**. `TENON_SIDEBAR_SNAPSHOT` at 232×460 with one workspace backgrounded
confirms the main list excludes it and the "Backgrounded" section names it correctly.

**Owed:** no live-app pointer/drag journey against a slept or backgrounded row (installed-app
check only); the sleep-indicator badge, if wanted later, is a separate follow-on task.
