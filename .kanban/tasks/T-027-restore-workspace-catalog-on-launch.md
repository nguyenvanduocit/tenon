# T-027: The workspace catalog survives a relaunch
> Quitting Tenon currently throws away every workspace, tab, pane and split; the next
> launch rebuilds one workspace from the launch directory. Persist the catalog and
> restore it.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
RELEASED 2026-07-31 00:05 — task DONE by Orca worker
`term_3491061c-7a27-48d0-89d6-9143d983add6` (dispatch `ctx_1f39d1f17063`). Files shipped
(all free): NEW `Sources/TenonCore/WorkspaceCatalogStore.swift`, NEW
`Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`, NEW
`Tests/TenonAppStateTests/WorkspaceCatalogRelaunchTests.swift`, additive edits to
`AppStatePaths.swift` / `TenonApp.swift` / `SurfacePool.swift`. `Workspace.swift`,
`WorkspaceStore.swift` and `DurableJSONFile.swift` untouched.

## Why / evidence
- Tenon persists only `.recent-workspaces.json` and `.recent-views.json`
  (`Sources/TenonApp/TenonApp.swift:145,150`). `DurableJSONFile` is used by
  `SettingsStore.swift:339` and `PluginInstallationStore.swift:227` — never by the
  workspace catalog. The first workspace is derived from the launch directory
  (`TenonApp.swift:474-499`). **Relaunch = every tab, pane and split is gone.** (HIGH)
- Kero restores projects, tabs and pane layouts on restart, and remembers the sidebar
  layout across relaunches (changelog v0.1.21).
- Orca 1.3.32: *"App restart now restores 100% of the session"* — terminals, splits,
  cursor position, scrollback, working directory, window bounds, focused tab — on top of
  the out-of-process PTY daemon from 1.3.0.
- A supervision surface built to hold many concurrent agents cannot reset its layout on
  every restart; this blocks the attention work in T-029 from being worth anything.

## Criteria
- [x] The catalog tree (workspaces, tabs, `SpatialLayout`, `SlotContent`, active tab and
      active slot per workspace, sidebar state) round-trips through JSON with an explicit
      schema `version`, asserted in `TenonCoreTests` without a window —
      `WorkspaceCatalogPersistenceTests.testCatalogTreeRoundTripsThroughTheDocumentWithAnExplicitSchemaVersion`.
      Sidebar visibility/width already persist through `AppPreferences`
      (`ContentView.swift:20-22`); the catalog document deliberately does not duplicate
      them (invariant 6 — one owner per semantic).
- [x] Writes go through `DurableJSONFile` under `AppStatePaths` (atomic, exclusive lock) —
      `WorkspaceCatalogStore.write` wraps the atomic replace in
      `DurableJSONFile.withExclusiveLock`; asserted by
      `testWritesGoThroughTheDurableFileLock` (the stable `.lock` sibling exists after a
      save). Path: `AppStatePaths.workspaceCatalogFile` = `<state>/workspace/.workspace-catalog.json`.
- [x] Writes are coalesced off `WorkspaceEvent`, not one file write per mutation, and not
      driven from a SwiftUI callback — `store.onEvents` (the domain event callback in
      `AppComposition.wire`) notes changes; the actor debounces to one write per burst
      (`testRapidMutationsCoalesceIntoASingleWrite`: 10 notes → 1 write, last wins).
      `flush()` is the quit path (`testFlushWritesThePendingSnapshotImmediately`).
- [x] Restore is fail-soft per pane, asserted case by case — one test each in
      `WorkspaceCatalogPersistenceTests`: workspace folder gone (dropped, others kept,
      selection falls back), all gone (nil), deleted file (pane → `.empty`, layout kept),
      unknown `pluginView` (→ `.empty`), newer-build content type (→ `.empty`), unknown
      fields ignored, newer top-level `version` (no restore, file left byte-identical),
      corrupt/duplicate-key file (nil, no crash), structurally invalid tab (dropped
      without discarding the catalog). Domain preconditions are unreachable: restore
      validates piecewise and gates on `WorkspaceCatalog.isValid` before constructing.
- [x] Launch precedence is defined and tested — see "Design decisions" below.
      `testABareLaunchRestoresTheSavedCatalogAsSaved`,
      `…MatchingAnOpenWorkspaceSelectsIt…`, `…AddsAWorkspaceInsteadOfReplacingTheTree`,
      `…SeedsAFreshCatalog`. CLI-opened paths go through `WorkspaceStore.addWorkspace`
      mutations, which persist through the same event path.
- [x] Terminal scrollback and PTY continuity are explicitly OUT of scope. A restored
      terminal pane starts a fresh shell in its workspace path — the pane's live cwd is
      deliberately NOT persisted (per the T-030 handoff: a saved cwd would restore a
      directory no live shell is in; the workspace path seeds, the first OSC 7 corrects).
