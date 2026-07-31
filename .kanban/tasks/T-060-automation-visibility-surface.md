# T-060: Automation visibility — schedules, Run now, run history
> Automation runs today with zero user-facing surface: schedules exist only in plugin
> manifests and the engine (`AutomationScheduler`), so a user cannot see which automations
> exist, when one fires next, what past firings did, or trigger one by hand. Filed from the
> recorded non-goals of T-046 (`docs/design-automations.md` § "Recorded non-goals").
- **priority**: medium
- **effort**: L

## Owner / files (agent lock)
**RELEASED 01:3x — task done, every file below is FREE.** (Was: session 1d3e1340,
user-directed via /goal; third Doing entry past the WIP pair, same precedent as T-059 —
zero file overlap with T-055 (CoreIntentCatalog/Filesystem/kanban) and T-059
(SpatialCanvas*) locks.) Claimed while active:
- poc/Sources/TenonCore/AutomationScheduler.swift
- poc/Sources/TenonCore/AutomationRunHistory.swift (NEW)
- poc/Sources/TenonCore/PluginHost.swift (automationFired + targeted emit return only)
- poc/Sources/TenonApp/TenonApp.swift (wiring only)
- poc/Sources/TenonApp/SettingsView.swift (Automation section)
- poc/Tests/TenonCoreTests/AutomationSchedulerTests.swift
- poc/Tests/TenonCoreTests/AutomationRunHistoryTests.swift (NEW)
- poc/Tests/TenonCoreTests/AutomationEventDeliveryTests.swift
- docs/design-automations.md (non-goals lines this task retires)

## Rung walk (recorded before code, per criterion 1)
Walked per docs/architecture-interaction-boundaries.md:
- **Listing + history display**: built-in host UI reading `AutomationScheduler` /
  `PluginHost` typed state — same semantic owner, so DIRECT (invariant 6). Not an
  INTENT: built-in app UI has no generic app intent principal (invariant 8). Zero new
  `tenon` members; surface/global pins untouched.
- **Run now**: a host-UI gesture composing two DIRECT calls the owner already has —
  `scheduler.manualFiring` mints the Firing, `host.automationFired` delivers it through
  the SAME single emit site as scheduled firings. What crosses to the plugin stays the
  existing owner-scoped EVENT `automation.fired`, distinguished only by the payload's
  reserved `trigger: "manual"`. No second delivery path exists to diverge.
- **Run history**: host-owned bounded state (invariant 10), recorded at the one place
  firings already flow through. Not a RESOURCE (nothing is handed to a plugin), not an
  EVENT (nobody subscribes to history; the UI reads state).

## Decisions
- `Firing` gains `trigger: .scheduled | .manual`; the emit site stops hardcoding
  `"scheduled"` and reads the firing. Internal memberwise init — nothing outside the
  scheduler constructs Firings (verified by grep before claiming).
- **Manual firing leaves `nextDue` untouched**: Run now answers "did my automation
  work", it does not shift the schedule's phase. Pinned by test.
- **Delivery outcome**: targeted `emit(event:payload:to:)` returns `@discardableResult
  Bool`. T-049's "publisher never learns who listened" governs plugin-facing `publish`,
  which keeps ignoring the return; host-internal delivery outcome is host state.
- **Evidence return path**: each history record carries exactly the facts delivered
  (schedule, scheduledFor, trigger, late) plus the delivery outcome, rendered in the
  row's detail. The plugin's *response* actions are already attributed per-plugin on
  the one policy path / `tenon.log`; a deep link into a log surface is out of scope
  here because that surface does not exist yet — recorded, not hidden.
- History lives on `AutomationScheduler` (the automation owner), capacity-bounded;
  reconcile never touches it, which is what "survives hot reload" means and tests pin.
- `AutomationScheduler` becomes `@Observable` (Observation, not SwiftUI — precedent:
  `PluginHost` at PluginHost.swift:284, same target).

## Scope
- Classify per docs/architecture-interaction-boundaries.md BEFORE code, and record the
  rung walk here. Expected shape: the listing is built-in host UI reading
  `AutomationScheduler` state through a typed service DIRECT (same owner, invariant 6) —
  zero new `tenon` members for display.
- **Listing**: a built-in surface (settings section or palette-reachable view) showing,
  per loaded+enabled plugin: each schedule's id, cadence (`every`/`daily`), and next-due
  time. Disabled plugin → its schedules absent, same rule the scheduler already enforces.
