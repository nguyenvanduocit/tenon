# T-181: Files' context menu opens and feeds a coding agent
> A directory opens an installed agent there; a dropped row reaches a Tenon terminal too
- **priority**: high
- **effort**: M

**CLAIMED by this session, 2026-08-18 14:2x.** Operator feature request (screenshot) → PRD
written into `docs/prds/files-and-content.prd.md` (`FC-FR-037`…`040`, `FC-NFR-013`) → `/goal
finish the feature` directed implementation. Files held: `Sources/TenonBundledPlugins/FileExplorerPlugin.swift`,
`plugins/file-explorer/manifest.json`, `Sources/TenonApp/TerminalSurface.swift`,
`Sources/TenonApp/SurfacePool.swift`, `Sources/TenonApp/GhosttySurface.swift`,
`Tests/TenonCoreTests/FileExplorerPluginTests.swift`, a new
`Tests/TenonAppStateTests/TerminalFileDropTests.swift`, `files-and-content.prd.md`/`.feature`
— none held by any other Doing task (checked 2026-08-18 14:2x: T-180, T-179, T-178, T-177,
T-144, T-141, T-140, T-135 hold none of these).

**Explicitly NOT attempted here: `FC-FR-038` ("Send to Agent").** It needs a public
`agent.list.v1`/`agent.get.v1` to discover live agent panes (PRD-017, still `planned`, not in
source), and its natural home — `AgentIntentProvider.swift` / `TenonApp.swift` — is held live
by T-178. Building even a narrow slice would collide with that claim. Left for after T-178
clears; PRD-008 already records this as a stated dependency, not a silent gap.

## Criteria
- [x] `FC-FR-037` — directory menu offers one "Open in `<agent>`" item per `agent.inventory.v1`
      result, composes via `agent.command.v1`, opens via `terminal.open.v1` at that folder.
- [x] `FC-FR-039` restated in the PRD as a named requirement for already-shipped drag-out,
      which previously had none — no new automated test added; still resting on code
      inspection (`RowDragModifier`) and the operator's live observation.
- [x] `FC-FR-040` — a Tenon terminal pane accepts a dropped row's file URL and inserts its
      quoted path into the PTY without submitting.
- [x] `FC-NFR-013` — every path this task delivers into a PTY is POSIX-quoted through
      `AutomationAuthoring.posixQuoted`.
- [x] `swift test` scope green; full suite checked for regressions.
- [x] PRD delivery matrix and verification receipts updated to match what actually shipped.

**Shipped 2026-08-18.** `agent.inventory.v1`/`agent.command.v1`/`terminal.open.v1` were already
public, so `FC-FR-037` needed only `FileExplorerPlugin.swift` menu/routing changes plus three
new `intents.uses` entries in `plugins/file-explorer/manifest.json`. `FC-FR-040` added
`onFileDrop` to the `TerminalSurface` protocol (opt-in default, matching `onPwdChange`), wired
it in `SurfacePool.surface(for:)` next to the other per-slot callbacks, and gave
`GhosttyNSView` a real `.fileURL` dragging destination mirroring `WorkspaceFolderDropAdapter`.
Tests: `FileExplorerPluginTests` +3 (menu ordering, compose-then-open, failed-compose-never-opens),
new `TerminalFileDropTests` (+2, including a shell-metacharacter path). Full suite **2366 / 0**.

**Mid-task redesign, driven by a peer session (`tenon-33`):** a live cross-session message
reported them debugging a permanent "Plugin view unavailable" regression, hypothesizing
`BundledPluginRuntime`'s 256-slot mailbox overflows when `render()`'s existing
`workspace.changed`/`pane.cwd-changed`/`workspace.slot-focused` fan-out does one round trip too
many during churn. My first draft added exactly one more round trip (`agent.inventory.v1`)
inside `render()` — directly in the loop they suspect. Refactored before shipping: the agent
list is now fetched once in `open(instanceID:)` and on explicit `Files: Refresh`, cached on
`Pane`, and `render()` reads the cache — zero added round trips in the churn path. Replied to
`tenon-33` with this finding; declined folding their mailbox-overflow investigation into this
task (unverified hypothesis, separate files' worth of root-causing) so it stays independently
revertable.

**Known gaps, not this task's to close:**
- `FC-FR-038` ("Send to Agent") — unshipped, blocked on PRD-017's `agent.list.v1`/`agent.get.v1`
  and, right now, T-178's live lock on `AgentIntentProvider.swift`/`TenonApp.swift`.
- `GhosttyNSView`'s real AppKit drag registration has no automated test — building a real
  Ghostty surface in the shared suite risks the T-135 crash; needs a live human drag.
- T-159 (unclaimed): a composed agent command line over macOS's 1024-byte `MAX_INPUT` silently
  loses its Enter at the PTY. `FC-FR-037` can now trigger that exact failure mode with a long
  habitual argument set; not mitigated here, cross-linked in the PRD risk table.

Files released: `FileExplorerPlugin.swift`, `plugins/file-explorer/manifest.json`,
`TerminalSurface.swift`, `SurfacePool.swift`, `GhosttySurface.swift`,
`FileExplorerPluginTests.swift`, `TerminalFileDropTests.swift`, `files-and-content.prd.md`/`.feature`.
