# Process Resource Monitor Design

**Status:** Revalidated and implemented — see the revalidation record below before reading further
**Date:** 2026-07-30, revalidated 2026-08-10 (T-100)
**Baseline:** `de0de44c760e94f5650185272c0cdba6d8106ebb`

## Revalidation record — 2026-08-10 (T-100, `DRM-FR-044`)

Everything below this section is the original July design. It was measured against the current
source and against macOS itself before any of it was built, and it survived mostly intact. What
follows is what the measurements changed. Where this section and the original text disagree,
**this section is normative**.

### The feasibility spike (criterion 3)

Four probes, run on this machine (Darwin 25.4, arm64, `mach_timebase` 125/3, 637 live PIDs).
The scripts are throwaway; their results are not:

| Figure | Public API | Verdict |
|---|---|---|
| CPU | `PROC_PIDTASKINFO` cumulative user+system, or `rusage_info_v4.ri_user_time`/`ri_system_time` | **supported**, p95 0.71 µs / 1.00 µs per process |
| Resident memory | `pti_resident_size` / `ri_resident_size` | **supported** |
| Process identity | `rusage_info_v4.ri_proc_start_abstime` | **supported**, distinct per process, cheap |
| Disk I/O | `ri_diskio_bytesread` / `ri_diskio_byteswritten` | **supported**, cumulative, arrives free in the rusage call already needed for identity |
| **Network per process** | none | **UNSUPPORTED — removed from scope** |

Network was measured, not assumed. `rusage_info_v4` has 36 fields and `proc_taskinfo` 18; none
carries a network counter. `PROC_PIDFDSOCKETINFO` was read on a live socket-holding process and
exposes `sbi_cc` / `sbi_hiwat` / `sbi_mbcnt` / `sbi_mbmax` / `sbi_lowat` / `sbi_flags` /
`sbi_timeo` — *current buffer occupancy*, not bytes transferred, so no delta can be taken from
it. The only user-space source is `nettop`, which cost **5,243 ms** for a single sample: two and
a half thousand times the entire per-sample budget, for a subprocess, at a two-second cadence.

The decision this forces: **there is no network column.** The absence is stated once in the
popover footer and carried in the model as `TelemetryValue<Never2>`, a type that can only ever
be `.unavailable(.noPublicPerProcessAPI)`. A column of em dashes would have read as "no
traffic", which is the exact failure this task's criteria forbid.

### What the original design got wrong

1. **`proc_listchildpids` returns an entry count; `proc_listpids` returns a byte count.** The
   original text treats them as one API. Dividing the former by `MemoryLayout<pid_t>.size`
   turns three children into zero — a shell's whole subtree silently vanishing while the root
   still renders. Measured directly: a shell with five live descendants reported
   `attached-but-not-reached: [5 pids]` under the wrong convention and `[]` under the right one.
2. **A dead process returns `0` from `proc_pidinfo`, not a negative, and leaves the struct
   zeroed** (`rc=0, errno=ESRCH`, measured). The design's error handling assumed failure was
   detectable as a bad return. Only `rc == MemoryLayout<T>.size` means the read happened; a
   `rc >= 0` check reports an exited process as live, idle, and using no memory.
3. **`e_tdev` is `UInt32.max` when there is no controlling terminal**, not `0`.
4. **The title bar has no "Add Slot" control.** The design places the trigger "immediately
   before the existing Add Slot control"; `rightZone` today holds the tab strip, a drag area,
   and `QuickCommandControl`. The trigger sits before `QuickCommandControl` — same intent
   (host chrome, trailing, never `WorkspaceStatusBar`), a control that exists.
5. **The popover was specified at 460 pt wide, which belongs to no band in `designs.md`** —
   compact popovers are 300–320 pt and focused panels 480–560 pt. 460 was a feature-local
   number. It is **480 pt**, the low bound of the band it actually belongs to, which is what
   criterion 7's "no feature-local geometry tokens" asks for.
