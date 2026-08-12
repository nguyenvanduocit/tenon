# T-135: A real Ghostty surface that kills the test runner on a VM

> The last step of CI still fails, and for the first time in this stack it is not an assertion:
> the runner process exits mid-run.

- **priority**: high
- **effort**: M
- **owning PRD**: `docs/prds/terminal.prd.md`, `docs/prds/engineering-quality.prd.md`

## What CI measures

Downloaded from run `31532783661`'s `integration-xcresult` artifact:

```
GhosttySurfaceSmokeTests/testRealSurfaceRendersAcceptsInputResizesAndExits()
targetName: TenonIntegrationTests
failureText: "The test runner exited with code 1 before finishing running tests.
              This may be due to your code calling 'exit', consider adding a
              symbolic breakpoint on 'exit' to debug."
device:   Apple Virtual Machine 1 · macOS 15.7.7 · arm64
result:   4 passed, 1 failed
```

The other four cases in the bundle pass. This one builds a **real** `GhosttySurface` — a real PTY
and real libghostty — and the process dies before the suite finishes, so xcodebuild reports
`** TEST FAILED **` and exit 65 while every test line in the log reads as passing. That gap is why
the plain CI log looked contradictory: it never printed an assertion failure.

## Why this is only surfacing now

`macOS CI` has **no green run in its last 40** (22 failures, 1 cancelled, 0 successes). The
`Run hosted integration tests` step sits behind `swift test`, the Xcode app build, and the link
step, all of which failed first. This step has almost certainly never executed to completion, so
its failure is inherited, not introduced — it became visible only once the five causes ahead of it
were cleared on 2026-08-11/12 (compile break, the tab-strip presses, three concurrency waits, the
JSONSchema link drift, `waitForRunning`).

## The question to answer first

Does rendering a real surface belong in the per-push lane at all? The repository has already made
this call once, at `.github/workflows/macos-ci.yml:85`: the `ui-smoke` lane is separate "because it
needs a real GUI session and real app launches: one flaky window server should not turn a code
review red". A test that renders a real terminal on a VM with no display is arguably the same
kind of thing.

Against that: `TenonIntegrationTests` exists precisely so suites the Xcode scheme owns are actually
run, and moving a test out of the per-push lane costs real coverage — `swift test` cannot see this
target at all. So establish *why* the process exits before deciding where the test lives.

Do not "fix" this by deleting the test or by moving it somewhere it will not run. Find out what
calls `exit`.

## What the runner actually did — measured 2026-08-12 from two runs

Read from the `integration-xcresult` bundle of run `31532783661` (console-log attachment) and
from `gh run view 31567297728 --log`. The two runs agree to within 70 ms, so this is the shape of
the failure and not a one-off.

| | run `31532783661` | run `31567297728` |
|---|---|---|
| app's own launch pane spawns | 20:35:07.561 `login pid=21262` | 05:50:03.751 `login pid=25449` |
| test's surface spawns | 20:35:09.011 `login pid=21601` | 05:50:05.151 `login pid=25477` |
| `io_exec: pty fd closed, read thread exiting` | 20:35:10.122 (**+1.112 s**) | 05:50:06.329 (**+1.178 s**) |
| host process gone | 20:35:10.420 `Launch session expired` | — |
| xcodebuild relaunches | 20:35:11.054 | 05:50:07.298 |
| successor logs | 20:35:11.437 `[sentry] sentry: crash report written to disk path=…/dd20aca2-….ghosttycrash` | 05:50:07.698 `…/fed93492-….ghosttycrash` |

Four things follow, each marked where it stops being a reading and starts being a reading of a
reading:

1. **The process crashed; it did not call `exit`.** The successor process's libghostty writes a
   sentry crash capture ~2 ms after `ghostty_init` — and that successor then runs on healthily, so
   the capture it is flushing is the dead process's. (That last step is the one inference here, and
   the `.ips` this session started collecting settles it either way.)
   XCTest's "may be due to your code calling 'exit'" is its generic wording for
   an unexpected runner exit; `rg '\bexit\('` over `Sources/` reaches only `TenonCLI`, the two
   snapshot writers (env-gated), and the single-instance branch at `TenonApp.swift:204`, which is
   disabled under XCTest (`CLISocketServer.swift:118`, `enabled: !underTest`).
2. **A real Ghostty surface is survivable on this VM.** The app under test builds one at launch —
   real PTY, real `/usr/bin/login`, `renderer=renderer.generic.Renderer(renderer.Metal)`,
   `display link display id=1` — and it lives through the whole run in both launches. So this is
   not "no GPU" and not "no display".
