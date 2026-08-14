# T-147: An agent can say what it is doing, on the tab that shows it

> A Settings page installs Tenon's harness into the operator's global agent instructions,
> and the capability that harness describes — an agent renaming its own pane — is built
> in the same change so the instructions are true the day they land.

- **priority**: high
- **effort**: L
- **PRDs**: `TENON-PRD-004` (settings page), `TENON-PRD-003` (pane title as public capability),
  `TENON-PRD-011` (public intent inventory), `TENON-PRD-007` (CLI verb)

## Why

The operator asked for a Settings page beside CLI that installs a short Tenon briefing into
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and a Claude skill — so an agent starting inside
Tenon knows where it is and can rename its pane to say what it is working on.

Two facts made the briefing unwritable as asked, and the operator chose the fix over the
workaround after seeing both:

1. `TENON_PANEL_ID` and `TENON_TAB_ID` do not exist. The PTY environment is
   `TENON_PANE_ID`, `TENON_SOCKET_PATH`, `TENON_AGENT_HOOK_SCRIPT`,
   `TENON_AGENT_SURFACE_TOKEN`, `TENON_AGENT_HOOK_PORT/TOKEN`, `CODEX_HOME`
   (`Sources/TenonApp/TenonApp.swift:508-519`).
2. **No agent can rename anything.** The host can — `Workspace.renameSlot`
   (`Sources/TenonCore/Workspace.swift:1053`) writes `customTitle`, which the tab chip reads
   at `ShellTitleBar.swift:654` — but none of the 59 entries in `CoreIntentName` exposes it,
   and `tenon-cli` has no verb for it. `agent.rename.v1` (`AC-FR-026`) is a workspace-local
   *alias* for an agent and is `planned`, not the pane chrome.

Installing instructions for a capability that does not exist would teach every agent on this
machine a command that fails. So the capability ships first, and the harness describes it.

## Criteria

- [x] `workspace.pane.title.set.v1` exists in `CoreIntentName` and the catalog, audiences
      `{plugin, cli, agent}`, scope-identified pane, `.write` effects, `workspaceControl`
      binding; an empty title clears back to the content-derived title.
- [x] `WorkspaceIntentProvider` serves it through `WorkspaceStore.renameSlot` — no second
      semantic path (invariant 6).
- [x] `tenon-cli rename [--pane <uuid>] <text...>` compiles to that intent and falls back to
      `$TENON_PANE_ID`, like every other pane-scoped verb.
- [x] Every terminal surface — agent pane or not — exports `TENON_TAB_ID` and
      `TENON_WORKSPACE_ID` alongside `TENON_PANE_ID`.
- [x] The harness text states those two are a spawn-time snapshot and names
      `workspace.pane.owner.v1` as the live answer, because a pane can move between tabs.
- [x] Settings shows an "Agent Harness" page beside CLI whose Install button writes a
      marker-delimited managed section to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`
      and a skill to `~/.claude/skills/tenon/SKILL.md`.
- [x] Installing twice changes nothing the second time, and editing the harness text and
      reinstalling replaces the managed section without touching a byte outside the markers.
- [x] PRD-003/004/007/011 carry the new requirements with a dated verification receipt.

## Owner / files (agent lock)

Released 2026-08-14 — shipped by session `b3278b63`, full suite 2203 / 0. No file here is held.