6. **Traversal is tree-local, not a machine-wide sweep.** Both were measured: walking only the
   panes' own trees costs p50 0.064 ms / p95 0.132 ms, and simulating 32 panes' worth of roots
   costs p95 0.195 ms — against a 50 ms budget. A full `PROC_ALL_PIDS` sweep costs p50 0.90 ms
   / p95 1.26 ms on an idle machine and was measured at **p95 56 ms** under concurrent build
   load, because its cost scales with everything running rather than with Tenon's panes. Of 637
   PIDs, 202 are unreadable (other users) — a sweep would also have to explain 202 rows it
   cannot read.
7. **CPU needs no `mach_timebase_info` conversion where the design says it does.**
   `proc_pid_rusage` reports `ri_user_time`/`ri_system_time` already in nanoseconds. Applying
   the conversion to them would scale every CPU figure by ~41 on Apple silicon. The conversion
   is only needed for `PROC_PIDTASKINFO`'s mach-absolute ticks, which this implementation does
   not use for CPU.

### What the original design got right and is kept

PTY provenance from `ghostty_surface_tty_name` (confirmed present at `ghostty.h:1166`, freed
exactly once through `defer`); `(pid, start abstime)` identity; direct-TTY-then-nearest-root
ownership with a slot-UUID tie-break; one global claim set; the app row sampling `getpid()`
alone; interval CPU uncapped and allowed above 100%; RSS with checked addition; the seven-state
model; sixty history samples on aggregates only; one sample in flight with one coalesced
follow-up; generation and provenance-revision rejection; the 2/4/8/16/30 backoff ladder; the
4,096-identity cap; DIRECT classification with no public surface.

### Additions the original design did not have

- **Disk I/O columns**, because the spike proved they are free and reliable.
- **An explicit `hostShared` group.** The original text says non-terminal slots simply do not
  appear; T-100's criteria require unattributable processes to be *visible* and named as
  shared. They are now a group of their own rather than an omission.
- **A unanimous-reason rule for aggregates.** An aggregate of children that all failed the same
  way keeps that reason instead of flattening to a vague "unreadable" — found by a test that
  caught a pane reporting `unreadable` when the truth was `firstObservation`.

### Still outstanding after this pass

- No signed **Release** benchmark receipt: the numbers above are `swiftc -O` probes, and the
  app is ad-hoc signed with no sandbox and no hardened runtime (`codesign -dv` shows
  `flags=0x2(adhoc)` only, no entitlements file in the tree), so no entitlement can restrict
  `libproc` here. That reasoning is sound but is not the same thing as a Release receipt.
- **No `setsid`-detached case was exercised**: macOS ships no `/usr/bin/setsid`, so the
  "reachable but not TTY-attached" branch is covered by unit tests over synthetic sample sets
  rather than by a real detached process.
- No XCUITest, and no live multi-workspace topology comparison against `ps`.

## Goal

Tenon will provide a native Resource Monitor for the local processes owned by its
terminal panes. It will show current CPU and resident memory at app, workspace, tab,
pane, and process levels, update while the monitor is visible, and preserve the
trigger-and-popover experience of Orca's Resource Manager.

The feature is observational. It may focus or reveal a pane, but it does not terminate
processes, close panes, restart services, or expose telemetry to plugins, the CLI, or
agents.

## Evidence baseline

The installed Orca 1.4.159 Resource Manager:

- opens from a compact resource summary into a detail popover;
- starts with registered local PTY roots and attributes their reachable descendants;
- deduplicates process identities across terminal sessions;
- aggregates by repository, workspace, and terminal;
- displays CPU, RSS, physical-memory share, and short memory history;
- refreshes immediately and then every two seconds while the popover is open;
- keeps process-management actions separate from telemetry rows.