3. **What dies is the surface the test builds**, ~1.1 s after its child spawns, unprompted: the
   test's first `waitUntil` has an 8 s budget and its Ctrl-D is many seconds later, so nothing the
   test does asks for that exit.
4. **xcodebuild relaunches the host and finishes the remaining case**, which is why the summary
   reads `4 passed, 1 failed` for a five-case bundle that dies on case one.

### Ruled out

- *Our code calls `exit`* — see (1).
- *libghostty cannot start on a VM* — see (2); `ghostty_init`, `ghostty_config_new` and
  `ghostty_app_new` all succeed, and a second surface renders.
- *`/bin/sh` is intrinsically fatal under Ghostty's macOS `login` wrapper* — probed directly on a
  PTY: `/usr/bin/login -flp $USER /bin/sh` still had a live `sh-3.2$` prompt at 3.0 s, as did the
  default shell. The `/bin/sh` override is still the **only** config difference between the surface
  that lives and the surface that dies (`GhosttySurface.swift:706-740`: the test sets
  `config.command`; `TenonApp.swift:510`, the sole production construction site, does not) — but
  the probe means it cannot be asserted as the cause.

### Settled — H-teardown, and the "unprompted exit" reading above is withdrawn

**Correction, 2026-08-12.** The table above said the child exits "unprompted" because the test's
first `waitUntil` has an 8 s budget. That mistook a **ceiling for a duration**: `waitUntil` returns
the instant its condition holds (`GhosttySurfaceSmokeTests.swift:245-247`), so the 8 s is never
spent. Immediately before the Ctrl-D there is `pumpRunLoop(for: 1)` — a hard 1.0 s wall-clock spin.
So the earliest possible Ctrl-D is spawn + 1.0 s + surface start ≈ **1.1–1.2 s**, which is exactly
the measured window in all three runs (1.111 / 1.178 / 1.180 s), and the app's log falls silent for
1.094954 s beforehand — the shape of that spin. **The child exits because the test told it to, on
time.** A spontaneously dying `/bin/sh` has no mechanism that lands on that figure three times.

That separates the two hypotheses without a stack, which the previous note said was impossible:

- **H-teardown — surviving.** The crash follows the *intended* child exit and the close callback.
  `config.wait_after_command = false` (`GhosttySurface.swift:714`) makes libghostty ask the host to
  close the surface when the child exits; `closeSurface` forwards that to `onProcessExit`
  (`:481-483`). Production wires it (`SurfacePool.swift:146`); **this test left it nil**, so nothing
  acted on the close — while `waitUntil { surface.processExited }` kept calling
  `ghostty_surface_process_exited` on the C surface (`GhosttySurface.swift:1201-1203`) that
  libghostty had already torn down. Test and production differ by exactly the crash condition.
- **H-renderer — rejected.** It predicts a crash during steady-state drawing, and the surface drew
  fine for the whole preceding second.

**The change that follows** (this session): the test now observes the exit through
`surface.onProcessExit`, the same callback `SurfacePool` uses, instead of polling into C. Its own
comment already said it meant to "exercise the normal close callback used by SurfacePool" — it just
never wired one.

### H-teardown confirmed, and the remaining question is much smaller

Run `31579046795`, first run after the change: **zero occurrences of "runner exited with code"** —
the string that named this failure on every previous run. The host no longer dies. Polling
`ghostty_surface_process_exited` on a torn-down surface was the crash, established by behaviour
rather than by a stack.

Run `31581606850` then answered the follow-up with the diagnostic:

```
GhosttySurfaceSmokeTests.swift:131: XCTAssertTrue failed —
the close callback SurfacePool relies on never fired; ghostty_surface_process_exited=true
```

**`process_exited=true`.** So the child exits, on time, and libghostty simply never asks the host to
close the surface. That kills "the shell never exited" outright.

### What is left, in order of what the evidence favours

1. ~~**The short-lived-command threshold is not cleared on the VM.**~~ **DEAD.** Run `31582888515`
   raised `pumpRunLoop` from 1 s to 3 s and the result is unchanged: still
   `process_exited=true`, still no callback. The threshold is not what CI is hitting.
2. **The close never reaches our handler — leading candidate.** The registration is present and
   correct: `rt.close_surface_cb` is set on the app runtime (`GhosttySurface.swift:208-210`), and
   `closeSurfaceCallback` hops to the main actor (`:352-364`). But `closeSurface` then resolves the
   view through `view(fromTokenBits:)` (`:481-483` → `:489-492`), which is
   `liveViews[token]?.value` — a registry of **weak** boxes. A token that does not resolve makes the
   callback a silent no-op, which is precisely the observed behaviour: the child exits, ghostty asks
   for a close, and nothing happens.
   *Probe, one line:* log inside `closeSurface` whether the view resolved. That distinguishes "we
   were never called" from "we were called and dropped it", and it is worth keeping afterwards —
   a close that resolves to nothing should never be silent.
