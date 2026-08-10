# T-100: A Chrome-style Resource Monitor
> Provide a live, native task-manager view of CPU, memory, network, and ownership across Tenon, workspaces, tabs, panes, and their child processes.

- **priority**: high
- **effort**: L

## Criteria
- [x] A host-owned Resource Monitor presents one expandable hierarchy: Tenon App → workspace → tab → pane → process → child process, with stable identity and no process counted twice.
- [x] Rows expose current CPU, resident memory, PID where applicable, sample freshness, and supported cumulative/delta I/O metrics; network receive/send is included only where macOS supplies a reliable per-process value.
- [x] A feasibility spike establishes the signed-app semantics and cost of per-process network attribution before UI wiring. Unsupported, shared, or unreadable metrics render as unavailable/shared with a reason—never as zero and never apportioned heuristically among panes.
- [x] Terminal process ownership follows stable PTY provenance and the full reachable child tree, surviving process-group changes and PID reuse through `(pid, start time)` identity.
- [x] Host, WebKit, plugin-runtime, helper, or other shared processes appear in an explicit host/shared group unless the runtime exposes a proven pane owner. A pane without an exclusive OS process remains visible with unavailable host metrics rather than receiving invented values.
- [x] Workspace, tab, and pane aggregates update correctly as panes move, tabs/workspaces switch, processes spawn/exit, and inactive workspaces remain retained; stale in-flight samples cannot publish under obsolete ownership.
- [x] The monitor supports sorting, expanding/collapsing, keyboard navigation, VoiceOver, and focusing/revealing the owning pane, following `docs/designs.md` with no feature-local geometry or color tokens.
- [x] Sampling, process traversal, counter deltas, and aggregation run off the main thread; one sample is in flight, refreshes coalesce, history and process counts are bounded, and periodic sampling stops when no monitor surface is visible.
- [x] Partial permission failures and process churn preserve healthy rows and the last good snapshot with explicit loading/partial/stale/error states; a collector failure never masquerades as an empty system.
- [x] Collection is local and observational: no command line, environment, terminal contents, file contents, or secrets are recorded; this task does not terminate processes, close panes, or expose telemetry to plugins, CLI, or agents.
- [x] The 2026-07-30 design snapshot at `docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md` is revalidated and updated before implementation, including current `docs/designs.md`, domain tags, performance receipts, and the normative interaction inventory.
- [x] Built-in SwiftUI uses a typed DIRECT telemetry service; the repeating sampler has bounded host-private RESOURCE/STREAM/TASK lifecycle semantics under `docs/architecture-interaction-boundaries.md`, with no new public intent or `tenon` path.
- [~] Deterministic tests cover ownership, deduplication, PID reuse, first/delta samples, values over 100% CPU, aggregation, process churn, unavailable/shared network metrics, lifecycle cancellation, stale-result rejection, and capacity limits; a signed Release build verifies real process data and sampling overhead. — **tests done (67), signed Release verification NOT done** (see Limits).

## What was measured before anything was built

Phase 0 was four native probes, not a literature review. Results, on Darwin 25.4 / arm64,
`mach_timebase` 125/3, 637 live PIDs:

| Figure | API | Verdict |
|---|---|---|
| CPU | `rusage_info_v4.ri_user_time + ri_system_time` (already ns) | supported, p95 1.00 µs |
| RSS | `pti_resident_size` | supported, p95 0.71 µs |
| Identity | `ri_proc_start_abstime` | supported, distinct per process |
| Disk I/O | `ri_diskio_bytesread` / `_byteswritten` | supported, free in the call identity already needs |
| **Network** | — | **none exists** |

Network was refused on measurement, not on taste: zero network fields across all 36
`rusage_info_v4` and 18 `proc_taskinfo` members; `PROC_PIDFDSOCKETINFO` read on a live socket
exposes `sbi_cc`/`sbi_hiwat`/… — *current buffer occupancy*, from which no transferred-bytes
delta can be taken; `nettop` measured at **5,243 ms per sample** against a 2-second cadence.
So there is no network column. The absence is stated once in the popover footer and typed as
`TelemetryValue<Never2>`, a value that can only ever be `.unavailable(.noPublicPerProcessAPI)`.