Orca executes `ps -eo pid=,ppid=,pcpu=,rss=`. That is reference behavior, not the
Tenon implementation choice. On macOS, `ps` CPU is a decaying average over up to one
minute, a sample spawns and parses another process, and RSS is reported in KiB. Its
collector can also turn a `ps` failure into an apparently empty snapshot.

Tenon currently has no CPU or memory collector. `GhosttySurface` exposes only
`ghostty_surface_foreground_pid`; `TerminalSurface` and `SurfacePool` do not expose a
stable process provenance value. The pinned Ghostty API also exposes
`ghostty_surface_tty_name`, which is stable for the lifetime of a terminal surface and
is the correct provenance seam. Slot UUIDs are globally unique, and `SurfacePool`
retains surfaces belonging to inactive workspaces until their slots leave the catalog.

The native feasibility probes established:

- `proc_listpids(PROC_TTY_ONLY, ttyDevice, ...)` finds processes attached to a PTY;
- `proc_listchildpids` can traverse child processes without a `ps` subprocess;
- `proc_pidinfo` and `proc_pid_rusage` expose parentage, RSS, cumulative CPU counters,
  and absolute process-start identity for same-user terminal processes;
- CPU counters must be converted with `mach_timebase_info`;
- native per-process sampling measured approximately 1.57 microseconds in the probe,
  versus approximately 66.74 milliseconds for one `Process`-based `ps` sample.

These probes demonstrate feasibility, not completion. The signed application remains
a required verification surface.

Tenon's TDD law requires deterministic domain and boundary rules in `TenonCore`, tested
headlessly before the shell is wired. `TenonApp` contains Ghostty, Darwin, MainActor,
and SwiftUI adapters only.

## User experience

### Entry point

`ShellTitleBar.rightZone` gains a host-owned **Resources** button immediately before
the existing Add Slot control. The button is not placed in `WorkspaceStatusBar`,
because that strip is explicitly reserved for plugin contributions.

At normal width the trigger shows:

```text
[resource icon] 1.2 GB · 6 panes
```

At constrained width it collapses to the icon. Its tooltip and accessibility value
include the last sample time, CPU, RSS, and pane count. Closing the popover stops
periodic sampling, so the trigger exposes freshness instead of presenting the last
value as current.

### Popover

The popover is approximately 460 points wide and 520 points high. It contains:

1. global CPU, RSS, physical-memory share, pane count, and last-update time;
2. a two-minute aggregate memory sparkline;
3. sortable Name, CPU, and Memory headers;
4. an expandable hierarchy:

```text
Tenon
├── Tenon App
└── Workspace
    └── Tab
        └── Terminal pane
            └── Process
                └── Child process
```

The Tenon App row samples only `getpid()` and is never attributed to a terminal pane.
It matches Orca's separation of application overhead from terminal workloads without
claiming shell descendants as host overhead. Non-terminal slots do not appear as
zero-valued process rows.

Workspace, tab, and pane rows show aggregate values. Process rows show executable
name, PID, CPU, and RSS. The foreground process receives a presentation marker, but
foreground PID never determines ownership.

Default sorting is Memory descending. Sorting applies within sibling groups and never
flattens the hierarchy. Ties use normalized display name, then stable identity. CPU
and Memory headers toggle ascending and descending order; Name toggles lexical order.

Memory sparklines exist only for Tenon, workspace, tab, and pane aggregates. Raw
process rows show current values without allocating a history ring per PID.

Selecting a pane or process row and pressing Return focuses and reveals its pane
through the existing typed workspace service. This is navigation, not process control.

### Presentation semantics

- CPU is formatted with one decimal place and may exceed 100% when work spans cores.
- Memory is RSS and uses IEC units (`KiB`, `MiB`, `GiB`).
- The first valid process sample shows CPU as an em dash because there is no delta.
- A missing value is never displayed as zero.
- Physical-memory share is aggregate RSS divided by `ProcessInfo.physicalMemory`.
- Snapshot time combines a monotonic sample sequence with wall-clock presentation.

