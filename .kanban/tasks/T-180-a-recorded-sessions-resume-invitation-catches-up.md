# T-180: A recorded session's résumé invitation catches up
> Operator-reported: a recorded-session pane's Terminal tab said "Claude Code is not
> installed on this machine" while Claude Code was demonstrably running — the resume
> offer froze at whatever `agentSuggestions` was on the pane's first render.

- **priority**: high
- **effort**: XS

## Owner / files (agent lock)

**RELEASED 2026-08-18 by session `a2486dad`.** No file below is held any longer.
- `Sources/TenonApp/Canvas/SpatialSlotCardView.swift`
- `Tests/TenonAppStateTests/SpatialCanvasInteractionTests.swift`
- `docs/prds/spatial-panes.prd.md`
- `docs/prds/spatial-panes.feature`
- `.kanban/board.md`

## What was reported

Screenshot of an Agent Lens recorded-session pane, Terminal tab: "This session has
already happened... Claude Code is not installed on this machine, so this session
cannot be continued here." `claude` is genuinely installed at `~/.local/bin/claude`
(verified: `test -x`, symlink resolves to a valid Mach-O executable) and is the CLI
running this very session.

## Root cause

`AgentSessionResume.offer(for:installed:)` (`AgentSessionResume.swift:44`) is computed
fresh on every `BuiltInSlotContentView.body` evaluation for `.agentSession` content
(`BuiltInSlotViews.swift:123`), from the `agentSuggestions` array threaded down from
`ContentView`'s one-shot `.task { agentSuggestions = await AgentLaunchDetector.scanLive() }`
(`ContentView.swift:177`) — a scan measured at ~2.1s (T-175).

But `SpatialSlotCardView.configure` only rebuilds that content tree when its cache
key (`contentKey`) changes, and the key's `agentSuffix` — the part that encodes
`agentSuggestions` — is gated on `slot.content == .empty` only
(`SpatialSlotCardView.swift:672-677`). `.agentSession` panes were left out, even
though they read `agentSuggestions` exactly the way `.empty` panes do. Combined with
`.agentSession`'s `busValue` also being independent of `agentSuggestions`
(`Workspace.swift:63-67`), the key never changes for this content kind — so a
recorded-session pane opened before the ~2.1s scan resolves freezes its résumé offer
at `agentSuggestions == []` forever, even after detection correctly finds `claude`.

`.agentSession` carries no live PTY/WebView to protect from a rebuild (the whole
point of the cache guard for other content kinds) — the same reasoning that already
exempts `.empty` from the guard applies here.

## Criteria

- [x] A failing test demonstrates `SpatialSlotCardView.contentKey` (and therefore the
      mounted `AgentSessionResumeView`) does not change for `.agentSession` content
      when `agentSuggestions` changes from `[]` to a real detection result.
- [x] `SpatialSlotCardView.swift`'s `agentSuffix` also covers `.agentSession`, so the
      card rebuilds once detection answers.
- [x] `spatial-panes.prd.md` gains a requirement for this (no existing SP-FR covered
      "the résumé invitation must not freeze stale") with a Gherkin scenario and a
      decision-log entry.
- [x] `swift test` green, scope and full suite.

## Verification receipt (2026-08-18)

Red first: `testAgentSessionContentRebuildsWhenAgentDetectionResolves` failed on identical
`contentKey` before/after `agentSuggestions` changed. Fix: `SpatialSlotCardView.swift`'s
cache-key gate (`readsAgentSuggestions`) now covers `.agentSession` beside `.empty`. Green
after. Scope `SpatialCanvasInteractionTests` **75 / 0**. Full suite **2361 / 0** (one prior
same-session run reported 2361/1 with the failing test name outside the captured tail; an
immediate re-run reproduced 0 failures — see the PRD receipt for the full note). Added
`SP-FR-030` to `spatial-panes.prd.md` (requirement row, acceptance-spec row, delivery-matrix
row, decision log, verification receipt, change history) and a matching scenario to
`spatial-panes.feature`. No new source file, so no `xcodegen generate` is owed. Not committed.