**Three conventions the July design had wrong, each of which produces a confident wrong number
rather than an error:**

1. `proc_listchildpids` returns an **entry count**; `proc_listpids` returns **bytes**. Under the
   wrong one a shell with five live descendants reported `attached-but-not-reached: [5 pids]` —
   the root renders, the subtree silently vanishes. This is what the first probe actually did,
   and it was diagnosed rather than coded around.
2. A dead process returns **`0` with `errno == ESRCH`** from `proc_pidinfo` and leaves the
   caller's struct untouched — i.e. all zeros. Every loose check (`>= 0`, `!= -1`) turns an
   exited process into a live one using no CPU and no memory.
3. `e_tdev` is `UInt32.max`, not `0`, when there is no controlling terminal.

Two more findings changed the shape: the title bar has **no "Add Slot" control** any more (the
trigger sits before `QuickCommandControl`), and the specified **460 pt** popover width belongs
to no band in `designs.md` — it is 480 pt, the focused-panel bound, which is what "no
feature-local geometry tokens" asks for. Traversal is tree-local rather than a machine-wide
sweep: 32 panes' worth of roots costs **p95 0.195 ms** against a 50 ms budget, while a full
`PROC_ALL_PIDS` sweep costs p95 1.26 ms idle and was measured at **p95 56 ms** under build load,
because its cost scales with the machine rather than with Tenon.

## Evidence

Full suite **1836 / 0**, confirmed on two consecutive runs. 67 focused tests: `ProcessTelemetryTests` 41,
`ProcessTelemetryCoordinatorTests` 15, `TerminalProcessProjectionTests` 11 (real pty, real
`libproc`, real process trees created and killed by the test). Fitness gates green:
`DirectInventoryGateTests` 3, `DomainTagFitnessTests` 5, `InteractionBoundaryFitnessTests` 20.

**Order of work was implementation-then-test**, so mutation testing carries the red-first
evidence rather than a recorded failing run. Five mutations, each its own run with a
`cmp`-verified restore — **and two of them found real holes before they were caught**:

| # | Mutation | Result |
|---|---|---|
| M1 | `didFill` accepts `>= 0` (the ESRCH trap) | **survived twice**, then caught |
| M2 | child count divided by `pid_t` stride | caught (3 tests) |
| M3 | `ProcessIdentity` equality is PID-only | **survived once**, then caught |
| M4 | provenance-drift check disabled | caught |
| M5 | subtree walk descends into children another pane owns | **survived**, then caught |

- **M1 survived twice and exposed a vacuous test.** `testAnExitedProcessProducesNoRowRatherThanAZeroedOne`
  killed the whole tree, leaving no roots — so its assertion loop never ran and it was green for
  nothing. Rewritten to keep the shell alive and kill one child. Even then the mutation survived,
  because `sh` reaps its children before any sweep sees them, so **no dead PID is ever presented
  to the sampler**. The honest fix was to stop pretending a race could test it: the return-code
  rule is now `DarwinProcessSampler.didFill(returnCode:expecting:)`, a named function pinned
  directly against the shapes `proc_pidinfo` actually produces (`0` = gone, short read = half
  zeros). The mutation is caught by three assertions.
- **M3's first form was an ineffective mutation, not a passing test.** Making `startAbstime` a
  computed `0` left the stored property in place, and synthesized `Hashable` still distinguished
  the two identities. Re-applied as a real PID-only `==`/`hash`, it was caught — and caught
  precisely: the reused PID inherited the previous occupant's counter and reported
  `counterWentBackwards` where the truth is `firstObservation`.
- **M5 found a missing test.** Ownership already refuses to hand one identity to two panes, but
  nothing built a *snapshot* for a child whose own TTY belongs to a different pane than its
  parent's. `testAChildOwnedByAnotherPaneIsNotAlsoDrawnUnderItsParent` now does; under the
  mutation pane A reports 600 bytes instead of 100 and the tree holds 4 identities instead of 3.