### State model

- `loading`: no successful snapshot exists; a compact skeleton appears after 300 ms;
- `ready`: the latest complete snapshot is displayed;
- `paused`: periodic sampling is stopped because no monitor surface is visible;
- `empty`: sampling succeeded and no local terminal processes exist;
- `partial`: useful data exists, but one or more panes or processes could not be read;
- `stale`: the last good snapshot remains visible after a collector-level failure;
- `error`: no usable snapshot exists; an inline diagnostic and Retry button appear.

`ESRCH` during a sweep is normal process churn. It removes that identity from the new
snapshot and may make the snapshot partial; it does not fail the complete sample.
Permission and malformed-data failures are row-local when healthy rows remain.
A collector failure never becomes an empty snapshot.

### Keyboard and accessibility

- The trigger label is `Open Resource Monitor`.
- Its accessibility value contains aggregate CPU, RSS, pane count, and freshness.
- Opening moves focus to the tree; Escape closes and restores trigger focus.
- Up/Down move through visible rows.
- Left collapses a row or moves to its parent.
- Right expands a row or moves to its first child.
- Home/End move to the first/last visible row.
- Space expands or collapses; Return focuses the related pane.
- Sort headers are buttons with selected direction.
- Rows expose outline level, expanded state, name, PID where applicable, CPU, and RSS.
- Sampling updates do not create VoiceOver live announcements. Only transitions to
  ready, stale, or error are announced.

## Scope

### Included

- local Ghostty terminal panes in active and inactive retained workspaces;
- Tenon app self metrics;
- PTY provenance, root discovery, descendant traversal, and global deduplication;
- interval CPU and RSS;
- app/workspace/tab/pane/process hierarchy;
- two-minute aggregate RSS history;
- title-bar trigger, popover, sorting, navigation, keyboard, and VoiceOver behavior;
- loading, empty, partial, stale, paused, and error handling;
- unit, hosted-app, real-Ghostty integration, UI, performance, and signed-app proof.

### Excluded

- killing a process, foreground job, pane subtree, or all sessions;
- restarting a daemon or cleaning inactive workspaces;
- remote SSH processes that execute on another machine;
- processes that fully daemonize, detach from the PTY tree, and reparent outside every
  reachable terminal root;
- plugin, CLI, agent, palette, or registered-keybinding telemetry APIs;
- long-term persistence, export, alerting, cross-machine monitoring, or non-Darwin
  sampling backends.

## Interaction classification

The built-in SwiftUI shell observes local terminal resource snapshots and invokes safe
pane navigation.

- **Semantic owner:** `TenonCore`, `TenonApp`, and built-in SwiftUI ship together as
  one host owner.
- **Callers:** built-in SwiftUI only; no public adapter principal.
- **Callee:** a typed core telemetry coordinator plus existing typed pane navigation.
- **Result cardinality:** one initial snapshot and multiple immutable snapshots while
  a monitor surface is visible.
- **Lifetime:** host-private, visibility-scoped, cancellable sampling session.
- **Authority:** read-only inspection of Tenon's same-user local process trees.
- **Failure semantics:** typed unavailable, partial, stale, and terminal error states.
- **Backpressure:** one in-flight sample, at most one coalesced pending refresh, fixed
  process and history capacities, lifecycle and provenance revision checks.

The SwiftUI-to-service call is **DIRECT** because it remains within one semantic owner.
The repeating sampler has internal **RESOURCE / STREAM / TASK** lifecycle semantics,
but it is not a public resource protocol. No `IntentValue`, dispatcher, core intent,
public `tenon` path, scoped facility, event channel, or contribution is added.

The implementation updates the DIRECT inventory description and architecture fitness
coverage so future changes cannot silently route built-in UI through the intent
dispatcher. `WorkspaceStatusBar` remains plugin-only.

## Architecture

