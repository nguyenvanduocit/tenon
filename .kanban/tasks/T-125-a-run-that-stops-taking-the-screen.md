# T-125: A run that stops taking the screen

> An automation firing opens a pane on its own; the operator asked for the opposite —
> the panel appears when they go looking for a run, not when a schedule decides to.

- **priority**: high
- **effort**: M
- **PRD**: `docs/prds/automations.prd.md` (TENON-PRD-013)

## Owner / files (agent lock)

**NO OWNER. Lock cleared 2026-08-12** — session `819627d6` stopped writing, so every file
below is free for the next agent to claim:

- `Sources/TenonApp/AutomationSlotView.swift`
- `Sources/TenonApp/TenonApp.swift` — the `AutomationPaneActions` wiring only (lines ~40-70)
- `Tests/TenonAppStateTests/AutomationRunDetailTests.swift`
- `docs/prds/automations.prd.md`, `docs/prds/automations.feature`

Outside the repo, and therefore outside every other agent's tree:

- `~/Library/Application Support/Tenon/plugins/git-auto-update.js`
- `~/Library/Application Support/Tenon/user-plugins/supremor-vault-sync.js`
- `~/Library/Application Support/Tenon/user-plugins/supremor-watch.js`

## Status 2026-08-12 — stays in Doing, and why

Every criterion below is ticked and the change is in the shared working tree. It is **not**
in Done because **nothing outside the building session ever checked it**. T-123, T-124,
T-126 and T-132 each had an adversarial pass re-run their receipts and attack their claims;
T-125 had none, so the only evidence for it is its own word, and that is not the bar this
repository uses. Moving it to Done needs a verifier who re-runs
`swift test --filter Automation` and reads the three plugin files, not a fresh session
re-doing the work.

Owed before it can close:

- The fold-in named under "Left for whoever holds the next lock" below, now unblocked.
- Someone clicking a row in a running app: `AU-NFR-009` is `partial` because the host still
  permits a firing to open a pane, and nobody has seen the panel appear behind a run row.

## What is actually wrong

The host never opens a pane when a schedule fires; three installed plugins do it
themselves, inside their own `automation.fired` handler:

- `git-auto-update.js:209-213` — every `manual` trigger sends `workspace.content.open.v1`.
- `supremor-vault-sync.js:331` (scheduled run in a bad state) and `:405` (manual trigger).
- `supremor-watch.js:150` (scheduled run in an alerting state) and `:233` (manual trigger).

So a schedule the operator never asked about takes a pane, and the pane it takes shows
current plugin state rather than the run that caused it. The Automation pane already
holds the runs — `AutomationActivityRow` (`Sources/TenonApp/AutomationSlotView.swift:1097`)
renders one row per `AutomationRunRecord` — but a row is inert text with no way through
to the plugin that produced it.

## Criteria

- [x] No installed plugin opens a pane from an `automation.fired` handler; the removed
      `openPanel` helpers, their `workspace.content.open.v1` manifest `uses` entries, and
      any variable that existed only to gate them are gone with them, not left dead.
      Evidence: `rg 'workspace.content.open.v1|workspace.control|openPanel|lastAlertKey|PLUGIN_ID|shouldAlert'`
      over the three files returns nothing, and each passes `node --check`.
      `workspace.control` went too — `CoreIntentCatalog.swift:1726,1751` binds it to
      `workspace.content.open.v1` alone, and no other intent these files send needs it.
- [x] Every signal that previously reached the operator only through a stolen pane still
      reaches them. The two supremor plugins gained `statusLine()` +
      `tenon.statusBar.set(...)`, which is in the permission-free tier
      (`PluginManifest.swift:85-91`) and clears on `null` (`PluginRuntime.swift:1057`).
      `git-auto-update.js` needed none: its open fired only on a manual Run Now, so it
      carried discoverability, not a finding.
- [x] An activity row in the Automation pane is a control: activating it opens the owning
      plugin's registered shared view as ordinary workspace content, through
      `store.openContent(.pluginView(...))` — the typed call `workspace.content.open.v1`
      itself adapts (`WorkspaceStore.swift:216-219`).
- [x] A row whose plugin registers no shared view is not a dead control — `runDetail`
      returns nil and the row draws as plain evidence.
- [x] The choice of which view a row opens is a pure projection
      (`AutomationPanePresentation.runDetail(for:in:)`), asserted headlessly with no window.
- [x] `docs/prds/automations.prd.md` carries `AU-FR-029`, `AU-NFR-009`, their
      delivery-matrix row, a decision-log entry and a dated receipt;
      `docs/prds/automations.feature` carries both scenarios. 29 FR + 9 NFR = 38, and
      every one of the 38 is named by a scenario tag.
- [x] Tests green over the automation surface: `swift test --filter Automation` → 83/0.
      Full suite: 1898 executed, 26 failures, **all** in `AgentReadingOptionsTests` (T-123's
      in-flight red) plus one in T-124's `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics`.
      Zero failures in this task's scope.

## Left for whoever holds the next lock

`Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift:959-962` lists the typed DIRECT
surface of `AutomationPaneActions` field by field — `runNow`, `setPaused`, `createWithAI` —
and `openRunDetail` belongs in that list. T-124 held the file when this ran, so the assertion
lives in `AutomationRunDetailTests.testThePaneOpensARunPanelThroughTypedHostActionsOnly`
instead — same claim, same instrument, wrong file.

**The lock is clear now** (T-124 released 2026-08-11 22:2x), and both halves were re-read on
2026-08-12: the field really is absent from the enumeration, and it really exists at
`Sources/TenonApp/AutomationSlotView.swift:15`. The insertion is one line after `:962`:

```swift
"let openRunDetail: (PluginID, String) -> Void",
```

optionally with `"actions.openRunDetail("` beside the existing `"actions.setPaused("` entry.
