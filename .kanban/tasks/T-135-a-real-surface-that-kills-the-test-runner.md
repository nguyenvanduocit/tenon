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

## Criteria

- [ ] The mechanism is named: what in the surface path exits the process on a VM with no display
      (libghostty init? a renderer with no GPU? a signal? an assertion in C?)
- [ ] Evidence, not inference — a stack, a signal number, or a log line from the runner
- [ ] The behaviour is covered somewhere that runs it: either the test survives the VM, or it moves
      to `ui-smoke` **and** the task records what the per-push lane stops proving
- [ ] `macOS CI` reaches a green run — the first in over 40
- [ ] `docs/prds/terminal.prd.md` records whether rendering a real surface is a per-push guarantee

## Owner / files (agent lock)

_Unclaimed._ Expected: `Tests/TenonIntegrationTests/GhosttySurfaceSmokeTests.swift`,
`Sources/TenonApp/GhosttySurface.swift` (read-mostly), possibly `.github/workflows/macos-ci.yml`
and `project.yml`.

Useful: `gh run download <id> -n integration-xcresult -D <dir>` then
`xcrun xcresulttool get test-results summary --path <dir>` — the plain CI log does not carry the
failure reason, and that is how this one was finally read.