### Functional core: `TenonCore`

`ProcessTelemetry`

- defines typed provenance, raw process records, process identity, ownership,
  diagnostics, aggregates, history entries, and UI-independent snapshot state;
- maps current raw records plus previous CPU counters into deterministic values;
- owns graph traversal rules, ownership, deduplication, CPU calculation, RSS
  aggregation, stable sorting, state transitions, and bounded history behavior;
- imports no AppKit, SwiftUI, GhosttyKit, or Darwin process API.

`ProcessTelemetryCoordinator`

- depends on injected typed sampler, monotonic clock, and provenance snapshot functions;
- owns visibility demand, previous counters, lifecycle generation, provenance revision,
  retry backoff, history, one-in-flight admission, and one coalesced pending refresh;
- rejects late results when either lifecycle generation or provenance revision changes;
- emits immutable snapshots without knowing how the shell renders them.

Every rule in these two components is testable in `TenonCoreTests` without a window.

### Imperative shell: `TenonApp`

`TerminalSurface`

- exposes optional `ttyName` and optional `foregroundPID`;
- provides identity metadata only and performs no sampling.

`GhosttySurface`

- calls `ghostty_surface_tty_name`;
- copies the returned bytes into an owned Swift string;
- calls `ghostty_string_free` exactly once with `defer`;
- retains foreground PID as presentation metadata.

`SurfacePool`

- provides a small MainActor provenance snapshot keyed by slot UUID;
- includes workspace/tab/pane metadata, TTY name, and foreground PID;
- preserves inactive retained surfaces and removes deleted slots.

`DarwinProcessSampler`

- implements the core sampler seam outside `MainActor`;
- resolves TTY paths and reads `getpid()` plus native process records;
- discovers roots and descendants through libproc;
- returns immutable raw records without ownership, aggregation, history, retry, or UI
  decisions.

`ProcessTelemetryBridge`

- snapshots `WorkspaceStore` and `SurfacePool` on `MainActor`;
- maintains one monotonic provenance revision that changes when catalog ownership,
  slot membership, surface membership, or TTY metadata changes;
- rechecks the revision before publication;
- requests one immediate replacement after discarding a stale in-flight result.

`ResourceMonitorModel`

- is MainActor-isolated;
- binds core snapshot values to SwiftUI;
- controls open/closed demand and invokes existing typed pane-focus navigation;
- contains no graph, metric, sorting, error, or retry rule.

`ResourceMonitorButton` and `ResourceMonitorPopover`

- render trigger, summary, hierarchy, states, sorting, history, and accessibility;
- contain no sampling or process-ownership logic.

`AppComposition`

- constructs sampler, core coordinator, bridge, model, and UI dependencies;
- cancels the coordinator during application shutdown.

## Provenance and traversal

1. On the MainActor, snapshot every retained terminal surface as
   `(provenanceRevision, slotID, workspaceID, tabID, ttyName, foregroundPID)`.
2. Off-main, validate each TTY path as a character device and resolve `st_rdev`.
3. For each device, call `proc_listpids(PROC_TTY_ONLY, device, ...)`.
4. Read every attached PID into a raw record with PID, PPID, process group, TTY device,
   executable name, cumulative user/system ticks, RSS, and absolute start time.
5. A topmost TTY root is an attached identity whose current parent is not another
   attached identity on the same TTY. Multiple topmost roots are allowed.
6. Traverse `proc_listchildpids` breadth-first from every root. Re-read identity and
   parent information before accepting a child. A visited identity set prevents PID
   reuse, malformed parentage, or cycles from inheriting counters or looping.
7. A process directly attached to a pane's TTY belongs to that pane. A reachable
   descendant without a direct TTY match belongs to the nearest root. If overlapping
   ancestry reaches the same identity, direct TTY ownership wins; otherwise shortest
   depth wins, then lexicographic slot UUID breaks an exact tie.
