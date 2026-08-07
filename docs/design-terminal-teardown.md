# Terminal teardown — what a closing pane stops

**Status:** shipped (T-084). Normative for pane close; app quit is not covered yet.

Closing a pane means the work in it stopped. That sentence is the product rule; everything
below is what it costs to make it true.

## The measurement

Against the running app on 2026-08-07, through `tenon-cli`. A pane opened with
`nohup sleep 4343 >/dev/null 2>&1 & sleep 4242`, then closed with `workspace.pane.close.v1`:

| process | after the close |
|---|---|
| `sleep 4242` — foreground child of the shell | killed |
| `fish`, `login` — the pane's shell | killed |
| `nohup sleep 4343 &` — background job | **survived, reparented to PID 1** |

The ordinary case already worked. It worked by accident, in the sense that no Tenon code was
responsible for it:

1. `WorkspaceStore.closeSlot` drops the slot; `store.onEvents` calls
   `terminalSurfaces.retainOnly(Set(snapshot.allSlotIDs))` (`TenonApp.swift:1012`).
2. `SurfacePool.retainOnly` removes the surface from its dictionaries.
3. ARC releases it, `GhosttyNSViewResources.deinit` calls `ghostty_surface_free`
   (`GhosttySurface.swift:540-547`).
4. libghostty's `termio.Exec.deinit` sends **SIGHUP to the child's process group**, and stops.

Step 4's limits are the whole problem, and they are visible in the pinned
`build-2026-04-29` binary: `nm ghostty-internal.a` exports `U _killpg` and
`_termio.Exec.deinit`; its strings carry `"io_exec: error sending SIGHUP to command, may hang"`;
**there is no SIGKILL in the library at all.**

So two classes of process outlive their pane:

- anything that traps or ignores SIGHUP — nothing escalates;
- anything leading its own process group — an interactive shell puts every background job in
  one, and `killpg` on the shell's group never reaches it.

Both are exactly what a supervision workspace accumulates: dev servers, watchers, agents told
to keep running.

## How the reference terminals handle it

**Kero** — same libghostty backend, same language (`refrerences/kero/kero/TerminalSession.swift:126-183`):

```swift
func terminate() { … beginTeardown(processAlive: true, notifyExit: false) }
// clear callbacks → signalTerminalJob(SIGHUP) → await 120ms → signalTerminalJob(SIGKILL)
// → surface.detach()
// signalTerminalJob: for pid in {shellPid, foregroundPid}: kill(-pid, s); kill(pid, s)
```

Two of its comments are load-bearing. Teardown "must not depend on a later SwiftUI
reconciliation pass" — that is why the kill is an explicit call and not a `deinit`. And
detaching before killing "can make a backend wait synchronously for a process that ignored
SIGHUP" — that is why the order is kill, then release. Its limit: it knows two pids, so a
background job in a third group survives there too.

**Orca** — Electron + node-pty, PTY owned by a daemon rather than by the window
(`refrerences/orca/src/main/pty/posix-pty-process-groups.ts:89-130`):

```ts
/** Force-kill every process group still attached to one POSIX PTY. */
// ps -p <root> → tty; ps -t <tty> → every process on it; killpg each distinct pgid, root last
```

It does not guess who belongs to the pane; it asks the kernel which processes are still
attached to the pane's terminal. Two guards ride along: bail to a narrow kill when the app
itself shares that tty (a dev daemon launched from a terminal), and treat `ESRCH` as proof a
group is already gone rather than as failure. Escalation is SIGTERM → 5 s → SIGKILL, twice
(`pty-handler.ts:1275-1343`). Closing a tab calls `window.api.pty.kill` explicitly
(`terminals.ts:1157-1174`) — never a GC side effect. Because the PTY outlives the window, Orca
also has to `revive()` and re-attach, gated on `process.kill(pid, 0)` proving the process is
still alive.

## What Tenon does

Kero's shape — small, in-process, called explicitly at close — with Orca's scope — sweep the
tty instead of guessing pids.

