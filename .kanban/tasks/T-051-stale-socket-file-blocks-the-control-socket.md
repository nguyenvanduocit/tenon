# T-051: The app runs with no control socket and says nothing

> ~~A leftover socket file permanently blocks the control socket~~ — **that premise was false and
> it was mine.** What is real: when the socket cannot be created, `CLISocketServer` degrades to
> running without one and emits no diagnostic, so `tenon-cli` reports "Tenon is not running"
> about an app that is on screen and nothing anywhere says why.

- **priority**: medium
- **effort**: S
- **filed**: 2026-07-31 by session 247281cf, then corrected by the same session before any code
  was written.

## ⚠️ The original premise, and how it was wrong

I filed this claiming `CLISocketServer.swift:143` returns on `bind` failure before reaching the
`unlink(path)` on the next line, leaving a stale socket file to block every later launch.

I had read `bindAndListen` and stopped there. The reclamation is not in `bindAndListen` — it is in
the **caller**, `init`, which already does exactly the right thing:

- `:58` probe for a live listener (`connect`); if one answers, become `.secondary` and exit — the
  single-instance guarantee holds;
- `:70` nobody answered, so `unlink(path)`;
- `:71` then bind;
- `:80` if bind still failed, probe again — that is the launch-race window — and defer to the
  winner.

The `unlink` at `:145` is cleanup for the narrow bind-succeeded-but-listen-failed case. It was
never the reclamation path.

**Measured, rather than re-read** (`python3`, unix sockets, scratchpad):

| step | result |
|---|---|
| bind over a stale socket file, no unlink | `Address already in use` — the failure I assumed happens |
| `connect` to that stale path | `Connection refused` — so the probe correctly reports "no live instance" |
| `unlink` then bind — what the app actually does | **succeeded** |

So a stale socket file does not block anything. The real reason the app I launched had no socket
is that it never finished launching: started from a non-interactive shell with no GUI session, the
process stays alive but never reaches `AppComposition.init`, where the server is constructed
(`TenonApp.swift:149`).

## What is actually worth fixing

**The silence.** Three paths leave the app running with no control socket and no diagnostic:
`CLISocketServer.swift:66` (socket directory could not be created), `:87` (no live instance and
bind still failed), and the case above where the server is never constructed at all. The CLI's
message names a missing file and asserts the app is not running — the two most misleading things
it could say — and there is no log line anywhere to contradict it.

For an agent-first control surface this is the expensive kind of failure: it sent me looking for a
stale-file bug that does not exist. That is the cost, measured on myself.

**And there are no tests.** `CLISocketServer` has none — not for the single-instance handshake,
not for reclamation, not for degradation. The rule I got wrong by reading is exactly the kind a
test states unambiguously.

## Criteria
- [x] The socket path is injectable so the rules can be asserted without touching the real
      user-wide socket. Default stays `wellKnownPath()`; nothing about the shipped behaviour changes
- [x] Asserted headlessly: a stale socket file with nothing listening is reclaimed and the server
      binds — the claim this card was wrongly filed on, now pinned so nobody re-files it
- [x] Asserted headlessly: a **live** listener on the path still wins — the second server becomes
      `.secondary` and the first keeps its socket. This is T-009's single-instance guarantee and it
      must not be traded away for the reclamation above
- [x] Failing to obtain a control socket is reported once, with the reason and the path, through
      the same logging the rest of the host uses. Silent degradation is the defect
- [x] Mutation proofs: removing the `:70` unlink reddens the reclamation test; removing the `:58`
      live probe reddens the single-instance test

## Evidence

`swift build` exit 0 under warnings-as-errors; full `swift test` **901 / 0** (898 before).
`CLISocketServerTests` 3/3 — the first tests `CLISocketServer` has ever had.

⚠️ **No RED phase for the reclamation and single-instance tests, by their nature**: both pin
behaviour that already worked, so they were green on first run. That greenness *is* the finding —
it is what proves this card's original premise false. M43 and M44 are what make them load-bearing
rather than decorative.

## What shipped

One test seam (`overridingPath`, defaulting to `wellKnownPath()`), one recorded reason
(`Degradation`, `nil` while a socket is held), and `reportDegradation` which sets it and says it
once through `NSLog` — the same channel `GhosttySurface` already uses for host failures. Nothing
about the shipped path changes; the app still keeps running without remote control, it just stops
doing it silently.

The seam exists because the shipped app uses **one well-known user-wide socket**. A test that
touched it would fight the developer's own running Tenon for the single-instance lock — and, worse,
could win.

## Mutation proofs

| # | Mutation | Red |
|---|---|---|
| M43 | drop the `:70` unlink — reclamation gone | **only** `testAStaleSocketFileIsReclaimed`, failing with `bindFailed` — i.e. the mutation reproduces exactly the behaviour I wrongly claimed the shipped code already had |
| M44 | drop the `:58` live probe — reclaim blindly | **only** `testALiveListenerKeepsTheSocketAndTheNewcomerStandsDown`; the second launch takes the socket from the running app, which is the disaster the Notes warn about |
| M45 | degrade without reporting | **only** `testFailingToBindIsReportedRatherThanSwallowed` |

M45 matters more than usual here: the reporting was written before its test, so this is the proof
that stands in for the missing RED.

Restored `cmp`-byte-identical after each; `grep -c MUTATION` → 0.

## 🐞 My fixture was broken in the way that looks like success

First run: two tests failed and the third **skipped**, which reads like a pass in the summary line.
Cause — `sockaddr_un.sun_path` holds 104 bytes, and `FileManager.temporaryDirectory`
(`/var/folders/<2>/<32>/T/`) plus a UUID-named subdirectory overruns it, so `bind` refused every
path the fixture produced. The `XCTSkipIf` I had written for over-long paths then hid it.

Two corrections, both about the failure being *visible*:

- the length check is a hard `XCTAssertLessThan`, never a skip — a skipped fixture is
  indistinguishable from a passing test;
- the live-listener precondition asserts `socketPath`, not `role`. A server that failed to bind is
  **also** `.primary`, so checking the role alone let a broken fixture pose as a running app —
  which is precisely what happened.

## Notes
Do not "fix" reclamation by unlinking unconditionally before probing. That would make a second
launch steal the socket from a running app, which is the exact guarantee T-009 built and the
reason the probe comes first.
