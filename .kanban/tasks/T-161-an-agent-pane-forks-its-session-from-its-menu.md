# T-161: An agent pane forks its session from its header menu
> Right-clicking a live agent pane's title bar offers Copy Resume Command and Fork Session; Fork opens a fresh terminal beside the pane and launches the provider's own fork of that session.
- **priority**: medium
- **effort**: M
- **requirements**: `SP-FR-029` (PRD spatial-panes, new)

## Design (verified against the tree, 2026-08-14)
- The one command speller grows a continuation mode: `AgentLaunchComposer` spells fork as
  `--resume <id> --fork-session` for Claude Code and `fork <id>` for Codex — both verified
  against the installed CLIs' `--help` on this machine. Cross-provider fork stays the
  transcript-handoff prompt it already is.
- `AgentSessionResume.offer(for:installed:continuation:)` composes both offers, so the menu
  states its refusal reason before the click (same rule as the `+ Resume` button).
- The menu learns the pane's session from the pane's own lens:
  `AgentLensPool.resolution(for:)` reads the model the mounted pane already holds, and
  `AgentPaneSessionCapture.reference` applies the same `.exact`-confidence gate the catalog
  save uses. No session → the menu is exactly today's menu.
- Fork placement composes existing public ops: `WorkspaceStore.duplicateSlot` (a fresh shell
  beside the pane, anchored on the forked pane, not the focused one) + set-diff to find the
  new slot + `SurfacePool.sendTextWhenReady` to queue the fork command for the shell.
  No TenonCore edit needed — deliberate, to stay off T-160's claimed core files.

## Criteria
- [x] Composer: fork spelling per provider, red first (`AgentLaunchCommandTests` — 4 fork
      assertions red against the resume spelling, green after).
- [x] Offer: fork continuation composes/refuses with stated reason (`AgentSessionResumeTests`).
- [x] Canvas: live agent pane menu offers both items; plain terminal menu unchanged
      (existing pinned-order test untouched and passing); copy routes through a test seam;
      fork opens a terminal beside and queues the command, asserted off the stub surface's
      `sentText` (`SpatialCanvasInteractionTests`, 5 new tests).
- [x] PRD: SP-FR-029 added, SP-FR-008 restated for the conditional items, feature scenarios,
      delivery matrix row, decision log + receipt. Also recorded (not fixed): the PRD carries
      two distinct requirements both numbered `SP-FR-028`.
- [x] Full suite: 2273 / 2, both failures outside this scope and non-reproducing in
      isolation (T-160's then-in-flight move test; `CLISocketServerTests` peer-pid under
      concurrent-build load, the T-134 flaky-wait shape).

## Coordination
`SpatialCanvasNSView.swift`, `SpatialCanvasInteractionTests.swift`, and the spatial-panes
PRD pair are also claimed by T-160 (session `d43ed512`). Regions are disjoint (T-160: drag
routing ~752-870 + SP-FR-014; T-161: `slotContextMenu` ~554-624 + SP-FR-029). Coordination
message sent to that session 2026-08-14 15:4x; commits announced on the same channel.

## Owner / files (agent lock) — session `1ddd16bc`
- Sources/TenonApp/AgentLaunchCommand.swift
- Sources/TenonApp/AgentSessionResume.swift
- Sources/TenonApp/AgentLensSession.swift
- Sources/TenonApp/Canvas/SpatialCanvasNSView.swift (shared with T-160 — menu region only)
- Tests/TenonAppStateTests/AgentLaunchCommandTests.swift
- Tests/TenonAppStateTests/AgentSessionResumeTests.swift
- Tests/TenonAppStateTests/SpatialCanvasInteractionTests.swift (shared with T-160 — menu tests only)
- docs/prds/spatial-panes.prd.md (shared with T-160 — SP-FR-029/SP-FR-008 only)
- docs/prds/spatial-panes.feature (shared with T-160 — SP-FR-029 scenarios only)
