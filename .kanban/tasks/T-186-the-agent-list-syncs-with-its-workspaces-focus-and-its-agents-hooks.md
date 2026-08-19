# T-186: The agent list syncs with its workspace's focus, and with its agents' own hooks
> Operator-reported, two mismatches in the sidebar's expanded agent account (WS-FR-036).
> (a) A row's agent-list text stayed full-weight even when its workspace lost focus and its
> name muted. (b) An interactive agent session that had genuinely finished a turn still read
> `idle`, because OSC 133 never fires between an interactive agent's turns.
- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
Released — DONE 2026-08-19, this session. Built additively on top of uncommitted WIP already
in these files from earlier sessions (`git status` showed them modified before this task
started); confirmed via `ListAgents` that no peer session currently holds them (only
`tenon-3a`/`53210b` connected, unrelated). Touched: `Sources/TenonApp/WorkspaceSidebarView.swift`
(`AgentListRow`/`WorkspaceAgentList` take `isActive`), `Sources/TenonApp/TerminalSurface.swift`
(new `noteAgentTurnFinished()` protocol requirement + stub), `Sources/TenonApp/GhosttySurface.swift`
(its implementation), `Sources/TenonApp/SurfacePool.swift` (`noteAgentTurnFinished(for:)`),
`Sources/TenonApp/AgentLensSession.swift` (`AgentHookLensBus`'s third sink + `isRootTurnBoundary`),
`Sources/TenonApp/TenonApp.swift` (one `attach` call), `Tests/TenonAppStateTests/PaneAttentionTests.swift`,
`Tests/TenonAppStateTests/AgentPaneRosterTests.swift`, `docs/prds/workspace-shell.prd.md`.

## What was reported
(a) Screenshot: an inactive workspace's name reads muted, but its still-open agent account
below it keeps full-weight text — the two disagree about whether this row belongs to the
workspace you're currently looking at.

(b) Screenshot: a live Claude session that had just finished answering a question showed the
sidebar's hollow "idle" circle, not a finished/seen glyph, while two other rows (spawned by
one-shot `claude -p` automations that actually exit) correctly showed the finished state.

## Root cause (b)
`PaneActivity.Observation.commandFinishedCount` (`PaneActivity.swift`) is fed exclusively from
`GHOSTTY_ACTION_COMMAND_FINISHED` — OSC 133, "a foreground shell command just finished"
(`GhosttySurface.swift:396-400`). An interactive agent REPL (`claude`, `codex`, `opencode` run
without `-p`) *is* the shell's one foreground command for the whole session; finishing one turn
never returns to the shell prompt, so the counter never rises mid-session. The pane can only
ever poll into `.working` (screen still changing) or `.idle` (screen stable) — `.finishedUnseen`
and `.seen` are unreachable for exactly the sessions a person spends the most time watching. A
one-shot `claude -p "..."` invocation *does* exit as a real foreground command, which is why
those rows read correctly and the bug looked selective rather than universal.

## Fix
(a) `AgentListRow` takes the same `isActive` its parent `WorkspaceRow` already computes,
threaded through `WorkspaceAgentList`, and mutes its title with the identical
`isActive ? TenonTheme.text : TenonTheme.muted` the workspace name itself uses (`WorkspaceSidebarView.swift:486`).

(b) `TerminalSurface` gains `noteAgentTurnFinished()` — a second way to report the same fact
`commandFinishedCount` already models, so `PaneActivity` needed no change: it treats a rise in
that counter as one fact regardless of which seam reported it. `AgentHookLensBus` (`AgentLensSession.swift`)
gains a third sink, `SurfacePool`, alongside its existing `AgentLensPool`/`AgentPaneRoster` ones;
on a hook event where `isRootTurnBoundary` holds — `hookEventName == "Stop"` and `agentID == nil`,
the same subagent guard `AgentPaneRoster.ingest` already applies to this stream — it calls
`SurfacePool.noteAgentTurnFinished(for: event.paneID)`, which reaches the pane's real surface
and bumps its counter exactly as a genuine OSC 133 finish would.

## Criteria
- [x] A workspace row's agent-list text is muted exactly when the row's own name is muted
- [x] An interactive agent's `Stop` hook (root session) reaches the pane's `PaneActivity` as a
      finish, indistinguishable from a real OSC 133 command-finished
- [x] A subagent's `Stop` does not count as the pane's own turn finishing
- [x] `swift build` clean, full `swift test` **2383 / 0** (was 2379 / 0 before this task; +4 new)
- [x] `workspace-shell.prd.md` decision log restated for `WS-FR-036`'s fifth pass; delivery
      matrix files/tests/receipts updated
- [ ] Owed: a live install check — whether a real hook server actually delivers `Stop` for an
      interactive session the way the composed test fixtures assume is installed-app-only, same
      category as this requirement's other owed hover/click checks

## Follow-up, same session (2026-08-19, later)
Operator asked for a third mismatch: the agent-list row's text read at the same 11 pt as the
workspace name above it — no size step to say the account is the row's nested detail, not a
peer. `AgentListRow`'s title dropped to 10 pt (`interfaceFont(size: 10)`, `WorkspaceSidebarView.swift`),
one step under the workspace name's 11 pt; weight stays `.regular` against the name's
`.bold`/`.semibold`, so the two differ on both axes now instead of weight alone.
`swift build` clean. Verification note: a concurrent peer session's `xcodebuild -configuration
Release` build (confirmed via `ps aux`, unrelated to this task) loaded the machine to a 4-7
load average during the full-suite run, which took 3377 s instead of the usual ~155 s and
surfaced **1 unexplained failure among 2383** — not isolated by name because the run was piped
through `tail -15`, which discarded the per-test failure line. Re-running the three files this
change and the rest of this task actually touch — `PaneAttentionTests`, `AgentPaneRosterTests`,
`WorkspaceIdentityFormTests` — gave **44 / 44** in 1.1 s, clean of that contention. No test in
this repo asserts an exact SwiftUI font size, and a `CGFloat` literal has no path to a timing-
sensitive assertion, so the full-suite failure reads as load-induced flake rather than caused by
this change — **not re-run clean end-to-end to fully confirm**, flagged here rather than
claimed silently.
