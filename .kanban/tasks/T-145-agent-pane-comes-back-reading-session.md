# T-145: An agent pane comes back reading its own session
> A terminal pane that was running an agent when the app quit restores as the recorded-session
> reading — the same pane "Details" opens from the session list — instead of a blank shell.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-001` workspace-shell (restoration), requirement `WS-FR-027`

## Why

`SlotContent.agentSession` already survives a restart (`WorkspaceCatalogStore.swift:482-549`), so a
pane opened from the Agent Sessions list comes back reading its transcript with `+ Resume` on it.
A pane that had the agent *live* in a PTY records `type: "terminal"`
(`WorkspaceCatalogStore.swift:466`) and comes back as an empty shell: the session id and transcript
path are only in `AgentSessionRegistry`, which is in-memory (`AgentSessionHooks.swift:79-93`) and
dies with the process. The reading, the summary, and the one-click resume are all lost at quit for
exactly the panes that were doing the work.

## Decisions (operator, 2026-08-13)

- **Eligibility**: only a pane whose foreground process is still the agent at capture time — the
  `.exact` branch, read through `AgentLensDiscovery.boundSession` (hook binding + declared process
  group matches the live foreground pid). A pane where the agent already exited and a shell took over stays a
  terminal.
- **Fallback**: the record keeps `type: "terminal"` and carries the session beside it. Restore
  prefers the reading and degrades to a shell in the pane's own cwd when the transcript is gone —
  never to `.empty`. An older build reading the same file sees a plain terminal.
- **No second control**: the restored pane keeps `+ Resume` as its only conversion, asked and
  answered after the change was working. A pane wanting a bare shell is closed and reopened.

## Owner / files (agent lock)

Released 2026-08-13 16:5x — session `6bc4f9c5` holds nothing.

What it changed: `WorkspaceCatalogStore.swift`, `AgentPaneSessionCapture.swift` (new),
`AgentLensSources.swift`, `TenonApp.swift`, `WorkspaceCatalogPersistenceTests.swift`,
`AgentPaneSessionCaptureTests.swift` (new), `workspace-shell.prd.md`/`.feature`.

`AgentLensSources.swift` was added to the list mid-task and is the one file that needed a
reason: the capture first called `AgentLensDiscovery.resolve`, whose opening `provider(for:)`
forks `/bin/ps` on a cold per-surface verdict — which every pane in an unmounted tab is — on
every catalog mutation. `boundSession` is the same branch `resolve` returns first, extracted so
both callers go through one function. Every other `AgentLens*` source was left alone: they carry
another session's uncommitted work.

## Criteria

- [x] A live agent pane is captured as `terminal` + its `AgentSessionRecord`; a shell pane is not
- [x] Restore turns that record into `.agentSession(ref)` when the transcript is readable
- [x] Restore degrades it to `.terminal` (with cwd) when the transcript is gone or absent
- [x] A document written by an older build (no session field) still restores as `.terminal`
- [x] Only `.exact` resolutions carrying both a session id and a transcript become a reference
- [x] `WS-FR-027` stated in the PRD with a scenario in `workspace-shell.feature`
- [x] `swift build` + `swift test` green on the scope

## Result

Shipped 2026-08-13. `AgentPaneSessionCaptureTests` 9/0, `WorkspaceCatalogPersistenceTests` 26/0,
full suite **2120/0** — run twice, before and after the discovery extraction. Both new behaviours
were red before the change, and the `.exact` guard killed a mutation admitting `.inferred`.

Owed, and not claimed as done:

- **the live journey** — no test drives a real agent through a quit and a relaunch; the capture
  is asserted against the resolver's verdict, not against a PTY.
- **`xcodegen generate`** for the two new files, at commit time. CI regenerates and diffs the
  pbxproj; it was not run here because regenerating now would write another session's untracked
  files into a shared, committed artifact.