One design flaw was found by a test rather than by review: aggregating a single unavailable
value flattened its reason to `.unreadable`, so a pane whose only process was on its first
observation reported the vaguest possible answer. Aggregates now keep a unanimous reason.

## Limits — stated, not sold past

1. **No signed Release verification.** Criterion 12's second half is not done. What *is*
   established: the app carries no entitlements file, no sandbox, and no hardened runtime
   (`codesign -dv` on the installed bundle shows `flags=0x2(adhoc)` only), so nothing can
   restrict `libproc` for same-user processes — but that is a sound argument, not a receipt.
   The performance numbers come from `swiftc -O` probes, not a Release app run.
2. **Not run in the app.** Launching would need a restart, which kills other sessions' panes.
   The popover has never been photographed: `PaneViewSnapshotWriter` renders *pane* content and
   the monitor is title-bar chrome, so no offscreen renderer reaches it. Given T-055 and T-096
   both shipped layout bugs that passed their tests, **treat the visual result as unverified.**
3. **No XCUITest**, and no live multi-workspace topology comparison against `ps`.
4. **The detached-but-reachable branch is covered only by synthetic sample sets.** macOS ships
   no `/usr/bin/setsid`, so no real process was made to leave its controlling terminal while
   staying reachable.
5. **`CLISocketServerTests` failed once in the first full run and not in the second** (`testTheRequestCapCoversTheReplyNotOnlyTheDecode`,
   permit exhaustion) and passes 20/0 in isolation. Untouched since Aug 7 and unrelated to this
   change — a load-flaky socket test, recorded here so the next reader does not re-diagnose it.

## Owner / files (agent lock)

## Owner / files (agent lock)

**RELEASED 2026-08-10 14:2x — session `e3ac726b` holds nothing.** Every file below is free.
`ShellTitleBar.swift` was contested at claim time and became free when T-105 reached Done;
`TenonApp.swift` is T-071's and took a deliberately surgical edit (one stored property, one
`@ObservationIgnored` property, one construction block beside `terminalSurfaces`, one argument
at the `ContentView` call site) — all droppable if it conflicts with their work.

Files touched:

- `Sources/TenonCore/ProcessTelemetry.swift` (NEW)
- `Sources/TenonCore/ProcessTelemetryCoordinator.swift` (NEW)
- `Sources/TenonApp/DarwinProcessSampler.swift` (NEW)
- `Sources/TenonApp/ProcessTelemetryBridge.swift` (NEW)
- `Sources/TenonApp/ResourceMonitorView.swift` (NEW)
- `Tests/TenonCoreTests/ProcessTelemetryTests.swift` (NEW)
- `Tests/TenonCoreTests/ProcessTelemetryCoordinatorTests.swift` (NEW)
- `Tests/TenonAppStateTests/TerminalProcessProjectionTests.swift` (NEW)
- `Sources/TenonApp/TerminalSurface.swift` — one protocol member
- `Sources/TenonApp/GhosttySurface.swift` — its implementation
- `Sources/TenonApp/SurfacePool.swift` — the provenance snapshot
- `docs/architecture-interaction-boundaries.md` — DIRECT inventory entry
- `docs/domains.md` — the new domain
- `docs/prds/diagnostics-and-resource-monitor.prd.md` / `.feature`
- `docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md` — revalidation
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` — released by T-101/T-071

- `Sources/TenonApp/ShellTitleBar.swift` — the trigger in `rightZone`
- `Sources/TenonApp/TenonApp.swift` — composition (surgical, see above)
- `Sources/TenonApp/ContentView.swift` — one property, one argument
- `Tests/TenonCoreTests/DirectInventoryGateTests.swift` — the new entry's pin

## Notes
- This is the live Chrome Task Manager-style view. T-092's bounded health journal and stall detector remain the post-incident evidence path; this task does not duplicate or replace them.
- CPU and memory already have a detailed native `libproc` design baseline. Network attribution is deliberately gated by a feasibility receipt because shared WebKit/network helpers and OS API availability can make per-pane numbers unknowable.
- The first version is read-only. Process termination or resource limits require their own authority, safety, and interaction design.
