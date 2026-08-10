# Diagnostics: the app records its own health

**Status:** current · **Task:** T-092 · **Motivated by:** T-091

Tenon's product claim is that a condensed statement returns to inspectable evidence. An app
that freezes and leaves nothing behind fails that claim about itself.

On 2026-08-07 the app spun at 100% CPU for over two hours. Everything eventually known about
it was reconstructed from outside the process — `sample` for the stack, `heap` for the
undrained autorelease pool, `.recent-views.json` for what was on screen, `log show` to bracket
the time — and all of it was available only because a human noticed while the process was
still alive. A force quit would have erased the entire incident.

## What is recorded

Lifecycle and incident receipts live in
`Application Support/Tenon/diagnostics/health.jsonl`:

The monitor arms at app readiness, after `AppStartupPreparation.prepare` has loaded the catalog,
but before plugin runtime loading and restored-pane reconciliation. Preparation is outside its
lifetime; a failure there has no health-journal receipt and must not be described as an observed
startup stall.

| kind | when |
|---|---|
| `launch` | watchdog start, including whether the observer armed |
| `termination` | orderly app shutdown reached durable diagnostics storage within the bounded flush |
| `stall` | the main runloop stopped completing turns |
| `stall-continues` | that stall is still going, one record per escalation interval |
| `recovered` | turns resumed, with how long the stall lasted |
| `responsiveness-stall` / `-continues` / `-recovered` | one bounded main-queue ping stopped being accepted while runloop phases still completed |
| `stall-sample-scheduled` | one sample attempt was queued; this is not a launch or success claim |
| `stall-sample-completed` / `-failed` | a non-empty sample committed, or the bounded reason it did not |
| `stall-transitions-completed` / `-failed` | the frozen typed pre-incident ring committed, or the bounded reason it did not |

Every record carries one immutable run identity (`runID`, PID, version, build, channel), the
last completed runloop phase/beat sequence, physical footprint, and interval CPU core percent.
Unavailable readings are written as `unavailable`, never invented as zero. Incident records also
carry one `incidentID`; sample completion is journaled only after exit zero, privacy filtering,
and a non-empty file.

Each incident owns `diagnostics/incidents/<runID>/<incidentID>/sample.txt` and
`transitions.jsonl`. Creation, commit, cleanup, and retention reopen every run/incident directory
descriptor-relatively with `O_NOFOLLOW`; only the fixed final and temporary artifact names are
writable or removable. Raw sample text is never published under a pathname. The newest eight
incident directories
are retained, so recurrence does not overwrite the first failure and evidence does not grow
without bound. The raw capture drain and the privacy-filtered result are each capped at 64 MiB.
Export includes only journal-correlated committed artifacts in the person-chosen text file, with
16-artifact/16-MiB aggregate limits.

Tenon opens a fixed staging leaf with `openat(O_NOFOLLOW | O_EXCL)`, immediately unlinks it, and
keeps the `O_RDWR` descriptor alive for the whole capture. `/usr/bin/sample` receives only the
write end of a pipe; a concurrent drain stores at most 64 MiB in that unlinked inode and discards
any excess while continuing to drain the child. A force kill therefore cannot strand raw command,
argument, path, or plugin-label text, and replacing a run, incident, or leaf pathname cannot
redirect sample bytes. Tenon reads and privacy-filters the held inode, rechecks the sanitized byte
limit, then atomically commits only `sample.txt` and its completion receipt. Pipe EOF and the
capture-queue wait are deadline-bounded: a timed-out sampler that retains stdout is cancelled
without holding the capture queue or preventing a later incident from sampling. The copier uses
bounded 64-KiB filesystem calls; like any local persistence path, a kernel call that itself never
returns can strand that drain worker, but it cannot block the main thread or watchdog.

## Why there are two responsiveness signals

The T-091 hang was neither a deadlock nor slowness. The main thread never returned from a
single runloop-observer call: SwiftUI's `Update.dispatchActions()` kept re-arming the update it
was dispatched from, so `NSRunLoop.flushObservers` never finished. Everything else followed
from that — the runloop never completed a turn, so its autorelease pool never drained, so
812,479 pool pages and one leaked `NSTimer` per turn accumulated into 11 GB.

