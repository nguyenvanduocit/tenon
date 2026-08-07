# T-084: Closing a pane kills what it started
> Pane teardown owns the child processes it spawned, instead of borrowing whatever libghostty happens to do.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
**RELEASED 17:3x — all files below are FREE.** Session 921ed8e8 held them 17:0x–17:3x.

- `poc/Sources/TenonCore/TerminalJobTermination.swift` (NEW)
- `poc/Sources/TenonApp/TerminalSurface.swift`
- `poc/Sources/TenonApp/SurfacePool.swift`
- `poc/Sources/TenonApp/GhosttySurface.swift`
- `poc/Tests/TenonCoreTests/TerminalJobTerminationTests.swift` (NEW)
- `poc/Tests/TenonAppStateTests/SurfaceLifecycleTests.swift`
- `docs/design-terminal-teardown.md` (NEW)
- `docs/domains.md` (one new domain entry)

`TenonApp.swift` was deliberately NOT claimed — T-071 holds it. App-quit teardown therefore
stayed out of this slice; see Non-goals.

## The measurement that started this

Measured against the running app on 2026-08-07 through `tenon-cli`, opening a pane whose
command was `nohup sleep 4343 >/dev/null 2>&1 & sleep 4242`, then closing that pane:

| process | after `workspace.pane.close.v1` |
|---|---|
| `sleep 4242` (foreground child of the shell) | killed |
| `fish` + `login` (the pane's shell) | killed |
| `nohup sleep 4343 &` (background job) | **survived, reparented to PID 1** |

So the ordinary case already works, and the ordinary case is not the interesting one.

Why the survivor survives, end to end:

1. `WorkspaceStore.closeSlot` drops the slot, `store.onEvents` calls
   `terminalSurfaces.retainOnly(Set(snapshot.allSlotIDs))` (`TenonApp.swift:1012`).
2. `SurfacePool.retainOnly` only `removeValue`s (`SurfacePool.swift:342-362`) — no kill anywhere.
3. ARC releases the surface, `GhosttyNSViewResources.deinit` calls `ghostty_surface_free`
   (`GhosttySurface.swift:540-547`).
4. libghostty's teardown sends **SIGHUP to the child's process group and stops there**.
   Evidence from the pinned `build-2026-04-29` binary: `nm ghostty-internal.a` has `U _killpg`
   and `_termio.Exec.deinit`; its strings carry `"io_exec: error sending SIGHUP to command,
   may hang"`; there is **no SIGKILL in the library at all**.

A background job leads its own process group, so `killpg` on the shell's group never reaches
it, and nothing escalates. Tenon is the only one of the three terminals studied with no
application code responsible for killing anything.

## How the reference terminals do it

- **Kero** (`refrerences/kero/kero/TerminalSession.swift:126-183`) — kills actively rather than
  through ARC: `terminate()` → clear callbacks → `signalTerminalJob(SIGHUP)` → `await 120ms`
  → `signalTerminalJob(SIGKILL)` → `surface.detach()`. Signals `{shellPid, foregroundPid}`,
  each as `kill(-pid)` then `kill(pid)`. Two comments are load-bearing: teardown "must not
  depend on a later SwiftUI reconciliation pass", and detaching before killing "can make a
  backend wait synchronously for a process that ignored SIGHUP". Still pid-guessing, so a
  `nohup` job in a third process group would survive there too.
- **Orca** (`refrerences/orca/src/main/pty/posix-pty-process-groups.ts:89-130`) — asks the
  kernel instead of guessing: `ps -p <root>` for the tty, `ps -t <tty>` for every process on
  it, then `killpg(SIGKILL)` on every distinct pgid, the root's group last. Guards: bail to a
  narrow kill when the app itself shares that tty (dev daemon launched from a terminal), and
  treat `ESRCH` as proof the group is already gone. Escalation is SIGTERM → 5s → SIGKILL ×2
  (`pty-handler.ts:1275-1343`). Close is explicit — `closeTab` calls `window.api.pty.kill`
  (`terminals.ts:1157-1174`), never a GC side effect.

This task takes **Kero's shape** (small, in-process, same libghostty backend) with **Orca's
scope** (sweep the tty, don't guess pids).

## Design

Functional core / imperative shell, so the rule is assertable in `TenonCoreTests` with no
window and no PTY:

- `TerminalJobTermination` (pure) — parse a `ps` table; answer two questions: what tty does the
  root pid own, and which process groups on that tty may be signalled. Returns nothing when the
  root has no tty, when the host process shares it, or when the root's own group is absent.
  Root's group is ordered last: it owns the tty, and killing it first can tear down the PTY
  before the other groups have been enumerated.
- `TerminalJobTerminator` (shell) — runs `ps`, sends SIGHUP to each group, waits 120 ms
  (Kero's number), **re-scans**, sends SIGKILL to what is still there. The re-scan is what
  keeps a 120 ms-old pid list from signalling a recycled pid — the failure Orca documents at
  `pty-handler.ts:148-167`. No tty (or a shared one) degrades to `kill(-pid)` + `kill(pid)`.
- `TerminalSurface.terminate()` joins the seam with a no-op default, so the stub records it and
  the rule is assertable without a terminal — the same shape `sendText` used in T-031.
- `SurfacePool.retainOnly` calls `terminate()` on every surface leaving the catalog, before
  dropping it. That is the one place a slot's death is already observed; nothing new learns
  about pane lifetime.

## Non-goals

- App quit. `TenonApp.swift` is T-071's; quitting still leaves teardown to libghostty. Worth a
  follow-up task, because the same background job survives a quit today.
- A `setsid` daemon that has left the tty entirely. Nothing scoped to a pane can find it, and
  Orca cannot either — its sweep is tty-scoped by construction.
- Changing what a *hidden* pane does. T-031's rule stands: a surface dies exactly when its slot
  leaves the catalog, and this task only adds what happens at that moment.

## Criteria
- [x] `TerminalJobTermination` decides tty and process groups from a `ps` table, with the host-shares-tty and no-tty cases refusing the group sweep
- [x] A process that ignores SIGHUP is dead after teardown, proven by a test that spawns a real one
- [x] Closing a slot calls `terminate()` on its surface before releasing it, asserted through the stub backend
- [x] The pane's own shell still survives everything that is not a close — tab switch, workspace switch, focus move (T-031's assertions stay green)
- [x] `docs/design-terminal-teardown.md` records the rule, the two reference implementations, and the measured survivor that motivated it
- [x] Full `swift test` green, with the count reported against the claim-time baseline

## Evidence

**RED first, and it was a real red.** `SurfaceLifecycleTests` ran before `SurfacePool` was
wired: 2 failures (`terminateCount` 0 ≠ 1) with the never-terminate-on-hide assertion already
green. Adding one line to `retainOnly` turned it.

**Full suite: 1379 tests, 0 failures** (81.7s). Baseline at claim time was 1349 (16:07 board
note); +14 are mine (11 `TerminalJobTerminationTests`, 3 `SurfaceLifecycleTests`), the rest
landed from other sessions in parallel.

**Mutation-verified, 3/3 caught** — the implementation was written before the tests here, so
each rule was proven to be *checked* rather than merely present (source restored from a `cp`
backup, `cmp` confirmed identical afterwards):

| mutation | result |
|---|---|
| drop the SIGKILL escalation (i.e. behave exactly like libghostty) | 4 tests fail, including **both** real-process tests |
| drop the host-shares-tty guard | `testTheHostSharingTheTTYRefusesTheSweepEntirely` fails: `[5050, 5939, 4908]` ≠ `[]` |
| order the root's group first instead of last | `testEveryProcessGroupOnThePanesTTYIsATargetWithTheShellsGroupLast` fails |

**Two test fixtures had to be corrected to keep their own premises** — both were silent
false-greens, worth knowing about:

- `sh -c "trap '' HUP; sleep 45"` — the shell **execs** `sleep` in place for a single trailing
  command, and the exec discards the trap. Measured: the process died to a plain SIGHUP, so the
  test would have passed with escalation deleted. Fixed with a loop body.
- `sh -c 'job &'` and even `bash -mc 'job &'` leave the background job in the **shell's own
  process group** — job control is off in a non-interactive shell. That removes the entire
  thing under test. The fixture now uses `zsh -f -ic`, matching the real pane's interactive
  `fish`.

**Not verified live.** The installed `/Applications/Tenon.app` is the user's running session;
re-installing would have destroyed their open panes, so the live re-measurement of the original
`nohup` scenario is deferred to the next install. The mechanism itself is covered by a test
that spawns a real PTY through `script(1)` and kills a real background job in it.

**Launch smoke deliberately skipped.** The socket path is per-uid and the user's app owns it, so
a second instance would only activate theirs — the smoke would prove nothing and would yank
their window. Nothing in this change touches the startup path.
