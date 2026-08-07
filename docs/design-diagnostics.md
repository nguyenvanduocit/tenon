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

Four kinds of record, in `Application Support/Tenon/diagnostics/health.jsonl`:

| kind | when |
|---|---|
| `launch` | diagnostics armed — a journal whose newest record is a launch means the previous session never recovered |
| `stall` | the main runloop stopped completing turns |
| `stall-continues` | that stall is still going, one record per escalation interval |
| `recovered` | turns resumed, with how long the stall lasted |

Every record carries `footprintMB` — physical footprint, read via `TASK_VM_INFO`. That is the
figure that told the T-091 story: `ps` reported 232 MB resident while the real footprint was
11 GB, because the rest had been compressed and swapped. Resident size would have hidden it.

## Why a stalled runloop is the signal

The T-091 hang was neither a deadlock nor slowness. The main thread never returned from a
single runloop-observer call: SwiftUI's `Update.dispatchActions()` kept re-arming the update it
was dispatched from, so `NSRunLoop.flushObservers` never finished. Everything else followed
from that — the runloop never completed a turn, so its autorelease pool never drained, so
812,479 pool pages and one leaked `NSTimer` per turn accumulated into 11 GB.

CPU would not have distinguished this from a busy build. Frame rate would have reported the
symptom. "Did the runloop complete a turn" is the fact underneath both.

## Shape

Functional core, imperative shell:

- **`RunloopHealth`** (`TenonCore`) is pure. Fed `beat` and `probe` with injected times, it
  decides `stalled` / `stillStalled` / `recovered`, and reports each episode once rather than
  once per probe — at a one-second probe, the T-091 hang would otherwise have written 7,200
  identical records. It owns no clock and no thread, so the whole judgement is asserted in
  `TenonCoreTests` without a window, which is the fitness test CLAUDE.md sets.
- **`DiagnosticsJournal`** (`TenonCore`) is bounded, per invariant 10: at the ceiling the
  oldest records go. JSON Lines, so a process killed mid-write loses that line and nothing
  else — and a force quit is precisely how the motivating incident ended.
- **`DiagnosticsRuntime`** (`TenonApp`) owns the clock and the threads. The beat is a
  `CFRunLoopObserver` added with order `.max`, so an earlier observer that never returns stops
  the beat instead of being masked by ours.
- **Export** is a menu item calling `journal.export(to:)` behind an `NSSavePanel`. Same-owner
  DIRECT under `architecture-interaction-boundaries.md` — the host's own menu, the host's own
  journal, one semantic owner — so no intent and no new capability.

## The probe does not run on the main queue

This is the design, not an optimisation. A probe scheduled on the main queue would be wedged
by the exact condition it exists to detect; during the T-091 hang, anything queued behind that
observer waited two hours with it.

`testTheWatchdogStillFiresWhileTheMainThreadIsBlocked` holds the main thread in a busy loop —
spinning rather than sleeping, because a sleeping thread still lets its runloop turn — and
requires a stall to be recorded anyway. Moving the timer to `DispatchQueue.main` makes that
test fail with an empty journal, which is the property stated as a failure.

## What is deliberately not collected

**Nothing leaves the machine.** There is no upload, no endpoint, and no opt-in prompt to get
wrong.

**No terminal contents, ever.** This is a terminal: its panes carry source code, credentials
and agent transcripts. The journal holds timings and process figures, and the export contains
exactly what the journal holds — a person exporting it can read the whole file first.

No pane titles, no working directories, no plugin identifiers. If a future record needs one of
those, that is a product decision to take deliberately, not a field to add quietly.
