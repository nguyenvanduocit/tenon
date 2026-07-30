# T-031: A pane nobody opened costs nothing
> A pane that has never been viewed holds no terminal surface, no PTY and no renderer
> buffers. Once viewed, it keeps them until the slot closes — a live PTY is never torn
> down to save memory.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
**RELEASED 00:30 — DONE + VERIFIED.** Was claimed by Orca worker task_b70e2f48cda7
(dispatch ctx_d2a305594ba0, terminal term_f86e30ad-b02f-4d6d-b5e3-b5ea848d57dc) at 00:19.
All files below are free again. Pairs with T-027 (a restored tree is the case that makes
this matter) and with the process-resource-monitor design under review.

Files touched by this slice (no longer locked):
- `poc/Sources/TenonApp/SurfacePool.swift` — the lifecycle rule (additive; T-027's pin
  accessor + `onPinChange` and T-030's `directories` untouched in behaviour)
- `poc/Sources/TenonApp/TerminalSurface.swift` — `sendText` joins the seam so the stub can
  assert delivery headlessly (the T-030 `onPwdChange` precedent)
- `poc/Sources/TenonApp/GhosttySurface.swift` — occlusion signal only; T-035's
  `doCommand(by:)` untouched
- `poc/Sources/TenonApp/TenonApp.swift` — restore seeding + capture arguments
- `poc/Sources/TenonCore/WorkspaceCatalogStore.swift` — additive DTO fields (`title`,
  `cwd` on `SlotRecord`), capture/restore threading
- NEW `poc/Tests/TenonAppStateTests/SurfaceLifecycleTests.swift`
- task file + own board lines

NOT touched: `SpatialCanvasView.swift` / `BuiltInSlotViews.swift` (free since T-016
released, but the design needs no edit there — the render path is already the only
materialization producer), nothing of T-037's.

## Design decisions (this slice)

**"Viewed" = the pane's content actually displayed on the visible canvas.** Not focus: a
split shows several panes at once, all before the human's eyes — materializing only the
focused one would leave visibly open panes blank. Not workspace selection: only the
selected workspace's selected tab renders (`WorkspaceStageView.swift:18-19`), so a
background tab's panes are not displayed and must not materialize. The production
producer of the signal is the render path — `BuiltInSlotViews.swift:23` calls
`pool.surface(for:workspacePath:)` exactly when a terminal pane's card is on the canvas —
so `surface(for:)` IS the injected "this pane became visible" signal and the pool never
reaches for the UI. A restored tree of 20 panes therefore materializes only the panes of
the one visible tab, and each remaining pane materializes the moment the human opens it.

**A restored pane materializes as a FRESH shell in its recorded cwd.** Materializing
never resurrects the dead process and never replays history: the catalog records
structure plus, per pane, the last title and cwd (new optional `SlotRecord.title`/`cwd`);
restore seeds those into `SurfacePool.titles`/`directories` as placeholder data without
building anything, and first view spawns a new shell whose working directory is the
recorded cwd (fail-soft: a cwd that no longer is a directory is dropped at restore and
the workspace path is used, exactly like every other degraded field). This supersedes
T-027's "cwd is not persisted" note — that note described the pre-T-031 behaviour where
nothing could render a cwd before a surface existed.

**Teardown is slot-closure only.** `retainOnly(allSlotIDs)` (the only lifecycle call the
app makes, `TenonApp.swift:416`) keeps every catalog slot; tab switches, workspace
switches and focus moves change nothing in the pool. The negative assertions pin object
identity across those operations. Bounded lifetime (invariant 10): the surface, its
title, its directory, its pin and its queued text all die exactly when the slot leaves
the catalog, and a weak-reference assertion proves nothing keeps the surface alive after.

**Hidden viewed panes: renderer occlusion, never PTY teardown.** A card detached on a
tab/workspace switch keeps its surface and PTY; `GhosttyNSView` now tells libghostty
`ghostty_surface_set_occlusion(surface, false)` when it leaves the window and `true` (per
the window's real occlusion state, observed via `didChangeOcclusionStateNotification`)
when it returns, so hidden panes stop paying renderer cost. This is the Kero v0.1.30
"hidden tab renderer memory" trim, host-side.

## Shared with T-029

T-029's core half landed `PaneActivity` with `setViewed(_:at:)`; its `## Handoff to the
app half` names the viewed rule for *attention*: app frontmost AND workspace selected AND
pane displayed on the canvas, with both edges. T-031's predicate is deliberately
different — **"has ever been displayed", latching, no frontmost conjunct** (an unfocused
window still draws its panes, so they must materialize) — but both derive from the same
underlying event: **the canvas pane-display lifecycle**. To keep one producer
(invariant 6):

- The underlying event is "this pane became displayed on the canvas / stopped being
  displayed". Today its only reified producer is the render path's
  `SurfacePool.surface(for:workspacePath:)` call (rising edge; the falling edge has no
  consumer yet and no producer yet).
- T-031 consumes only the rising edge, as the materialization latch
  (`SurfacePool.hasEverBeenViewed(_:)` — true exactly while the slot holds a surface,
  which is one-way until the slot closes).
- When T-029's app half lands, it must produce both edges from the card
  attach/detach lifecycle (SpatialCanvasView) AND the NSApp frontmost signal, and feed
  `PaneActivity.setViewed` from that composition. At that point the same canvas-lifecycle
  producer should drive materialization (the mount edge calls `surface(for:)` — which it
  already does by construction, since mounting is what renders the pane). No second
  computation of "is this pane visible" may appear in the pool: the pool only ever
  *receives* the signal.
- Mapped onto the handoff's (a) ∧ (b) ∧ (c) decomposition: T-031 consumes the rising
  edge of **(c) alone** ((b) is subsumed — only the selected workspace's selected tab
  renders a canvas), and **deliberately not (a)**: an app that is not frontmost still
  draws its window, so a pane displayed there must materialize or it would render
  nothing. Today (c) has no covered-card case — every slot of the visible tab has its
  own frame (`Tab.spatialSlots` is a flat grid; the "Stack" verb is a downward split) —
  so "rendered by the canvas" and "displayed" coincide exactly.
- T-031 leaves every `IdleDetector`/observation feed untouched: `terminalObservation`
  stays a pull the pollers drive at their fixed cadence; nothing here converts that
  feed to events (the handoff's stableSamples caveat).

## Why / evidence
- `SurfacePool.surface(for:workspacePath:)` builds a surface on first call and keeps it in
  `surfaces` (`SurfacePool.swift:49-67`); `docs/research-reference-terminals.md` already
  records that surfaces of inactive workspaces are retained until their slots leave the
  catalog. With one pane per agent, that is the memory curve. (HIGH)
- Kero v0.1.26: *"Sessions you never open no longer cost any GPU memory"* — panes claim
  buffers only when first viewed, and previously viewed panes keep them until closure.
  v0.1.30 additionally reduced hidden Ghostty tab renderer memory.
- The constraint to respect: `research-reference-terminals.md` shows both reference
  terminals independently cure *SwiftUI tearing down the surface kills the PTY* (Kero parks,
  Muxy reparents). So the win here is **never building** a surface for an unviewed pane, and
  trimming renderer cost for hidden ones — not releasing live ones.
- `pendingText` (`SurfacePool.swift:36-39`) is the existing precedent that a slot can be
  addressed before its surface exists; the lazy path must keep that behaviour.

## Criteria
- [x] A slot that has never been viewed has no entry in `SurfacePool.surfaces` and no PTY;
      asserted headlessly by driving the pool, not by looking at a window
      (`testAPaneNobodyViewedBuildsNoSurfaceAndNoReadPathMaterializesOne` — every read,
      write, focus and retain path is hit and the build count stays 0)
- [x] Such a pane still renders something useful — its recorded title and cwd — and
      materializes on first view, with the first frame not losing `pendingText`
      (`SlotRecord.title`/`cwd` persist; restore seeds `SurfacePool.titles`/`directories`
      with no surface; `testFirstViewMaterializesTheSurfaceWithoutLosingQueuedText`
      asserts queued text arrives on the materialization frame through the
      `TerminalSurface.sendText` seam)
- [x] A viewed pane's surface survives tab switches, workspace switches and split changes;
      a test asserts a live PTY is never torn down for memory reasons
      (`testSwitchingTabsWorkspacesOrFocusNeverTearsDownAViewedSurface` pins object
      identity across repeated `retainOnly(allSlotIDs)` — the only lifecycle call the
      shell makes on any workspace mutation, split changes included — plus focus moves)
- [~] Hidden viewed panes cost less than visible ones: `GhosttyNSView` now signals
      `ghostty_surface_set_occlusion(false)` when its card detaches (tab/workspace
      switch) and follows `NSWindow.didChangeOcclusionStateNotification` while attached,
      so hidden panes stop paying renderer frames. **The before/after numbers are NOT
      recorded — deliberately.** `GhosttySurface` is smoke-only by repo convention, this
      session is headless, and a measurement I did not take will not be written down.
      What a human must do: open ~20 terminal tabs, view them all, leave one visible;
      sample `Tenon` in Activity Monitor (memory + GPU/`% GPU` in the GPU tab, or
      `sudo powermetrics --samplers gpu_power`) before/after this change, and confirm
      typing in a hidden pane's shell (via `tenon-cli pane.send`) still works — the PTY
      must never pause, only the renderer.
- [x] Restored-but-unviewed panes from T-027 go through this same path, so a relaunch with
      30 panes does not spawn 30 shells
      (`testARelaunchRestoresManyPanesWithoutSpawningASingleShell` — a real quit→relaunch
      through `AppComposition`: every restored slot has `hasEverBeenViewed == false` and
      the makeSurface counter never moves; `testARestoredPaneShows…SpawnsAFreshShellThere`
      proves first view spawns a FRESH shell in the recorded cwd — nothing resurrects the
      dead process or replays history)
- [x] Surfaces are still released when a slot leaves the catalog (no leak on close) —
      `testASurfaceDiesExactlyWithItsSlotAndLeavesNoStrongReference` keeps the release
      assertion and adds the invariant-10 weak-reference proof that nothing outlives it
- [x] `swift build` + `swift test` green (numbers in the board line); measurement method
      for the renderer trim stated above — the process-resource-monitor collector does
      not exist yet, so Activity Monitor / powermetrics is the stated instrument