3. **Delivery needs a runloop the test does not spin — weakened.** `wakeupCallback` posts
   `shared.tick()` through `DispatchQueue.main.async` (`:238-248`) and `tick` calls
   `ghostty_app_tick` (`:223`). `waitUntil` spins `RunLoop.main.run(mode: .default, before:)`
   (`:265`), which does drain the main queue, so the tick should happen. Keep it only as a fallback
   if (2) shows the callback never arrives at all.

Order: (2), then (3) only if (2) shows no call. Both are one log line apart from an answer.

One artifact separates them: the crash report, and nothing was collecting it. The
`.ghosttycrash` is certain — the runner's own log prints its path. The macOS `.ips` under
`~/Library/Logs/DiagnosticReports/` is the one that carries the signal and the faulting thread,
and whether ReportCrash writes one on this image is itself unknown until a run says so. The new
step takes both and stays green either way, so the next run answers that too.

### Local reproduction is blocked on this machine, for an unrelated reason

The verify command builds clean and then never launches:

```
xcodebuild test -project Tenon.xcodeproj -scheme Tenon -configuration Debug \
  -destination 'platform=macOS' -clonedSourcePackagesDirPath .build \
  -only-testing:TenonIntegrationTests CODE_SIGNING_ALLOWED=NO
→ Testing failed:
    Could not launch "TenonIntegrationTests"
    … The LaunchServices launcher has returned an error … (IDELaunchErrorDomain code 20)
  ** TEST FAILED **  (exit 65)
```

Reproduced at 13:10 and 13:49. This is a launcher refusal, not the CI crash — no test ever runs,
and CI does launch fine. The likely reason is a `/Applications/Tenon.app` running as
`dev.tenon.app` while LaunchServices is asked to start the DerivedData build of the same bundle
id; that instance belongs to the human at this machine and was left alone. Anyone trying to
reproduce T-135 locally should expect to quit their own Tenon first.

### Why no code change shipped this session

Both fixes the criteria allow are currently unbuyable:

- *Make it survive.* Every candidate edit rests on a hypothesis the evidence does not yet pick
  between, and the one probe that could have supported the strongest candidate (`/bin/sh`) refuted
  it instead. Changing the test's stimulus on that basis would be a guess wearing a fix's clothes.
- *Move it to `ui-smoke`.* That lane is `runs-on: macos-15` — the same Apple VM image, with no
  extra GUI session of its own. The crash follows the test there, and a permanently red nightly
  lane is worse than a named red per-push one, so this would be relocation, not repair.

Next session starts with a named frame instead of a reconstruction: push anything, open the
`Collect crash reports from the hosted lane` step (or the `integration-crash-reports` artifact),
read `exception.type` / `faultingThread` / the top frames, and H-teardown vs H-renderer decides
itself.

## Criteria

- [x] The mechanism is named as far as evidence reaches: the host **crashes** inside the
      libghostty surface path ~0.3 s after the test surface's child exits at ~1.1 s; it is not an
      `exit()` call, not a failed init, and not "no GPU/display". The faulting frame is still open.
- [x] Evidence, not inference — log lines from the runner, twice, with timestamps (table above),
      plus the successor process's sentry crash capture. A stack is the one thing still missing,
      and collecting it is now a CI step.
- [ ] The behaviour is covered somewhere that runs it: either the test survives the VM, or it moves
      to `ui-smoke` **and** the task records what the per-push lane stops proving
- [ ] `macOS CI` reaches a green run — the first in over 40
- [ ] `docs/prds/terminal.prd.md` records whether rendering a real surface is a per-push guarantee

## Owner / files (agent lock)

Session `5d1e7e00` — claimed 2026-08-12 13:35:

- `.github/workflows/macos-ci.yml`
- `.kanban/tasks/T-135-a-real-surface-that-kills-the-test-runner.md`

Read-only this session: `Tests/TenonIntegrationTests/GhosttySurfaceSmokeTests.swift`,
`Sources/TenonApp/GhosttySurface.swift`, `Sources/TenonApp/SurfacePool.swift`,
`Sources/TenonApp/TenonApp.swift`. Neither the test nor the surface was edited — see
“Why no code change shipped this session”.

Useful: `gh run download <id> -n integration-xcresult -D <dir>` then
`xcrun xcresulttool get test-results summary --path <dir>` — the plain CI log does not carry the
failure reason, and that is how this one was finally read.
