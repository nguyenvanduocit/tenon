# T-046: Automation — manifest schedules fire owner-scoped plugin events
> A plugin declares wall-clock schedules in its manifest; a host-side scheduler fires
> `automation.fired` events at the owning plugin, whose JavaScript then does anything the
> plugin API can do. Tenon's answer to Orca's automations, with JS instead of a prompt DSL.
- **priority**: high
- **effort**: L

## Owner / files (agent lock)
session f014e8e0 — ACTIVE, claimed 03:37.

Files this task will change:
- NEW `poc/Sources/TenonCore/AutomationSchedule.swift` (manifest block model + occurrence math)
- NEW `poc/Sources/TenonCore/AutomationScheduler.swift` (host-side due computation, time as parameter)
- `poc/Sources/TenonCore/PluginManifest.swift` (additive `automation` block)
- `poc/Sources/TenonCore/PluginHost.swift` (additive: `PluginSnapshot.automationSchedules`,
  `automationFired(_:)` targeted-emit helper — nowhere near T-044's terminal files)
- `poc/Sources/TenonApp/TenonApp.swift` (composition: `startAutomationScheduling()`)
- `poc/plugins/clock/manifest.json` + `poc/plugins/clock/main.js` (first consumer — replaces
  its dead `"tick"` subscription that nothing ever emitted)
- NEW `poc/Tests/TenonCoreTests/AutomationScheduleTests.swift`
- NEW `poc/Tests/TenonCoreTests/AutomationSchedulerTests.swift`
- NEW `poc/Tests/TenonCoreTests/AutomationEventDeliveryTests.swift`
- NEW `docs/design-automations.md`
- `docs/architecture-interaction-boundaries.md` — ⚠️ SHARED with T-044's claim. My edits are
  two additive bullets in the EVENT inventory (~:339) and CONTRIBUTION inventory (~:385),
  different sections from T-044's INTENT/lane tables. @247281cf shout on the board if that
  still collides with your in-flight classification edit and I'll hand you the two bullets
  to apply instead.
- `CLAUDE.md` (one phrase: manifest declaration list gains automation schedules)

## Why (research record, 2026-07-31)
Orca's automation unit is `if (one shell precheck exits 0) { paste one prompt string into
one TUI-agent PTY }` on an rrule/cron schedule — no steps, no conditionals, no data flow;
precheck stdout is discarded; completion is inferred by heuristics; two divergent dispatch
implementations (renderer hook vs headless closure); timezone stored but never used
(evidence: refrerences/orca/src/shared/automations-types.ts, automation-schedules.ts:441-467,
useAutomationDispatchEvents.ts, main/index.ts:2067-2155).

Tenon inverts the unit: the automation IS plugin JavaScript. Conditionals, chaining, and
data flow are ordinary JS; actions are the declared intents that already exist
(`process.exec.v1`, `terminal.run.v1`, `workspace.*`, `network.fetch.v1`, …). The host adds
only what JS cannot own: durable wall-clock scheduling that survives reload and fires even
when no plugin timer is armed.

## Interaction classification (written BEFORE code, per the law's change protocol)
- Manifest `automation.schedules` block — **CONTRIBUTION** (rung 1): declarative static
  registration owned by the contributor; host owns validation/reconciliation. Same class as
  `settings` schemas.
- Schedule firing — **EVENT** (rung 2): `automation.fired`, a fact on a host-owned channel,
  delivered owner-scoped via the existing targeted `PluginHost.emit(event:payload:to:)`
  (the `pane.cwd-changed` / views-callback delivery class). No reply, no result, publisher
  never awaits observers.
- The automation's actions — existing **INTENT**s, unchanged policy path; the plugin
  principal, manifest-declared uses, capability grants, and consent all apply exactly as
  for any plugin (invariant 9).
- Scheduler tick driving — host-native same-owner **DIRECT** (`AutomationScheduler` in
  TenonCore, time passed as a parameter; the imperative `Date()`/timer edge lives in
  `AppComposition`, the T-029 `startAttentionPolling` pattern).
- **Zero new `tenon` members.** The runtime-surface inventory and
  `testRuntimeExportsOnlyTheClassifiedPublicSurface` / global-scope pins stay untouched.

## Design (details in docs/design-automations.md, written with this change)
Manifest grammar (strict decode — unknown fields rejected, the palette-block precedent):
```json
"automation": {
  "schedules": [
    { "id": "tick", "every": "1m" },
    { "id": "morning", "daily": "09:00", "grace": "2h" }
  ]
}
```
- exactly one of `every` (duration `<int><s|m|h|d>`, min `1m`, max `7d`) | `daily` ("HH:mm",
  local wall clock — deliberately NO stored timezone, Orca's is dead metadata and wrong);
  ≤ 8 schedules per plugin; ids unique, ≤ 64 bytes; `grace` optional (min `1m`, max `7d`),
  default = one interval for `every`, `6h` for `daily`.
- Sub-minute cadence is deliberately excluded: that is `tenon.timers.every` (RESOURCE),
  which already exists. Schedules are wall-clock automations, not tick sources.
- Missed-run rule (Orca-proven, simplified): on tick, a schedule past due fires AT MOST the
  latest missed occurrence, and only within `grace`; staler misses are skipped silently and
  the schedule advances. `late: true` on the payload when fired > 2 min past due.
- Event payload: `{ scheduleId, scheduledFor: ISO8601, late: Bool, trigger: "scheduled" }`
  (`trigger` reserved for a future manual "Run now").
- Hot reload: reconcile keyed by (pluginID, scheduleID); an unchanged spec keeps its
  `nextDue` (no phase thrash), a changed spec recomputes, vanished specs drop. Only
  `isLoaded && isEnabled` plugins are scheduled. In-memory `nextDue` only — cross-restart
  catch-up persistence is a recorded non-goal for this slice.

## Criteria
- [x] Manifest `automation` block decodes, validates fail-closed (unknown field, dup id,
  both/neither cadence, sub-minute `every`, > 8 schedules all rejected), round-trips, and
  an automation-free manifest is byte-for-byte unaffected.
- [x] Pure occurrence math: `every` advances by interval from `after`; `daily` yields the
  next local HH:mm via `Calendar.nextDate` (DST-safe); both proven without a window.
- [x] `AutomationScheduler.tick(now:)` fires a due schedule exactly once (double tick = one
  firing), skips-and-advances beyond grace, and never invents a firing for a plugin that
  is disabled, unloaded, or gone from the snapshot.
- [x] Reconcile preserves `nextDue` across an unchanged hot reload and recomputes on a
  changed spec — asserted, not trusted.
- [x] `automation.fired` reaches ONLY the owning plugin's runtime (two-plugin test: both
  subscribe, one fires, the other's state provably untouched), and a real fixture plugin's
  JS observably reacts (statusBar) through a real `PluginHost`.
- [x] `PluginSnapshot` carries the declared schedules; `onPluginLifecycleChanged` fires when
  a reload changes them (the reconcile trigger is the existing lifecycle channel).
- [x] clock plugin: dead `"tick"` subscription replaced — shows the time immediately and
  refreshes on its declared `1m` schedule; `ShippedPluginsTests` stays green.
- [x] Boundary doc EVENT + CONTRIBUTION inventories updated in the same change;
  `docs/design-automations.md` records the decision, grammar, and follow-ups
  (single-file scripts T-047, run history, manual trigger).
- [x] `swift build` exit 0 (warnings-as-errors) and full `swift test` green at or above the
  claim-time baseline; RED-first evidence recorded for each new test file.

## Verification (all evidence measured on this tree, 2026-07-31)
- **RED first, 03:51**: all three new suites written against inert stubs (types compiled,
  tree kept building for every concurrent agent) — **33 tests / 54 assertion failures /
  0 unexpected**, each failing for its stated reason (no validation, `tick` returning
  `[]`, snapshot unpopulated).
- **GREEN, 03:54**: real implementation landed — 33/33, `AutomationEventDeliveryTests`
  drives real JavaScriptCore runtimes through a real `PluginHost` (live factory).
- **Mutation table** (each: rule broken → named test red → byte-identical revert via
  `cmp` against a pre-mutation copy):
  | rule broken | red test | result |
  |---|---|---|
  | grace check → `if true` (stale misses fire) | `testTickSkipsBeyondGraceAndAdvances` | RED ✓ |
  | reconcile always recomputes `nextDue` | `testReconcilePreservesPhaseAcrossUnchangedReload` | RED ✓ |
  | targeted emit → broadcast | `testFiringReachesOnlyTheOwningPlugin` | **SURVIVED first run** — the absence assertion raced in-flight delivery. Test strengthened with an ordered probe barrier (`test.probe` emitted after the firing rides the same per-runtime path; B must report `"b:probed"`, a broadcast leaves `"b:fired,probed"`). Retry: RED ✓ with exactly that string |
  | `isLoaded && isEnabled` gate deleted | `testDisabledOrUnloadedPluginNeverSchedules` | RED ✓ (both phantom firings visible) |
  | snapshot population dropped | `testSnapshotCarriesDeclaredSchedules` + lifecycle test | RED ✓ (4 failures) |
  | sub-minute floor deleted at all 3 enforcement points | `testSubMinuteEveryIsRejected` | RED ✓ (both asserts) |
  The M3 survival is the finding worth keeping: an absence assertion without a
  synchronization barrier is vacuous. The probe-barrier pattern is now in the test.
- **Full suite, 04:0x**: `swift build` exit 0 (warnings-as-errors); `swift test` exit 0,
  **838 tests / 0 failures** (claim-time bar 792; +33 mine, +13 T-044's landed mid-slice
  and went green in parallel). Earlier full run at 03:57 showed 9 reds — all in T-044's
  in-flight `ScrollbackPagingTests`/`TerminalIntentProviderTests`, none mine, and they
  cleared when that session landed its implementation.
- **Launch smoke**: built binary alive 8 s on a private `TENON_SOCKET_PATH`, empty log.
- **Docs in-change** (law change protocol §3): boundary doc EVENT inventory gained
  `automation.fired`, CONTRIBUTION inventory gained `automation.schedules`; NEW
  `docs/design-automations.md` (decision record, grammar, worked example verified
  against the real `process.exec.v1`/`ui.toast.v1` contract shapes in
  `CoreIntentCatalog.swift:789-809,1260-1265` and `plugins/git/main.js:108-131`);
  `CLAUDE.md` manifest-declaration sentence extended. Zero new `tenon` members — the
  surface/global-scope pins were deliberately NOT touched.
- **Human-verify remains** (repo convention): watch the clock's status-bar minute tick
  in the running app, and a real 09:00 `daily` firing across a sleep/wake.
- **Independent review (change protocol §7): STILL OWED — recorded honestly.** Two
  reviewer agents ran to completion but the agent-mail transport delivered only idle
  notifications; one truncated preview ("## Review: T-046 Automation Schedules …
  Reviewed all lis") proves a report exists that never arrived, through 5 retrieval
  attempts (SendMessage ×3, task list, file-drop request). In its place the authoring
  session ran a risk-focused audit on the exact reviewer checklist — WEAKER than an
  independent pass, flagged for the next PM sweep to re-run properly:
  - advance-to-latest loop terminates: `.every` ≥ 60 s strictly advances;
    `.daily` uses `Calendar.nextDate(after:)` (strictly after, asserted by
    `testDailyNextOccurrenceFindsNextLocalTime`'s exact-boundary case) with a
    strictly-greater +24 h nil fallback; in-memory state means launch reconcile can
    never see a deep-past `nextDue`, so iteration count is bounded by sleep-while-running;
  - no retain cycle: `wire()`'s lifecycle closure captures the scheduler strongly but
    the scheduler holds no host reference; host/store/webSurfaces stay weak;
  - tick task: double-start guarded (`automationTickTask == nil`), cancelled in
    `stop()`, `[weak self]` + cancellation-throw exit;
  - manifest field regression: NO site encodes/persists `PluginManifest`
    (grep: only preferences + revision use `JSONEncoder`), so the additive field
    cannot corrupt stored artifacts;
  - forgery: `automation.fired` has exactly ONE emit site
    (`PluginHost.swift:1513`, targeted); plugins have no `events.emit`;
  - probe-barrier soundness: B's JS accumulates a log, so the settled final string is
    deterministic regardless of statusBar update interleaving — and the M3 mutation
    run showed exactly `"b:fired,probed"` under broadcast, proving the barrier sees
    a leaked delivery.