**The decision is pure** (`TenonCore/TerminalJobTermination.swift`), so it is assertable in
`TenonCoreTests` with no window and no PTY:

- `controllingTTY(of:in:)` — the pane's terminal, or nil when `ps` reports `?`/`??`. Nil is an
  answer, not a failure: without a tty nothing proves which processes are the pane's.
- `signalTargets(onTTY:rootPID:hostPID:in:)` — every process group on that tty, **root's group
  last** (it owns the terminal; killing it first can collapse the PTY mid-sweep). Returns empty
  — fail closed — when the host shares the tty, or when the root is no longer on it. Groups 0
  and 1 are dropped before any decision: signalling group 1 is how a bug becomes a logout.

**The execution is a thin shell** (`TerminalJobTerminator`): SIGHUP every target → wait 120 ms
(Kero's number) → **re-read `ps`** → SIGKILL what is still there. The re-read is not caution
for its own sake: a 120 ms-old pid list can name a process that already exited and whose number
the kernel reissued, the hazard Orca documents at `pty-handler.ts:148-167`. With no tty, or a
shared one, it degrades to Kero's floor: `kill(-pid)` then `kill(pid)`.

**The call site is the pane's death, not the object's.** `SurfacePool.retainOnly` calls
`terminate()` on each surface leaving the catalog *before* releasing it — while the surface can
still name its own processes. `terminate()` is on the `TerminalSurface` seam with a no-op
default, so the stub backend records it and the rule is testable without a terminal;
`GhosttySurface.terminate()` clears its callbacks first (a dying pane must not report a title
or a process exit into a slot the workspace has forgotten), then sweeps.

### Why not `deinit`

Because "the surface was deallocated" and "the pane was closed" are different facts, and only
the second one authorizes killing anything. Deallocation order is not a product decision, it
cannot be observed in a test without weak-reference gymnastics, and — Kero's comment — it makes
teardown depend on a reconciliation pass that may not have run yet. `retainOnly` is where a
slot's death is already observed, so nothing new had to learn about pane lifetime.

## What is still true after this

- **A hidden pane is never terminated.** T-031's rule stands: tab switch, workspace switch, and
  focus moves all re-assert the same catalog, and `terminate()` fires only for a slot that
  actually left it. Asserted directly.
- **A pane is terminated at most once.** Removal happens in the same pass as the signal, so a
  repeated catalog sync cannot aim a second round at recycled pids.
- **Tenon never signals a tty it shares.** Running `swift run tenon` from a terminal inherits
  that terminal; the sweep refuses rather than killing the developer's own shell.

## Known gaps

- **App quit.** `TenonApp.swift` belongs to T-071, so quit still leaves teardown to libghostty
  and the same background job survives it. Follow-up task.
- **A process that left the tty entirely** (`setsid`, a true daemon) cannot be found by anything
  scoped to a pane. Orca's sweep is tty-scoped for the same reason. This is a boundary, not a
  bug: a process that detached from the terminal asked not to be the terminal's.
- **`ps` is the only oracle.** It costs two subprocess reads per close, on a background task.
  If that ever shows up in a profile, `proc_listpids` is the same answer without the fork.

## Tests

`Tests/TenonCoreTests/TerminalJobTerminationTests.swift`

- the pure rules, including both fail-closed refusals and the group-ordering;
- the sweep's signal sequence against a scripted process table, proving the second round is
  driven by a **re-read** and not by the first list;
- a real process that ignores SIGHUP: the test first proves SIGHUP alone leaves it running —
  otherwise it would pass with escalation deleted — then that teardown kills it;
- the measured survivor, reproduced in a PTY of its own via `script(1)`: a background job in its
  own process group dies with the pane. It needs an **interactive** shell (`zsh -f -ic`) to be
  faithful — job control is what puts a background job in its own group, and `sh -c` (and even
  `bash -mc`) leaves it in the shell's, which silently removes the thing under test.

`Tests/TenonAppStateTests/SurfaceLifecycleTests.swift` — terminate-on-close, never-on-hide, and
exactly-once.
