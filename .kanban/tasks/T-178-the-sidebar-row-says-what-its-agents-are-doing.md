# T-178: The sidebar row says what its agents are doing

> The tagline under a workspace name stops counting tabs and starts naming the agent panes
> inside it, one at a time, each with the state its own attention machine is already in.

- **priority**: high
- **effort**: M
- **prd**: `TENON-PRD-001` (`docs/prds/workspace-shell.prd.md`) — new `WS-FR-036`
  (`WS-FR-035` was taken by T-177 while this task was in flight)

## Why

`WorkspaceSidebarView.swift:377` renders `"\(workspace.tabs.count) tabs"`. A tab count is the
one fact about a workspace a supervisor never needs: it is stable, it is derivable from the
tab strip they are already looking at, and it says nothing about whether any agent in there
wants them. The operator asked for the row to carry the work instead — the title of each AI
pane in turn, with a state glyph, scrolling when the title outruns the space.

## What is already true (verified before the first edit)

- `SurfacePool` is `@MainActor @Observable` (`SurfacePool.swift:29`) and carries
  `titles: [UUID: String]` (`:30`) and `paneAttention: [UUID: PaneActivity]` (`:49`) for
  **every** workspace — `:340` records that surfaces of unviewed workspaces are included
  deliberately. The sidebar already holds the pool (`WorkspaceSidebarView.swift:74`).
- `PaneActivityState` is `working / idle / finishedUnseen / seen / exited`
  (`Sources/TenonCore/PaneActivity.swift:19-25`). This is the one attention vocabulary
  (`docs/domains.md`, `attention`), so the glyph reads it and computes nothing.
- A pane's displayed title is `slot.customTitle ?? pool.titles[slot.id]`
  (`BuiltInSlotViews.swift:169-174`). `customTitle` is what `tenon-cli rename` writes, which
  `AgentHarnessText:26-32` instructs every agent to set — so the tagline reads the sentence
  the agent wrote about its own work.
- `SlotContent` has **no** agent-terminal case (`Sources/TenonCore/Workspace.swift:5-21`); a
  live agent runs inside `.terminal`.
- Agent-ness today is `AgentSessionRegistry.boundPanes()` (`AgentSessionHooks.swift:141`) —
  an `actor`, async, unobservable, and lagging by design (`:145-149`: an agent that has not
  run a tool is absent).
- Live hook facts fan out on MainActor through `AgentHookLensBus.deliver`
  (`AgentLensSession.swift:919-929`) into `AgentLensPool.ingest` (`:950-952`), which routes
  only to **already-mounted** models. A pane in a background workspace drops its own facts.
  That gap is the whole reason this task adds a roster.

## Corrections made while building

- **The launch writer was dropped, and decision 1 below is why it was ever specified.** The
  briefing said the hook binding lags an agent until its first tool call. That is true of
  `AgentSessionRegistry`, and only because its own `record` refuses an event with no
  session-bearing payload (`AgentSessionHooks.swift:145-149`). This roster asks for less — a
  pane id and a surface token — and `SessionStart` is in the installed set (`:213`) and reaches
  the bus unfiltered, so a pane is named from the moment the session starts. A second writer
  at the launch site would have been a second path to a fact already covered.
- **The rotation's `TimelineView` sits inside each tagline, not around the row list.** Wrapping
  the list would invalidate every row on every tick; inside, the invalidation is one line of
  text, and a row with fewer than two agent panes mounts no schedule at all — so the common
  sidebar runs zero timers rather than one.
- **The `working` indicator is a pulsing filled dot, not a `ProgressView`.** The first
  offscreen render photographed `working` and `idle` as the same hollow ring: a mini
  `ProgressView` draws as a plain ring in a still frame. Filled-versus-hollow reads without
  depending on motion.

## Decisions taken with the operator

1. An AI pane is one the hooks have bound **plus** one just launched with an agent command.
   *(Second half withdrawn on evidence — see corrections above.)*
2. Glyphs come from the existing `PaneActivity` machine, not from hook event names.
3. A workspace with no AI pane keeps showing `N tabs` unchanged.
4. Fixed ~4 s dwell per pane; horizontal scroll only when the text overflows; then the next.
5. Every row rotates, including rows for workspaces in the background.

