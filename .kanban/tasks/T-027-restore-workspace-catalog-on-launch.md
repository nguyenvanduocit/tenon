# T-027: The workspace catalog survives a relaunch
> Quitting Tenon currently throws away every workspace, tab, pane and split; the next
> launch rebuilds one workspace from the launch directory. Persist the catalog and
> restore it.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
UNCLAIMED. Whoever takes this claims the list below — it overlaps `Workspace.swift` /
`WorkspaceStore.swift`, which T-026 (session `d25d3c17`) is holding right now, so read
`Doing` before starting.

Expected files:
- `poc/Sources/TenonCore/Workspace.swift` — `Codable` conformance for the catalog tree
- `poc/Sources/TenonCore/WorkspaceCatalogStore.swift` — NEW persistence, mirroring `SettingsStore`
- `poc/Sources/TenonCore/DurableJSONFile.swift` — reuse, no change expected
- `poc/Sources/TenonApp/AppStatePaths.swift` — the catalog's path
- `poc/Sources/TenonApp/TenonApp.swift` — launch precedence (`TenonApp.swift:474-499`)
- `poc/Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift` — NEW

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
- [ ] The catalog tree (workspaces, tabs, `SpatialLayout`, `SlotContent`, active tab and
      active slot per workspace, sidebar state) round-trips through JSON with an explicit
      schema `version`, asserted in `TenonCoreTests` without a window
- [ ] Writes go through `DurableJSONFile` under `AppStatePaths` (atomic, exclusive lock) —
      several agents share this machine and a torn write must not lose the catalog
- [ ] Writes are coalesced off `WorkspaceEvent`, not one file write per mutation, and not
      driven from a SwiftUI callback
- [ ] Restore is fail-soft per pane, asserted case by case: missing directory, deleted
      file, unknown `pluginView` id, or a schema written by a newer version degrades that
      one pane and never discards the catalog
- [ ] Launch precedence is defined and tested: a bare launch restores the saved catalog; an
      explicit launch directory or a CLI-opened path adds or selects that workspace instead
      of replacing the tree
- [ ] Terminal scrollback and PTY continuity are explicitly OUT of scope (Orca buys them
      with a daemon). A restored terminal pane starts a fresh shell in its recorded cwd;
      the decision is written down, not left implicit
- [ ] A restored pane that has never been viewed holds no terminal surface — the lazy path
      is T-031's; this task must not build surfaces for the whole restored tree
- [ ] `swift build` + `swift test` green; launch smoke: two workspaces / three tabs / one
      split, quit, relaunch, same tree

## Inbound from T-030

T-030 (pane cwd + project root) ships a per-pane **project-root pin** — the "Set Project
Directory…" override — that currently lives in memory in `SurfacePool.pinnedRoots`
(`poc/Sources/TenonApp/SurfacePool.swift`). It survives pane switches and dies with the
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