8. Apply one global claimed-identity set before aggregation. One process identity
   contributes RSS and CPU exactly once across Tenon.
9. Processes reachable from a TTY root remain included after changing process group or
   dropping their controlling TTY. A process that fully reparents outside the reachable
   root tree leaves terminal ownership.
10. Foreground PID marks a row only after `(PID, start time)` resolves inside the owning
    pane. It never changes roots or aggregate ownership.
11. Independently read `getpid()` into one host record using the same absolute start
    identity, cumulative CPU counters, and RSS fields. Project it only into Tenon App.
    Do not traverse host children because terminal shells are also host descendants.
12. Before publication, compare captured provenance revision with the current revision.
    On drift, discard the projection, evict deleted keys, and coalesce one immediate
    replacement. Never publish stale workspace/tab/pane ownership.

Identity is `(pid, processStartAbstime)`, not PID alone. Failed identity reads are
partial-row diagnostics, not guessed identities.

## Metric semantics

### CPU

`PROC_PIDTASKINFO` supplies cumulative user and system CPU ticks. The sampler converts
their sum through the current `mach_timebase_info` numerator and denominator.

```text
cpuPercent =
  100 × (currentCPUTimeNs - previousCPUTimeNs) / elapsedMonotonicNs
```

The result is unavailable for the first observation, zero/negative elapsed time,
counter decrease, changed start identity, or unreadable sample. Values are not
normalized by logical CPU count and are not capped at 100%. If no child has a valid
delta, aggregate CPU is unavailable rather than zero.

### Memory

RSS comes from the native task/rusage record in bytes. Aggregate RSS uses checked
addition over globally claimed identities. Overflow produces a partial snapshot and
an unavailable aggregate; it never wraps.

Physical footprint may be retained in validation diagnostics, but it is not a public
UI field because Orca parity and the requested Memory column use RSS.

## Sampling lifecycle and capacity

- After app readiness and the first provenance snapshot, take one initial sample.
- Opening the popover requests an immediate sample and one every two seconds.
- Closing the last monitor surface cancels periodic demand after a short native-call
  boundary and retains the last good snapshot as paused.
- Reopening requests an immediate sample.
- A tick during an active sample becomes one coalesced pending refresh.
- Ten ticks during a slow sample still produce at most the active sample and one
  follow-up.
- Start/stop increments lifecycle generation.
- Closing, moving, reopening, or reassigning a slot increments provenance revision.
- A result with stale generation or provenance is discarded before publication.
- App shutdown cancels demand and awaits coordinator quiescence.
- Fatal consecutive errors back off at 2, 4, 8, 16, then 30 seconds while visible.
- Manual Retry bypasses the delay once without creating another in-flight sample.

Capacity is fixed:

- at most 4,096 process identities per global snapshot;
- roots visited by stable slot UUID and descendants by breadth-first PID/start order;
- cap overflow returns an explicit partial/truncated snapshot;
- exactly 60 history samples per Tenon/workspace/tab/pane key;
- deleted keys evicted immediately and unseen keys after ten minutes;
- no per-process history;
- no unbounded task, callback, queue, history, or process set.

## Performance budgets and evidence

- Native reads, traversal, projection, and aggregation perform no work on `MainActor`.
- MainActor publication and SwiftUI binding remain below 2 ms p95.
- A 32-pane, 1,000-process sample remains below 50 ms p95.

Receipts use a Release build and record hardware model, CPU count, memory, macOS
version, source SHA, and build command. Each benchmark performs 20 unmeasured warm-up
iterations followed by 200 measured iterations. p95 is the nearest-rank value at
sorted index `ceil(0.95 × count) - 1`. Raw durations and summary are retained in
`.build/evidence/process-resource-monitor-performance.json`.

These are release budgets, not claims established by the feasibility micro-probe.

## Failure, privacy, and security

