# PRD — Local health evidence and read-only process Resource Monitor

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-016` |
| Lifecycle | `shipped`; bounded health diagnostics and the read-only process Resource Monitor both ship. Signed Release and XCUITest receipts remain outstanding |
| Owner | diagnostics and host-private process telemetry |
| Reviewers | product, native shell, reliability, privacy, accessibility, performance, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-10 |
| Related work | T-091 incident, T-092, T-100 |
| Normative sources | [`design-diagnostics.md`](../design-diagnostics.md), [Resource Monitor design snapshot](../superpowers/specs/2026-07-30-process-resource-monitor-design.md), [`designs.md`](../designs.md), [`architecture-interaction-boundaries.md`](../architecture-interaction-boundaries.md) |
| Acceptance specification | [`diagnostics-and-resource-monitor.feature`](diagnostics-and-resource-monitor.feature) |

## 1. Executive summary

### Problem

When Tenon spun at 100% CPU for more than two hours, the app retained no evidence of its own
failure. The useful facts were reconstructed by hand while the process was still alive: a stack
sample, heap/footprint evidence, recent view state, and unified logs. A force quit could have erased
the incident. Ordinary resident-memory reporting would also have hidden its 11 GB physical
footprint because compression and swap reduced the visible RSS.

After-the-fact evidence is only half the operator job. A person supervising terminals also needs to
see which local process tree is consuming CPU or memory now, which workspace/tab/pane owns it, and
return to the responsible pane. Tenon currently has no shipped process telemetry collector or
Resource Monitor UI. Treating a failed sample as an empty system, attributing shared helpers by
guesswork, or publishing stale ownership would be worse than saying that a value is unavailable.

### Proposed outcome

The shipped health runtime watches both whether the main runloop completes turns and whether one
bounded main-queue ping is accepted, from a watchdog neither stall can block. It records a bounded
local JSONL journal containing attributed lifecycle, stall/recovery, physical-footprint, interval
CPU, last runloop phase, first-stall stack evidence, and a typed pre-incident transition ring.
Healthy operation stays silent on disk; bad/truncated lines and write failures cannot crash the app.
A person explicitly exports a readable journal plus committed incident artifacts through the native
save panel, and nothing is uploaded.

The Resource Monitor is a host-owned, read-only title-bar popover. It attributes native
process samples through stable PTY and `(PID, process start)` identity, shows an expandable Tenon /
host-or-shared / workspace / tab / pane / process hierarchy, and preserves unavailable, partial,
stale, and error truth. CPU, physical footprint, freshness, and disk I/O appear because macOS establishes them
reliably; per-process network does not exist as a public API and is stated as absent rather than
shown as an empty column. Sampling is visibility-scoped, off-main, bounded, and directly owned
by the host; it adds no plugin, CLI, agent, palette, capability, or public intent surface.

### Why now

T-092 shipped the minimal evidence path motivated by T-091. T-100 and the July design snapshot
describe a larger Chrome-style monitor but have not shipped. The newer T-100 scope also asks for a
signed-app feasibility decision on network/shared-process attribution that the earlier snapshot
excluded. This PRD preserves that distinction so future work cannot mistake a design document for
current behavior or replace proven diagnostics while adding live telemetry.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| shipped diagnostic core/runtime | `DiagnosticsJournal`, `RunloopHealth`, `DiagnosticsRuntime` | high | exact event, timing, path, footprint, stack-sample, bound, and failure behavior |
| focused tests | journal, health, runtime, and stall-sample test suites | high | corruption survival, silence, off-main watchdog, one sample per episode, path/export behavior |
| incident record | T-091 and [`design-diagnostics.md`](../design-diagnostics.md) | high | runloop-turn and physical-footprint signals explain the motivating hang |
| completed task receipt | T-092 | high | shipped wiring, menu export, unified-log categories, and installed Release observation |
| monitor design | 2026-07-30 design snapshot | medium | feasible native CPU/RSS architecture and desired UX, not implementation evidence |
| feasibility spike | T-100 Phase 0, 2026-08-10 | high | CPU/RSS/identity/disk I/O supported and cheap; per-process network has no public API and `nettop` costs 5.2 s per sample |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Leave trustworthy local evidence after Tenon stalls and expose honest current ownership/resource use while it is running. |
| Primary users? | people diagnosing Tenon and supervising local agent/terminal workloads |
| Success? | a stall survives force quit as bounded evidence; monitor values are correctly owned, fresh, navigable, and never invented |
| Fixed constraints? | no terminal content/secrets, same-owner DIRECT UI, off-main collection, finite resources, native design/accessibility |
| Unknown? | signed-app network/I/O availability and cost; exact attribution of shared WebKit/plugin/helper processes; final live performance receipts |

## 3. Users, jobs, vocabulary, goals, and scope

The primary user is a person running several local terminals or agents who needs to answer two
questions: “what happened when Tenon stopped responding?” and “what is consuming resources now?” A
supporting engineer needs evidence that survives the incident without asking users to enable remote
telemetry. Accessibility users need the same hierarchy, values, state, sorting, and navigation by
keyboard and VoiceOver.

- When Tenon freezes, retain the first useful stack and a bounded time/footprint trail locally.
- When resource use grows, attribute it to a stable process and the nearest proven pane owner.
- When ownership or a metric cannot be proven, say unavailable/shared instead of reporting zero.
- When a row identifies a pane, reveal it without adding process-control authority.

| Term | Meaning | Not to be confused with |
|---|---|---|
| runloop stall | no completed main-runloop turn for the configured threshold | a busy build whose runloop still turns |
| physical footprint | what a process is answerable for, including compressed pages and IOKit mappings: `TASK_VM_INFO.phys_footprint` for Tenon's own health records, `rusage_info_v4.ri_phys_footprint` for any process the monitor reads. The figure Activity Monitor's Memory column and `vmmap --summary` report | resident size, which counts only pages currently in RAM and shrinks under compression |
| process identity | `(PID, absolute process-start identity)` | PID alone |
| ownership | provenance proved from retained pane TTY and reachable ancestry | foreground PID or heuristic apportioning |
| unavailable | value could not be established | measured zero |
| shared | process is real but no exclusive pane owner is proven | silently assigning it to a pane |

Goals are durable bounded post-incident evidence, truthful live telemetry, stable provenance under
process/workspace churn, low-cost native supervision, strict local privacy, and fast implementation
without unnecessary public architecture. Success targets are: every detected stall records its
first stack once; healthy operation writes no heartbeat records; journals never exceed 2,000 decoded
records; zero sensitive-content fields; zero duplicate process identities; zero stale ownership
publication; one active sample plus at most one coalesced follow-up; hidden monitor has no periodic
sampling; native collection/projection stays within the recorded performance budgets.

In scope: journal/watchdog/export/logging and local app/process CPU, memory, supported disk I/O,
hierarchy, sorting, history, states, focus/reveal, accessibility, lifecycle,
privacy, signed-app and performance receipts. Non-goals: remote telemetry, automatic upload,
long-term metric persistence, alerting, cross-machine/remote-SSH process monitoring, guessed process
ownership, killing/throttling/restarting processes, closing panes, plugin/CLI/agent telemetry APIs,
or non-Darwin collectors. Process control can be a later separately-authorized feature; it is not
smuggled into an observational monitor.

## 4. User experience

Diagnostics arms during app start without a prompt because it writes only bounded local health
evidence. It is otherwise invisible until a stall appears in the journal/unified log or the person
chooses **Export Diagnostics…**. The native save panel is the explicit boundary for copying a
human-readable export; cancel leaves the journal unchanged and writes nothing elsewhere.

The title bar carries a host-owned **Resources** button before the trailing host control. Normal
width shows an icon plus compact footprint/pane summary; constrained width keeps the icon. Tooltip and
accessibility value disclose CPU, footprint, pane count, sample time, and whether the retained sample is
paused/stale. Opening the 480×520-point popover focuses its outline and requests an immediate sample. The view shows global summary, two-minute aggregate footprint history, sortable headers,
and an expandable hierarchy. Escape closes and restores trigger focus; arrows/Home/End/Space navigate
the outline; Return focuses and reveals the related pane.

Loading, ready, paused, empty, partial, stale, and error are distinct. A skeleton waits 300 ms to
avoid flashing. Row-local churn or permission failure preserves healthy rows; collector failure
preserves the last good snapshot as stale or shows Retry when none exists. Closing the final monitor
surface stops periodic sampling and keeps the last snapshot explicitly paused, never falsely fresh.

## 5. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `DRM-FR-001` | App readiness **MUST** arm diagnostics once and enqueue an attributed `launch`; orderly shutdown **MUST** attempt a same-run `termination` within a 250 ms persistence bound. A durable termination proves a clean close; an unmatched run means unclean exit or unavailable persistence, not crash proof by itself. | shipped | `@req-drm-fr-001` |
| `DRM-FR-002` | A repeating `.max`-order main-runloop observer **MUST** beat on runloop activity so an earlier observer that never returns cannot be masked. | shipped | `@req-drm-fr-002` |
| `DRM-FR-003` | A private watchdog queue **MUST** probe every one second independently of the main queue and keep at most one main-queue responsiveness ping outstanding. | shipped | `@req-drm-fr-003` |
| `DRM-FR-004` | Five seconds without a completed turn **MUST** produce one `stall` event measured from the last beat, not from the detecting probe. | shipped | `@req-drm-fr-004` |
| `DRM-FR-005` | An ongoing stall **MUST** produce at most one `stall-continues` event per 60-second escalation interval. | shipped | `@req-drm-fr-005` |
| `DRM-FR-006` | The first subsequent completed turn **MUST** produce one `recovered` event with the full stall duration and reset the episode. | shipped | `@req-drm-fr-006` |
| `DRM-FR-007` | Every record **MUST** carry run ID, PID, version, build, channel, last runloop phase/beat, physical footprint, and interval CPU core percent; unavailable metrics **MUST NOT** become zero, and timed records **MUST** carry seconds. | shipped | `@req-drm-fr-007` |
| `DRM-FR-008` | The first detected no-turn or responsiveness stall in each episode **MUST** freeze the typed transition ring and take one three-second `/usr/bin/sample` on a queue separate from watchdog and persistence; success requires exit zero, privacy filtering, and a non-empty atomically committed artifact. | shipped | `@req-drm-fr-008` |
| `DRM-FR-009` | Continued probes in one stall **MUST NOT** resample; a new stall after recovery **MUST** sample again. | shipped | `@req-drm-fr-009` |
| `DRM-FR-010` | Healthy completed turns and sub-threshold silence **MUST** create no journal or stack-sample record. | shipped | `@req-drm-fr-010` |
| `DRM-FR-011` | The journal **MUST** live at the channel's application-support `diagnostics/health.jsonl`; each incident **MUST** own a distinct run/incident artifact directory and only the newest eight directories may remain. | shipped | `@req-drm-fr-011` |
| `DRM-FR-012` | Each record **MUST** be one ISO-8601-dated JSON line containing kind, message, and string figures so a truncated final write cannot invalidate earlier lines. | shipped | `@req-drm-fr-012` |
| `DRM-FR-013` | The journal **MUST** keep at most 2,000 decoded records, 16 KiB per record, and 4 MiB total; it **MUST** discard oldest records first and preserve newest incident evidence. Samples **MUST** remain at or below 64 MiB. | shipped | `@req-drm-fr-013` |
| `DRM-FR-014` | Reads **MUST** skip malformed/truncated lines and return every other decodable record in order. | shipped | `@req-drm-fr-014` |
| `DRM-FR-015` | Directory creation, append, trim, footprint, logging, transition capture, or sampling failure **MUST NOT** crash or end the user session and **MUST NOT** claim success without a durable onset/scheduled receipt. Event persistence **MUST** retain at most 64 jobs; capture **MUST** retain at most one active plus one queued job. | shipped | `@req-drm-fr-015` |
| `DRM-FR-016` | **Export Diagnostics…** **MUST** use a native save panel, produce readable ISO-8601 text with record count/messages/sorted figures and committed incident artifacts, reject absolute/traversing/symlink paths and diagnostics-overwrite destinations, examine at most 16 artifact references, embed at most 16 MiB, and leave state unchanged on cancellation. | shipped | `@req-drm-fr-016` |
| `DRM-FR-017` | Diagnostics **MUST** emit app-owned unified-log messages under bounded `diagnostics`, `terminal`, or `cli` categories instead of scattered `NSLog` output. | shipped | `@req-drm-fr-017` |
| `DRM-FR-018` | Runtime stop/deinit **MUST** cancel its probe timer and remove its runloop observer. | shipped | `@req-drm-fr-018` |
| `DRM-FR-019` | No diagnostic record/export **MUST** contain terminal contents, pane titles, working directories, plugin identifiers, command lines, environments, file content, or secrets. Stack samples **MUST** redact command/argument/environment lines, user-volume paths, and dynamic plugin executor/watch labels before commit while retaining stack symbols. | shipped | `@req-drm-fr-019` |
| `DRM-FR-020` | Nothing **MUST** leave the machine automatically; only a person-confirmed save copies the readable journal to a chosen destination. | shipped | `@req-drm-fr-020` |
| `DRM-FR-021` | The monitor **MUST** open from a host-owned Resources title-bar button in the shell's own chrome and **MUST NOT** occupy the plugin-only workspace status bar. | shipped | `@req-drm-fr-021` |
| `DRM-FR-022` | Its trigger **MUST** show compact footprint/pane summary when width permits, collapse to an icon when constrained, and expose CPU/footprint/pane-count/freshness/state through tooltip and accessibility value. | shipped | `@req-drm-fr-022` |
| `DRM-FR-023` | The popover **MUST** show global CPU/footprint/physical-memory share/pane count/update time, an aggregate two-minute footprint history, sortable columns, and one expandable ownership hierarchy. | shipped | `@req-drm-fr-023` |
| `DRM-FR-024` | The hierarchy **MUST** separate Tenon host/shared overhead from retained workspace → tab → pane → process → child-process ownership and **MUST NOT** count one process identity twice. | shipped | `@req-drm-fr-024` |
| `DRM-FR-025` | Terminal ownership **MUST** start from stable copied Ghostty TTY provenance and reachable native child traversal; foreground PID **MUST** be presentation metadata only. | shipped | `@req-drm-fr-025` |
| `DRM-FR-026` | Process identity **MUST** be `(PID, process-start absolute time)` and ownership ties **MUST** prefer direct TTY, then nearest root, then stable slot UUID. | shipped | `@req-drm-fr-026` |
| `DRM-FR-027` | Tenon App **MUST** sample only `getpid()` as host overhead; shared/WebKit/plugin/helper processes **MUST** remain shared or unavailable unless an exclusive owner is proven. | shipped | `@req-drm-fr-027` |
| `DRM-FR-028` | A pane without an exclusive OS process **MUST** remain representable without invented zero metrics; fully detached processes outside every reachable root **MUST NOT** retain pane ownership. | shipped | `@req-drm-fr-028` |
| `DRM-FR-029` | Rows **MUST** expose executable name, PID, interval CPU, physical footprint, and sample freshness; I/O or network values **MUST** appear only after signed-app feasibility proves reliable semantics and cost. | shipped; disk I/O admitted, network refused by measurement | `@req-drm-fr-029` |
| `DRM-FR-030` | CPU **MUST** use converted cumulative-counter deltas, show em dash on first/invalid observation, allow values above 100%, and never turn unavailable into zero. | shipped | `@req-drm-fr-030` |
| `DRM-FR-031` | Memory **MUST** be current physical footprint written in the SI units macOS itself prints, aggregate with checked addition, expose unavailable on overflow, and calculate physical-memory share from the aggregate. | shipped | `@req-drm-fr-031` |
| `DRM-FR-032` | Sorting **MUST** remain within sibling groups, default to Memory descending, toggle each header direction, and break ties by normalized name then stable identity without flattening the tree. | shipped | `@req-drm-fr-032` |
| `DRM-FR-033` | Exactly 60 footprint history samples **MUST** be retained per Tenon/workspace/tab/pane aggregate; process rows **MUST NOT** allocate their own history. | shipped | `@req-drm-fr-033` |
| `DRM-FR-034` | The monitor **MUST** distinguish loading, ready, paused, empty, partial, stale, and error; collector failure **MUST NOT** masquerade as an empty successful sample. | shipped | `@req-drm-fr-034` |
| `DRM-FR-035` | Process exit (`ESRCH`), unreadable row, invalid TTY, or permission failure **MUST** preserve healthy rows and produce row-local partial diagnostics when useful data remains. | shipped | `@req-drm-fr-035` |
| `DRM-FR-036` | Opening **MUST** request an immediate sample then sample every two seconds; closing the final surface **MUST** cancel periodic demand and preserve the last snapshot explicitly paused. | shipped | `@req-drm-fr-036` |
| `DRM-FR-037` | At most one sample **MUST** be in flight and one refresh coalesced; lifecycle/provenance changes **MUST** reject late results and request at most one replacement. | shipped | `@req-drm-fr-037` |
| `DRM-FR-038` | Fatal visible errors **MUST** back off at 2, 4, 8, 16, then 30 seconds; manual Retry **MUST** bypass one delay without adding another in-flight sample. | shipped | `@req-drm-fr-038` |
| `DRM-FR-039` | One snapshot **MUST** cap global process identities at 4,096, traverse deterministically, and expose partial/truncated state at capacity. | shipped | `@req-drm-fr-039` |
| `DRM-FR-040` | Moving, closing, reopening, or reassigning a pane **MUST** increment provenance, evict obsolete ownership/history, and prevent an old snapshot from publishing under the new hierarchy. | shipped | `@req-drm-fr-040` |
| `DRM-FR-041` | Selecting a pane/process row and pressing Return **MUST** focus and reveal the owning pane through the existing typed workspace service without process control. | shipped | `@req-drm-fr-041` |
| `DRM-FR-042` | Trigger, tree, sort headers, disclosure, values, state announcements, Escape restoration, arrows, Home/End, Space, and Return **MUST** have complete keyboard and VoiceOver semantics without live-announcing every sample. | shipped | `@req-drm-fr-042` |
| `DRM-FR-043` | The monitor **MUST** remain read-only: it **MUST NOT** terminate/throttle/restart a process, close a pane, or add plugin/CLI/agent/palette/keybinding telemetry access. | shipped | `@req-drm-fr-043` |
| `DRM-FR-044` | Before delivery, the July design **MUST** be revalidated against current source/design/domain/boundary rules and signed-app CPU/footprint/I/O/network/shared-process feasibility, with unsupported metrics removed or named unavailable. | shipped; revalidation record dated 2026-08-10 heads the design snapshot | `@req-drm-fr-044` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `DRM-NFR-001` | reliability | Diagnostics and telemetry **MUST** fail soft, preserve the last trustworthy evidence/snapshot, and never cause the outage they observe. | shipped | `@req-drm-nfr-001` |
| `DRM-NFR-002` | boundedness | Journal, sample count, process set, history, task, queue, retry, callback, and visibility lifetimes **MUST** have explicit finite bounds and owners. | shipped | `@req-drm-nfr-002` |
| `DRM-NFR-003` | privacy | Collection **MUST** remain local and limited to health/process metadata; sensitive content and process arguments **MUST NOT** enter journal, UI history, export, or logs. | shipped | `@req-drm-nfr-003` |
| `DRM-NFR-004` | native design | Trigger, popover, hierarchy, state, history, and errors **MUST** use Tenon design tokens/components and **MUST NOT** introduce feature-local geometry/color/typography tokens. | shipped; the July design's 460 pt was a feature-local number and is now 480 pt, `designs.md`'s focused-panel bound | `@req-drm-nfr-004` |
| `DRM-NFR-005` | accessibility | Meaning **MUST NOT** depend on color; focus, outline level, expansion, value, sort direction, unavailable/shared state, and navigation **MUST** be localized and spoken. | shipped | `@req-drm-nfr-005` |
| `DRM-NFR-006` | performance | Native sampling/traversal/aggregation **MUST** remain off `MainActor`; publication/binding **MUST** be below 2 ms p95 and a 32-pane/1,000-process Release sample below 50 ms p95. | partial; measured p95 0.195 ms for 32 panes' roots under `swiftc -O`, no signed Release receipt | `@req-drm-nfr-006` |
| `DRM-NFR-007` | correctness | Process reuse, churn, reparenting, overlap, foreground changes, inactive retained workspaces, and counter resets **MUST NOT** duplicate, leak, or invent ownership/metrics. | shipped | `@req-drm-nfr-007` |
| `DRM-NFR-008` | lifecycle | App shutdown **MUST** cancel/await telemetry quiescence; diagnostics observer/timer and monitor visibility/generation/provenance resources **MUST** end at their declared owner boundary. | shipped | `@req-drm-nfr-008` |
| `DRM-NFR-009` | architecture velocity | Built-in UI **MUST** use a typed same-owner DIRECT service and host-private bounded RESOURCE/STREAM/TASK lifecycle; no public routing or permission ceremony **MAY** be added without a concrete independent-owner or risk need. | shipped | `@req-drm-nfr-009` |
| `DRM-NFR-010` | compatibility | Live collection **MUST** target supported macOS/Darwin APIs, copy/free Ghostty TTY strings correctly, and expose unsupported metrics honestly with no semantic-changing `ps` fallback. | shipped | `@req-drm-nfr-010` |
| `DRM-NFR-011` | observability | Failure text/logs **MUST** identify collection stage/reason/freshness without command lines, secrets, guessed values, or unbounded per-PID noise. | shipped | `@req-drm-nfr-011` |
| `DRM-NFR-012` | evidence | Core, hosted, real-Ghostty, UI/accessibility, performance, signed Release, and live receipts **MUST** prove their respective claims at one reviewed source SHA. | partial; core/hosted/real-`libproc` receipts exist, signed Release and XCUITest do not | `@req-drm-nfr-012` |

## 6. Acceptance, architecture, and data lifecycle

[`diagnostics-and-resource-monitor.feature`](diagnostics-and-resource-monitor.feature) maps all 56
requirements. Shipped evidence is the pure injected-time state machine, bounded/corruption-tolerant
journal, runtime watchdog, stack-capture tests, export test, source wiring, unified log, and installed
Release receipt. Planned monitor evidence needs pure graph/metric/coordinator tests, hosted projection,
real Ghostty/libproc, XCUITest/accessibility, reproducible Release benchmarks, signed-app permission,
and live topology comparison.

| Interaction | Classification | Constraint |
|---|---|---|
| health menu → journal/export | DIRECT | one host owner; save panel is explicit copy destination |
| title-bar UI → telemetry/navigation | DIRECT | built-in host service only; no intent/public principal |
| repeating visible sampler | host-private RESOURCE/STREAM/TASK | cancellable, one in flight, bounded history/capacity |
| stall/recovery fact | internal typed state change plus local journal/log | no plugin EVENT or remote telemetry surface |

`RunloopHealth` and the metric/ownership/coordinator rules belong in headlessly testable
`TenonCore`. Clock/runloop, Mach/libproc/Ghostty, MainActor bridge, and SwiftUI remain `TenonApp`
adapters. The journal owns 2,000 newest records for the app-support lifetime. A stall episode owns
one stack capture. The monitor coordinator owns counters/history only while composed; visibility owns
periodic demand; lifecycle generation and provenance revision reject late results. Deleted keys leave
immediately and unseen history keys after ten minutes. Shutdown cancels demand and reaches
quiescence.

Same-user read-only process metadata needs no recurring permission prompt: inability to read a row
is data availability, not an invitation to invent a new permission architecture. Any later process-
control action is a separate authority/product decision. Host-native UI follows `docs/designs.md`;
the Orca comparison informs information flow only and cannot override Tenon's visual language.

## 7. Delivery matrix, phases, risks, and decisions

| Requirements | Implementation/evidence | State/gap |
|---|---|---|
| FR-001…018, NFR-001…003/008/011 | diagnostics core/runtime/commands/log/path plus four focused suites and T-092 Release receipt | shipped; shutdown wiring remains a continuous audit |
| FR-019…020 | explicit negative data inventory, local journal, save-panel-only export | shipped |
| FR-021…044, NFR-004…010 | `ProcessTelemetry`, `ProcessTelemetrySnapshot`, `ProcessTelemetryCoordinator` (core); `DarwinProcessSampler`, `ProcessTelemetryBridge`, `ResourceMonitorView` (shell); 67 focused tests | shipped 2026-08-10 (T-100) |
| NFR-006/012 | measured `swiftc -O` probes plus real-`libproc` tests | partial; no signed Release benchmark, no XCUITest, no live multi-workspace comparison |

Phase 0 revalidates the design and signed-app semantics, especially reliable I/O/network and shared
process grouping. Stop or omit any metric whose meaning/cost cannot be proven. Phase 1 builds pure
identity/ownership/metric/coordinator rules and native sampler/provenance seams with headless, real-
Ghostty, and performance evidence. Phase 2 wires title-bar/popover/states/navigation/accessibility,
then proves the signed Release and live multi-workspace topology. T-092 remains enabled throughout;
the monitor does not replace or migrate its journal.

Primary risks are watchdog coupling to the stalled queue, diagnostics becoming unbounded, sensitive
data entering evidence, PID reuse/double counting, foreground-PID ownership flicker, shared helper
misattribution, stale snapshots after moves, subprocess fallback changing CPU meaning, MainActor
sampling, and design prose being mistaken for shipped behavior. Independent queues, fixed bounds,
negative privacy inventory, start-time identity, TTY ancestry/global claim set, generation/revision
checks, native APIs, explicit delivery labels, and signed receipts mitigate them.

Decisions: runloop completion is the shipped health signal; physical footprint—not RSS—is the health
journal memory figure; first stall samples once; JSONL drops oldest; automatic upload is forbidden;
the live monitor and the health journal report one memory figure, physical footprint, in the SI units macOS prints; first CPU is unavailable; sampling pauses when hidden; monitor is
observational and host-private; no generic intent/capability/permission layer is justified; unsupported
I/O/network/shared ownership remains unavailable rather than estimated. The July snapshot is input to
T-100, not proof that T-100 shipped.

Open decisions before monitor implementation: whether signed macOS APIs provide reliable per-process
network and cumulative/delta I/O at acceptable cost; which shared host/helper rows can be named
without implying pane ownership; whether non-terminal panes appear as unavailable ownership nodes;
and whether the trigger's exact compact summary should prioritize footprint, CPU, or the worse pressure.

## 8. Verification receipts and change history

| Date | Worktree/commit | Environment/scope | Result | Exclusions |
|---|---|---|---|---|
| T-092 delivery | historical accepted SHA | Swift suites plus installed Release app | journal/log/export verified; focused tests and mutation receipts green | not evidence for Resource Monitor |
| 2026-08-09 | current dirty tree | source/design/task documentation audit | 44 FR/12 NFR mapped to current shipped/planned truth | no Swift suite, signed feasibility, UI, or live monitor run |
| 2026-08-10 | current dirty tree (T-100, session `e3ac726b`) | `swift test` on `TenonCoreTests` + `TenonAppStateTests`, plus four native feasibility probes on Darwin 25.4/arm64 | Resource Monitor shipped. full suite 1836/0 on two consecutive runs; 67 focused tests green: `ProcessTelemetryTests` 41, `ProcessTelemetryCoordinatorTests` 15, `TerminalProcessProjectionTests` 11 (real pty, real `libproc`). Fitness gates green: DIRECT inventory 3, domain tags 5, interaction boundaries 20. Feasibility: CPU/RSS/`ri_proc_start_abstime`/disk I/O supported at p95 ≤ 1 µs per process; 32 panes' roots traversed at p95 0.195 ms; **per-process network has no public API** — absent from all 36 `rusage_info_v4` and 18 `proc_taskinfo` fields, socket info carries buffer occupancy only, `nettop` measured at 5,243 ms per sample | no signed Release benchmark; no XCUITest; no live multi-workspace comparison against `ps`; no `setsid`-detached process exercised (macOS ships no `/usr/bin/setsid`) |

| 2026-08-10 | current dirty tree (T-108, session `2c553190`) | `swift test` full suite plus a live sweep of two real panes on Darwin 25.4/arm64 | **`DRM-FR-025` and `DRM-FR-035` were shipped but non-functional in the running app and are now corrected.** Ghostty starts each pane through setuid-root `/usr/bin/login`, which answers `proc_pidinfo` with `rc=0, errno=EPERM` for a UID-501 caller. Root selection asked whether a parent was in the *enumerated* attached set, so `login` shadowed every shell while never qualifying as a root itself: `roots` came out empty, the traversal never ran, and **every pane attributed zero processes** while the banner read `partial, 2 processes unreadable` — one `login` per pane. Root selection is now the pure rule `TerminalProcessTree.roots(readable:)` in `TenonCore`, judged against what the sampler could **read**. A second defect of the same class was found and fixed while proving the first: the walk skipped the children of any process it could not read, so one `sudo` mid-tree would delete everything beneath it — measured, `proc_listchildpids` answers for an EPERM process (`[37403]` for `login`), so children are now queued before the read is attempted. A process unreadable at survey time no longer counts toward `unreadableCount`; one lost inside the walked tree still does. Evidence: full suite **1851 / 0**; `TerminalProcessTreeTests` 7 new, 6 red before the fix; the shipped `DarwinProcessSampler` run against this machine's two panes returned **20 processes, `unreadable=0`, `shared=0`, every row owned**, against 0 processes and `unreadable=2` before | no setuid-parent case in the automated suite — macOS offers no password-free setuid-root process to spawn under a test pty, so the mid-tree branch rests on the measured `proc_listchildpids` behaviour and the pure rule's coverage; monitor popover still never photographed; no signed Release benchmark; no XCUITest |

| 2026-08-10 | current dirty tree (T-109, session `2c553190`) | `swift test` full suite, live sweep of two real panes, and a cross-check against `vmmap --summary` on Darwin 25.4/arm64 | **The monitor's memory figure disagreed with Activity Monitor and is now the same figure.** Two independent causes, both measured on PID 37334: the sampler read `pti_resident_size` (155.1 MiB) where macOS reports `ri_phys_footprint` (368.5 MiB), and it wrote IEC units where macOS writes SI. Apple's own `vmmap --summary` reports `Physical footprint: 368.5M`, confirming which field the operating system means. The direction of the error is not fixed — for the app footprint was 2.4x resident, for the test process footprint was *smaller* (6.5 MB against 29.5 MB) — so the two quantities cannot be reconciled by a constant and one of them had to be chosen. Footprint is the choice that matches Activity Monitor and the health journal beside it, and it is the figure that would have shown T-091's 11 GB. `DRM-FR-031` rewritten; `DRM-FR-022/023/029/033` restated on footprint; `proc_taskinfo` left the sampler entirely, one fewer syscall per process. Evidence: `TelemetryMemoryFigureTests` 3 and `SamplerMemoryFigureTests` 1, **red before** (formatter returned `291.0 MiB` for an expected `305.1 MB`; sampler figure sat 3.33x from footprint); full suite **1854 / 0**; live through the shipped formatter, `claude` 431.6 MB and 18 processes aggregating 1.2 GB | monitor popover still never photographed; no signed Release benchmark; no XCUITest |

Initial canonical PRD created 2026-08-09. It reconciles T-092's shipped local evidence with T-100's
planned live monitor and records the newer network/shared-process feasibility gate without claiming
those values exist. T-108 corrected the first two requirements this PRD had marked `shipped` on the
strength of a green suite that no live pane had ever exercised, and T-109 corrected the memory
figure those requirements report.