- [x] A restored pane that has never been viewed holds no terminal surface — restore is
      pure (returns `RestoredWorkspaceCatalog`, touches no pool); surfaces are still built
      only by `SurfacePool.surface(for:)` on first render. Pin re-application records the
      pin without building anything (`pinProjectRoot` exits before `updateDirectory` when
      no surface exists). Nothing in this slice calls `surface(for:)`. Deeper laziness is
      T-031's.
- [x] `swift build` exit 0 + `swift test` 680/680 (baseline 653; +20
      `WorkspaceCatalogPersistenceTests`, +1 `WorkspaceCatalogRelaunchTests`, rest are
      other live workers'). Quit → relaunch → same tree is asserted headlessly through
      the real composition root:
      `WorkspaceCatalogRelaunchTests.testQuitAndRelaunchRestoresTheSameTreeAndReAppliesThePin`
      builds two workspaces / three tabs / one split + a pin, `stop()`s, re-inits, and
      compares the whole catalog for equality. Live launch smoke: app alive on a private
      socket, clean log (see worker_done).

## Design decisions (T-027)

- **Schema is a DTO layer, not `Codable` on the domain types.** `Tab`/`Workspace`/
  `WorkspaceCatalog` enforce invariants with preconditions; a decoder init would make
  those preconditions reachable from a hostile or stale file — the exact crash fail-soft
  forbids. `WorkspaceCatalogSnapshot` validates first, constructs only what passed.
  `Workspace.swift` is untouched.
- **Launch precedence:** `TENON_WORKSPACE_PATH` and a terminal launch's cwd are an
  *explicit* launch directory — running `tenon` inside a project means "open this
  project", so it adds (or folder-key-selects) that workspace on top of the restored
  tree, never replacing it. A Finder-style launch (cwd `/`) names nothing — that is the
  bare launch that restores the catalog exactly as saved. With nothing restored, the old
  behavior is preserved verbatim (`resolvedInitialWorkspacePath` now delegates to
  `resolvedLaunchDirectory`).
- **Forward compatibility:** unknown JSON fields are ignored at every level; an unknown
  pane content `type` degrades that one pane. The top-level `version` bumps only for
  incompatible rewrites; a newer `version` is not restored at all (identical shapes can
  carry changed semantics — best-effort would restore something silently wrong) and the
  bytes are left untouched. An old build that then quits overwrites with its own state —
  the user running the old build chose it, and its session deserves persistence too.
- **`.diff` panes:** a git-sourced diff round-trips (repo/path/staged/untracked/origPath
  re-resolve on open); an inline diff is captured as `.empty` — its two texts are live
  plugin state, same reasoning as the cwd.
- **Restore never rewrites the file; live state does.** Saves happen on mutation
  (coalesced) and at quit (`stop()` notes the final tree + pins, then flushes). The
  persistence tasks read live state at run time, so unordered actor jobs converge on the
  newest tree instead of racing the quit save.
- **Unknown plugin view at launch:** what init can know before `host.loadAll()` is
  whether the plugin still exists in the inventory (manifest `id` scan — plugin
  directories are short-named). A view id unknown *within* a live plugin stays the host's
  instance-reconciliation business.

## Inbound from T-030

T-030 (pane cwd + project root) ships a per-pane **project-root pin** — the "Set Project
Directory…" override — that currently lives in memory in `SurfacePool.pinnedRoots`
(`Sources/TenonApp/SurfacePool.swift`). It survives pane switches and dies with the
pane, but not a relaunch. Making it survive is one field in *your* schema, deliberately
left to you rather than bolted on from T-030, so the workspace tree keeps exactly one
persistence path (invariant 6).

- **Field:** one optional absolute path per pane on `Slot` — `projectRootPin: String?`,
  where `nil` means "Use Automatic".
- **Round-trip:** verbatim in, verbatim out. It is a human override, so restore it
  *without* re-resolving and *without* checking that the directory still exists — a pin
  aimed at a worktree that has since been removed must come back as a visible pin the user
  can clear, not silently revert to automatic. (This is the one case where the fail-soft
  rule above should degrade the pane's *marker*, not its pin.)
- **Wiring on restore:** for each restored pane carrying a pin, call
  `SurfacePool.pinProjectRoot(url, for: slotID)`. That method re-resolves and publishes the
  `pane.cwd-changed` EVENT only when the anchor actually moved, so a restore is just a
  normal update — no special case needed.
- **Do NOT persist the pane's cwd.** It is live shell state. A restored pane re-seeds from
  its workspace path and the first OSC 7 corrects it; persisting the cwd would restore a
  directory no live shell is in. (Note this interacts with the scrollback criterion above,
  which already says a restored pane "starts a fresh shell in its recorded cwd" — the
  recorded cwd there should be the workspace path, not T-030's live pane cwd.)

— session `a4af4e8c`, T-030