- Only local process metadata available to the same macOS user is read.
- No command line, environment, terminal output, file content, or secret is collected.
- Process name and PID remain inside the local app UI.
- `EPERM` or unreadable PID produces a partial diagnostic without guessed data.
- Invalid or missing TTY leaves that pane unavailable without affecting healthy panes.
- Signed-build permission failure preserves the last good snapshot as stale.
- Logs contain bounded structured diagnostics without process arguments.
- No automatic `ps` fallback exists because it would change CPU semantics.

## Alternatives rejected

`ps` polling is rejected because it spawns and parses a process, uses decaying CPU
semantics, lacks strong PID-reuse identity in the chosen fields, and can collapse
failure into empty results.

Foreground PID is rejected as a pane root because it changes as shell jobs start and
exit, causing ownership flicker and omission of background or sibling work.

A runtime hybrid is rejected because it pays for native identity plus subprocess
metrics and can change visible semantics during fallback.

A plugin contribution or new intent is rejected because built-in UI and sampling are
one semantic owner. Public routing adds cost without isolation.

Bottom status-bar placement is rejected because `WorkspaceStatusBar` is a closed
plugin-contribution surface. The host title bar preserves Tenon's architecture while
retaining Orca's compact trigger-to-detail interaction.

## Likely implementation surfaces

Production:

- `docs/architecture-interaction-boundaries.md`
- `Sources/TenonCore/ProcessTelemetry.swift`
- `Sources/TenonCore/ProcessTelemetryCoordinator.swift`
- `Sources/TenonApp/TerminalSurface.swift`
- `Sources/TenonApp/GhosttySurface.swift`
- `Sources/TenonApp/SurfacePool.swift`
- `Sources/TenonApp/DarwinProcessSampler.swift`
- `Sources/TenonApp/ProcessTelemetryBridge.swift`
- `Sources/TenonApp/ResourceMonitorView.swift`
- `Sources/TenonApp/ShellTitleBar.swift`
- `Sources/TenonApp/TenonApp.swift`

Tests and fixtures:

- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`
- `Tests/TenonCoreTests/ProcessTelemetryTests.swift`
- `Tests/TenonCoreTests/ProcessTelemetryCoordinatorTests.swift`
- `Tests/TenonAppStateTests/TerminalProcessProjectionTests.swift`
- `Tests/TenonIntegrationTests/GhosttyProcessTelemetrySmokeTests.swift`
- `Tests/TenonUITests/ProcessMonitorFlowUITests.swift`
- a non-shipping deterministic process-tree/CPU/RSS fixture target in `project.yml`.

## Test-driven verification

Tests precede production behavior. Each group records its failing RED result, then the
smallest production change makes it GREEN. Mutation checks must demonstrate that
removing timebase conversion, start identity, global deduplication, provenance
revision, generation checks, or one-in-flight admission fails a focused test.

### Headless core tests

- idle shell, foreground command, background child, pipeline, and grandchild;
- multiple roots on one TTY;
- two panes, tabs, and workspaces without cross-leakage;
- inactive retained workspace telemetry;
- app-self first/delta CPU and RSS without claiming terminal descendants;
- missing parent, cycle, exit race, reparent race, and PID reuse;
- direct TTY ownership, nearest-root ownership, tie-break, and dedup;
- first CPU sample, timebase conversion, counter reset, invalid interval, and >100%;
- exact RSS aggregation, overflow, IEC formatting, and missing values;
- loading, empty, partial, stale, paused, and error projection;
- one in-flight sample, one pending refresh, cancellation, backoff, and late generation;
- close, move, reopen, and reassignment during a delayed sample, with stale provenance
  rejected before publication;
- 60-sample history, key eviction, and 4,096-process truncation.

### Shell and real Ghostty tests

Hosted app tests verify provenance bridging, MainActor boundaries, and typed snapshot
binding without moving rules into the shell.

A non-shipping fixture creates an idle shell, known-duty-cycle CPU worker, fixed RSS
allocation, background child/grandchild, detached-but-reachable child, and fully
reparented exclusion case.

Real Ghostty integration verifies TTY mapping, stable ownership across foreground job
changes, process appearance/removal, CPU/RSS tolerance, close/reopen lifecycle, and
signed-runtime access. It reads `ttyName` repeatedly, confirms stable copied values,
and uses allocation diagnostics to prove each Ghostty string is freed exactly once.

### UI and accessibility

XCUITest verifies trigger/popover behavior, complete hierarchy, sibling-scoped sorting,
live updates without focus loss, focus/reveal, explicit states, keyboard outline
navigation, Escape focus restoration, and inactive workspace attribution.

Visual proof compares the built app with installed Orca for information density,
hierarchy readability, summary behavior, freshness, and error clarity. Tenon keeps its
own theme and title-bar architecture.

### Commands

```bash
./scripts/setup-ghosttykit.sh
xcodegen generate