- **Run now**: manual firing of one schedule reuses the reserved `trigger: "manual"`
  payload (`docs/design-automations.md` reserved it for exactly this) through the SAME
  single emit site as scheduled firings — a second delivery path is the two-implementation
  smell invariant 6 forbids.
- **Run history**: recent firings visible with timestamp, trigger (scheduled/manual), and
  an evidence link back to what the firing did — per VISION's evidence-linked compression
  tenet. Bounded buffer (invariant 10); pick and pin the bound.
- OUT OF SCOPE: cross-restart catch-up (persisted last-fired map) — its own card if
  wanted; listed separately in the design doc's non-goals.

## Criteria
- [x] Rung walk recorded in this file before implementation; boundary doc updated if the
      classification adds anything the law does not already say — **it does not**: the
      listing/history/Run-now walk lands entirely on rungs the law already states
      (same-owner DIRECT, existing owner-scoped EVENT), so the boundary doc is
      deliberately untouched.
- [x] A user can see every schedule of loaded+enabled plugins with owner, cadence, and
      next-due time; core rules (what is listed, next-due arithmetic) assert headless in
      `TenonCoreTests` with time as a parameter — Settings ▸ Automation;
      `testListingsExposeActiveSchedulesSortedWithNextDue`,
      `testListingsTrackTheAdvancedPhaseAfterAFiring`.
- [x] "Run now" fires exactly one owner-scoped `automation.fired` with
      `trigger: "manual"` through the existing emit site; a plugin cannot tell the
      delivery mechanism apart from a scheduled firing — pinned end-to-end through the
      real host + real JSC fixture: the plugin's own `automation.fired` handler renders
      `trigger=manual` with the identical event shape
      (`testManualFiringDeliversTheSameEventWithManualTrigger`); the emit site is the
      unchanged `PluginHost.automationFired`.
- [x] Run history is bounded, survives hot reload of the owning plugin, and each entry
      carries a working return path to evidence — capacity 128 newest-first
      (`AutomationRunHistoryTests`), reconcile never touches it
      (`testRecordedRunsSurviveReconcile`; reconcile IS the hot-reload trigger, pinned
      by T-046's lifecycle test), each row renders the delivered facts (schedule,
      scheduled instant, trigger, lateness) + delivery outcome.
- [x] Surface/global pins unchanged unless a new `tenon` member is deliberately added
      and classified — zero new members; the pin tests ran untouched in the green full
      suite.
- [x] Full `swift test` green — **946 / 0**, exit 0 (bar 924 at T-058).

## Evidence (session 1d3e1340, 01:2x–01:3x)
- **RED first**: 42 automation-filtered tests, **10 failures, all assertions, 0
  unexpected** — history newest-first + capacity (×4), listings (×2), manual-firing
  unwrap, history-survives-reconcile, and both delivery pins — against inert stubs;
  the tree kept compiling for peers throughout (type stubs landed with the tests).
- **GREEN**: filtered 42/42; then full `swift test` **946 / 0**, `swift build` exit 0
  under warnings-as-errors.
- **6 mutation proofs, each RED on its named assertion, restores `cmp`-verified
  byte-identical**: M1 append-not-prepend, M2 capacity trim dropped, M3 manual firing
  says scheduled (reddens the core pin AND the real-JS delivery test), M4 armed guard
  dropped (proves the stub-phase-green nil test has teeth), M5 missing session reports
  delivered, M6 reconcile clears history. ⚠️ The script's FINAL sanity run exited 1
  with zero assertion failures — that window coincided with T-055's in-flight edits to
  `CoreIntentCatalog`/`FilesystemIntentProvider`; an immediate rerun was 42/42 exit 0,
  so the red belonged to the peer's mid-edit tree, not this change.
- **Launch smoke**: debug binary alive 8 s, killed clean, log empty (no live Tenon
  instance existed, checked first, so no focus theft).
- Docs in-change: `docs/design-automations.md` — payload bullet now states both
  trigger values affirmatively; shipped surface has its own section; non-goals list
  keeps only the two real remainders (cross-restart catch-up, unattended terminal
  scope) and the stale single-file-scripts bullet (shipped in T-047) is retired.
- Human-verify remaining: the pixels — open Settings ▸ Automation, watch the clock
  schedule's next-firing count down, press Run Now and see the run row appear with
  trigger manual.