## Criteria

- [x] `AgentPaneRoster` answers "is this slot an agent pane" for every workspace, fed by the
      hook bus, keyed by `(paneID, surfaceToken)` so a rebuilt pane inherits nothing.
- [x] The roster is bounded (invariant 10): a slot whose surface is gone or replaced stops
      matching at the read, and the oldest binding is evicted past a stated capacity.
- [x] A pure projection turns (workspace, roster, titles, attention) into an ordered list of
      (slot, title, state), asserted headlessly.
- [x] A pure rotation rule turns (elapsed, count, dwell) into an index, asserted headlessly.
- [x] The row shows one agent pane's title with its state glyph, advancing every 4 s.
- [x] A title wider than the row scrolls horizontally and fades at the edge; one that fits
      does not move.
- [x] `accessibilityReduceMotion` stops the scroll and the rotation shows the first entry.
- [x] Rotation freezes when the app is not active.
- [x] No row without at least two agent panes schedules anything (T-141's rule).
- [x] A workspace with no agent pane still reads `N tabs`.
- [x] `WorkspaceRowAnnouncement` speaks every agent pane once rather than following the
      rotation, and a row with no agent speaks exactly what it always spoke.
- [x] `WS-FR-036` added to `workspace-shell.prd.md` with `.feature` scenarios, four decision
      rows, and a verification receipt.
- [x] `TENON_SIDEBAR_SNAPSHOT` photographs the new tagline at 110 pt and 232 pt, staging four
      states through the real machine and printing the state each pane reached.

## Owed

- **At 110 pt a row that also carries the unseen capsule has ~7 pt of tagline** and shows its
  glyph with no text. Visible in the 110 pt snapshot, rows 2 and 4. The remedy — dropping the
  capsule on a row that is already naming panes, since the per-pane glyph carries the same
  news — changes `WS-FR`-covered behaviour that belongs to the attention rollup, so it is the
  operator's call rather than this task's.
- **An agent that exits leaving its shell alive keeps its line.** Stated in the decision log
  and pinned by `testAnAgentThatExitsLeavingItsShellAliveIsStillNamed`. Closing it means the
  process-group comparison `AgentCallerAdmission` already owns, measured first.
- **No live run against a real agent.** Everything here is proved headlessly and through
  offscreen renders over stub surfaces.

## Owner / files (agent lock)

Claimed by session `ae944786` 2026-08-17 15:5x.

- `Sources/TenonApp/AgentPaneRoster.swift` (new)
- `Sources/TenonApp/WorkspaceAgentTagline.swift` (new)
- `Sources/TenonApp/WorkspaceSidebarView.swift`
- `Sources/TenonApp/WorkspaceIdentityViews.swift`
- `Sources/TenonApp/SidebarSnapshot.swift`
- `Sources/TenonApp/AgentLensSession.swift` (the bus gains a second sink, ~6 lines)
- `Sources/TenonApp/AgentIntentProvider.swift` (the launch path notes the pane)
- `Sources/TenonApp/TenonApp.swift` (composition)
- `Tests/TenonAppStateTests/WorkspaceAgentTaglineTests.swift` (new)
- `Tests/TenonAppStateTests/AgentPaneRosterTests.swift` (new)
- `Tests/TenonAppStateTests/WorkspaceIdentityFormTests.swift`
- `docs/prds/workspace-shell.prd.md`, `docs/prds/workspace-shell.feature`
- `docs/domains.md` (if a tag needs declaring)
- `Tenon.xcodeproj/project.pbxproj` (regenerated by `xcodegen`)

None of these are held by T-177, T-176, T-144, T-141, T-140 or T-135. T-177 holds
`ShellTitleBar.swift`, `ContentView.swift`, `WorkspaceStatusBar.swift`, `TitleBarSnapshot.swift`,
`AppPreferences.swift` and `SettingsView.swift` — this task touches none of them.
`AgentLensSession.swift` and `AgentIntentProvider.swift` are unheld; T-141 holds
`AgentLensView.swift`, which is a different file.