swift test --filter ProcessTelemetry

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  -only-testing:TenonCoreTests/ProcessTelemetryTests \
  -only-testing:TenonCoreTests/ProcessTelemetryCoordinatorTests \
  test

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  -only-testing:TenonAppStateTests/TerminalProcessProjectionTests \
  test

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  -only-testing:TenonIntegrationTests/GhosttyProcessTelemetrySmokeTests \
  test

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  -only-testing:TenonUITests/ProcessMonitorFlowUITests \
  test

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  test

xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  build

codesign --verify --deep --strict \
  .build/xcode/Build/Products/Release/Tenon.app
```

`swift test` proves the new core suite but not App, Integration, or UI targets. Those
surfaces require the Xcode scheme.

### Live proof

Run the signed Release app without the stub terminal. Create at least two workspaces
and two terminal panes, start the deterministic fixture, and capture:

- fixture PID/start/TTY manifest;
- Tenon hierarchy and aggregate values;
- independent `ps` topology/RSS as a diagnostic oracle;
- known-duty-cycle CPU comparison after native timebase conversion;
- process removal, pane close/move/reopen, inactive workspace, popover pause/reopen,
  and app stop;
- signpost/Instruments evidence for off-main work and performance budgets.

`ps %CPU` is not the interval-CPU correctness oracle. The deterministic duty-cycle
fixture is authoritative.

## Acceptance criteria

The feature is complete only when:

1. Every retained local terminal pane maps to stable TTY rather than foreground PID.
2. Reachable descendants retain correct pane ownership across foreground, background,
   pipeline, exit, and workspace transitions.
3. One `(PID, start time)` identity contributes to one pane and aggregate path.
4. Tenon App samples only the host identity and never double-counts terminal descendants.
5. CPU uses converted interval deltas, allows >100%, and resets on identity change.
6. Memory is current RSS, aggregates without duplication/overflow, and formats uniformly.
7. Sampling starts immediately, runs every two seconds while visible, pauses while
   hidden, and never overlaps or grows an unbounded queue.
8. Slot close, move, reopen, or reassignment invalidates stale in-flight ownership.
9. Sampling and graph work stay off `MainActor`; publication and 32-pane stress meet
   reproducible p95 budgets.
10. Trigger and popover expose hierarchy, sorting, history, freshness, state, keyboard,
    and VoiceOver contracts.
11. Empty, partial, stale, and error remain distinguishable.
12. Built-in UI uses typed DIRECT calls, no public path exists, and plugin status-bar
    invariant remains true.
13. Deterministic rules live in `TenonCore`; `TenonApp` contains adapters/projection only.
14. Focus/reveal works; no termination or restart control appears.
15. Focused tests, full Xcode scheme, real Ghostty integration, UI tests, signed Release
    verification, live behavior, and performance evidence pass at one reviewed SHA.

Passing a subset of tests, rendering static rows, or validating only a stub terminal
does not satisfy this design.