That makes runloop completion the right signal for a non-returning display turn. It is not enough
for main-queue saturation: a phase observer may keep beating while ordinary queued work waits
behind a self-feeding burst. The watchdog therefore keeps exactly one main-queue ping outstanding.
Five seconds of ping age while runloop beats remain fresh is a `responsiveness-stall`; it enqueues
no additional ping until that one returns. CPU core-percent deltas distinguish a spin from a wait
without deciding that an ordinary busy process is itself unhealthy.

## Shape

Functional core, imperative shell:

- **`RunloopHealth`** (`TenonCore`) is pure. Fed `beat` and `probe` with injected times, it
  decides `stalled` / `stillStalled` / `recovered`, and reports each episode once rather than
  once per probe — at a one-second probe, the T-091 hang would otherwise have written 7,200
  identical records. It owns no clock and no thread, so the whole judgement is asserted in
  `TenonCoreTests` without a window, which is the fitness test CLAUDE.md sets.
- **`DiagnosticsJournal`** (`TenonCore`) is bounded, per invariant 10: at 2,000 records,
  16 KiB per record, or 4 MiB total, the oldest records go. Atomic bounded rewrites and
  line-by-line decoding preserve neighboring evidence across truncated JSON or invalid UTF-8.
- **`DiagnosticsRuntime`** (`TenonApp`) owns the clock and the threads. The beat is a
  `CFRunLoopObserver` added with order `.max`, so an earlier observer that never returns stops
  the beat instead of being masked by ours. Watchdog, sampler, and persistence use separate
  queues, so a failed sampler or slow diagnostics filesystem cannot stop escalation/recovery.
  Persistence retains at most 64 incident events; sampling retains one active plus one queued
  capture. Shutdown waits at most 250 ms for a durable termination receipt rather than hanging
  app termination on a failed filesystem. Therefore an unmatched run means unclean exit **or**
  unavailable diagnostics persistence, never a proven crash by itself.
- **Export** is a menu item calling `journal.export(to:)` behind an `NSSavePanel`; bounded file
  traversal and destination writing run on a utility task rather than the main actor. This is
  same-owner DIRECT under `architecture-interaction-boundaries.md` — the host's own menu, the
  host's own journal, one semantic owner — so no intent and no new capability.

## The probe does not run on the main queue

This is the design, not an optimisation. A probe scheduled on the main queue would be wedged
by the exact condition it exists to detect; during the T-091 hang, anything queued behind that
observer waited two hours with it.

`testTheWatchdogStillFiresWhileTheMainThreadIsBlocked` holds the main thread in a busy loop —
spinning rather than sleeping, because a sleeping thread still lets its runloop turn — and
requires a stall to be recorded anyway. Moving the timer to `DispatchQueue.main` makes that
test fail with an empty journal, which is the property stated as a failure.

`testMainQueueBacklogIsRecordedWhileSyntheticRunloopBeatsContinue` proves the complementary
case: synthetic phase beats stay fresh while the main queue is blocked, so the bounded ping—not
the no-turn detector—must retain the incident.

## What is deliberately not collected

**Nothing leaves the machine.** There is no upload, no endpoint, and no opt-in prompt to get
wrong.

**No terminal contents, ever.** This is a terminal: its panes carry source code, credentials
and agent transcripts. A person explicitly chooses the export destination; no upload exists.

The pre-incident ring has a closed schema: run-relative uptime; a run-local pane ordinal; Agent
Lens account/mode/status enums; revision and message/tool/interaction/diagnostic/timeline counts;
scroll admitted/coalesced/executed; and numeric watchdog probes. It contains no stable pane UUID,
provider/session identifier, terminal or transcript content, title, working directory, plugin
identifier, command, environment, path, file content, or diagnostic/error detail.
Before a stack sample is committed, command/argument/environment lines, user-volume paths, and
dynamic plugin executor/watch labels are redacted while stack symbols and framework ancestry are
retained.
