# T-092: The app records its own health
> When Tenon froze for two hours, everything known about it had to be reconstructed from
> outside with `sample` and `heap`, after 10 GB had already swapped. The app should have
> been the one holding that evidence.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)

Session `efc4afbd` holds:
`poc/Sources/TenonCore/RunloopHealth.swift` (new),
`poc/Sources/TenonCore/DiagnosticsJournal.swift` (new),
`poc/Sources/TenonApp/TenonLog.swift` (new),
`poc/Sources/TenonApp/DiagnosticsRuntime.swift` (new),
`poc/Tests/TenonCoreTests/RunloopHealthTests.swift` (new),
`poc/Tests/TenonCoreTests/DiagnosticsJournalTests.swift` (new),
`poc/Sources/TenonApp/DiagnosticsCommands.swift` (new),
`poc/Tests/TenonAppStateTests/DiagnosticsRuntimeTests.swift` (new),
`poc/Sources/TenonApp/AppStatePaths.swift` (one computed path),
`poc/Sources/TenonApp/GhosttySurface.swift` + `CLISocketServer.swift` (NSLog call sites only),
`docs/design-diagnostics.md` (new), `docs/README.md` (two index rows),
`docs/domains.md` (APPEND ONLY — another agent has it dirty; one new section, nothing else touched).

⚠️ **`poc/Sources/TenonApp/TenonApp.swift` is claimed by T-071** (since 15:0x). Touched anyway,
deliberately and minimally: 4 hunks, 12 lines — two stored properties, their construction in
`init`, one `diagnostics.start()` at the top of `performStart`, one menu row. The file was
clean in the working tree at 22:0x, so nothing was overwritten. If T-071 conflicts, these
hunks are small enough to re-apply by hand.

## Why

The T-091 hang was diagnosed entirely from outside the process: `sample` for the stack,
`heap` for the undrained autorelease pool, `.recent-views.json` for what was on screen,
`log show` to bracket the time. Every one of those was available only because the process
was still alive when a human noticed. Nothing was recorded, so a hang that ends in a force
quit leaves nothing at all.

The app already knows the things that mattered and never writes them down: whether its
runloop is still completing turns, how many SwiftUI update turns it has run, how much
memory it holds, and which panes are open.

## Shape

**Functional core, imperative shell** — the decision is pure and headless, the clock and
the runloop are not.

- `RunloopHealth` (TenonCore, pure): fed `beat(at:)` when the main runloop completes a
  turn and `probe(at:)` from a watchdog, it decides `healthy` / `stalled(since:)` /
  `recovered`. Reports a stall ONCE per episode rather than every probe. No Foundation
  clock, no threads — times are passed in, so the whole state machine is testable in
  `TenonCoreTests` without a window. That is the fitness test from CLAUDE.md.
- `DiagnosticsJournal` (TenonCore): append-only, **bounded** records on disk under
  `Application Support/Tenon/diagnostics/`. Bounded because invariant 10 says every queue
  and lifetime is; an unbounded diagnostics file is its own outage.
- `TenonLog` (TenonApp): one `os.Logger` per category, replacing the five scattered
  `NSLog` calls so the app's own output is filterable in `log show` by subsystem.
- `DiagnosticsRuntime` (TenonApp): installs the CFRunLoopObserver that beats, a
  `DispatchSourceTimer` on a background queue that probes — the probe MUST NOT be on the
  main queue, because a stalled main queue would stop the very thing detecting the stall —
  and writes what it learns to the journal and the log.
- Export: one command that folds the journal into a single shareable file. Same-owner
  DIRECT under `docs/architecture-interaction-boundaries.md`; no new intent, no new
  capability.

## Criteria
- [x] `RunloopHealth` decides stall/recovery from injected times only, and reports each
      stall episode exactly once — 8 tests, no sleeping. Mutation-verified 3/3: measuring
      the stall from the probe instead of the last beat, dropping the escalation guard, and
      failing to clear the stall on recovery each turn the suite red
- [x] `DiagnosticsJournal` is bounded: 6 tests, including one that appends 200 more records
      past the ceiling and asserts the file does not grow. Mutation-verified: removing the
      trim, and trimming the newest instead of the oldest, both fail
- [x] The probe runs off the main queue — `testTheWatchdogStillFiresWhileTheMainThreadIsBlocked`
      spins the main thread for 1.5s and requires a record anyway. Moving the timer to
      `DispatchQueue.main` fails it with an empty journal, which is the proof
- [x] The five `NSLog` call sites go through `TenonLog` (`com.firegroup.tenon`, categories
      `terminal` / `cli` / `diagnostics`)
- [x] Export produces one file containing the journal, read back by a test; the menu item
      is same-owner DIRECT behind an `NSSavePanel`
- [x] Domain `diagnostics` declared in `docs/domains.md` with an Excludes line; all five new
      source files carry their `@domain:` tag
- [x] `docs/design-diagnostics.md` records what is collected, what is bounded, and what is
      deliberately never collected (no terminal contents, no titles, no paths)
- [x] `swift test` green across the suite — **1445 tests, 0 failures** (1420 before this task;
      20 of the 25 added are these three suites)
- [x] Verified in the installed Release app (PID 44385): the journal appeared at
      `Application Support/Tenon/diagnostics/health.jsonl` carrying
      `{"kind":"launch","figures":{"footprintMB":"116"},…}`, and `log show --predicate
      'subsystem == "com.firegroup.tenon"'` returns the app's own lines under the
      `diagnostics` and `cli` categories. A healthy app is otherwise silent, which is the
      intent — os_log carries stalls, not heartbeats.

- [x] The **Export Diagnostics…** menu item was clicked in the running app and wrote
      `~/Downloads/tenon-diagnostics.txt` (107 bytes):

      Tenon diagnostics export
      records: 1

      2026-08-07T15:38:12Z  [launch]  diagnostics started  (footprintMB=116)

Every criterion is met. One observation from reading the real output: timestamps are UTC
(`15:38:12Z` for a 22:38 local event). Unambiguous, and the right choice for lining an
export up against `log show` — but a person skimming their own export reads a seven-hour
lie unless they notice the `Z`. Worth a local-time column or a stated timezone in the
header; noted rather than changed, because it is a product call about who the export is
for.
