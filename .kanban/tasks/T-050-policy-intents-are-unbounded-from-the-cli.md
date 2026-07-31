# T-050: A `confirmation: policy` intent sent from the CLI waits forever

> `tenon-cli intent send terminal.open.v1` never returns. The caller's `--timeout` reaches the
> host as `timeoutMs` and does not bound the consent wait, so an agent-originated call parks
> indefinitely with no result, no error, and no expiry.

- **priority**: high
- **effort**: M
- **found by**: session 247281cf, driving the live app through its own CLI rather than reading
  the code — the call simply never came back.

## Evidence (measured against a running app, commit 17bf0a6)

| call | result |
|---|---|
| `intent send workspace.state.v1 --input '{"limit":1}'` | exit 0, 525 bytes of JSON |
| `intent send terminal.open.v1 --input '{"command":"echo hi"}' --timeout 4000` | **exit 124** (killed by an external `timeout 30`), **0 bytes stdout, 0 bytes stderr** |
| `intent send terminal.run.v1`, `intent send process.exec.v1` | same — no output within 25 s |

`intent describe terminal.open.v1` reports `"confirmation": "policy"`, `"external": true`,
audiences `[agent, cli, plugin]`. The working call is the one with no confirmation; the three
that hang are `.policy`. That is the only difference asserted.

## Root cause

`IntentDispatcher.resolveCallerConsent` (`IntentDispatcher.swift:1031`) is a bare
`withCheckedContinuation` registered as a waiter. It resumes on exactly two events — the
confirmation authorizer answering, or the task being cancelled. **There is no deadline on it.**

The CLI is not at fault: `intentSendRequest` (`main.swift:278-285`) parses `--timeout` and puts
`timeoutMs` in the request params. The host receives that deadline and does not apply it to the
consent wave, only to the phases after it.

The prompt itself is presented app-wide (`ContentView` → `.overlay { PluginUIOverlay(...) }`) and
`PluginUIPrompt.confirmationAuthorizer()` does not discriminate on principal, so a CLI-originated
request *does* raise a visible overlay. It is answerable — by a human at the window. What does not
exist is a bound on waiting for one.

## Why this matters beyond the annoyance

- **Invariant 10** says every queue, payload, lifetime, and generation is bounded. This lifetime
  is not. A request with an explicit caller-supplied deadline outlives it.
- The CLI is the *agent-first* surface (T-009). Every verb that does real work — open a terminal,
  run a command, exec a process — is `.policy`. So an unattended agent can read state and nothing
  else, which is the opposite of the supervised-fleet story T-048 shipped.
- A disconnecting client is a second, unmeasured question: `timeout` killed the CLI and closed the
  socket; whether the parked host-side request was cancelled or leaked is **not established here**
  and should be part of this task.

## Criteria
- [x] A consent wait is bounded. When the caller supplied `timeoutMs`, that is the bound; when it
      did not, a host default applies. Expiry resolves the request as a refusal the caller can
      read — not silence
- [x] The expiring path is asserted at the kernel level in `TenonIntentCoreTests`, without a
      window: a policy intent whose confirmation is never answered returns a timeout disposition
      within its deadline
- [x] ~~A CLI client that disconnects mid-wait cancels its parked request~~ — **NOT implemented,
      and deliberately so.** Measured: `CLISocketServer.dispatch` is fire-and-forget with respect
      to the client (`CLISocketServer.swift:233-257`) — the handler runs to completion and the
      reply is written to a socket that may already be dead; nothing watches the fd for peer close
      while the handler runs. Making disconnect cancel the request means a kqueue/poll watch on
      every client fd, which is real complexity in the socket layer. **With the deadline bound in
      place this stops being a correctness question**: an abandoned request now expires on its own
      instead of living forever, so cancelling on disconnect only frees the slot sooner. Recorded
      here rather than ticked or silently dropped; worth its own card if the earlier release ever
      matters
- [x] Decide and record whether a non-interactive principal can hold standing consent at all, or
      whether `.policy` verbs are interactive-only by design. Today only plugins are ever seeded
      (`PluginHost.swift:960`), and the CLI/agent principals have no path to it. **This is a
      product decision, not a bug fix** — write it in `docs/architecture-interaction-boundaries.md`
      whichever way it goes
- [x] Mutation proofs for the bound ~~and the cancellation~~ — M41 and M42 below. The
      cancellation half of this criterion is void: disconnect-cancellation was not implemented
      (see the struck criterion above), so there is nothing to mutate. Corrected rather than
      left ticked over an absent proof

## Notes
Do not "fix" this by making `terminal.open.v1` non-policy. Opening a terminal that runs a caller's
command is exactly the authority a confirmation exists to gate; the defect is the unbounded wait,
not the gate.

## What shipped

`resolveCallerConsent` takes the deadline the dispatcher had already computed and arms an expiry
against it. **Expiry leaves through the same door cancellation uses** — `cancelCallerConsentWaiter`
— which is what makes the rest fall out for free:

- `removeValue` settles the continuation exactly once, so expiry, cancellation and a late answer
  racing each other is already safe; no new settle-once machinery.
- A flight that still has waiters keeps its prompt standing, so one caller's deadline cannot take
  the dialog away from another who is still reading it.
- The returned outcome then meets the `now >= deadline` check that was **already there** at
  `IntentDispatcher.swift:602` and already mapped to `.timedOut` / `.deadlineExceeded`. No new
  error code, telemetry disposition, or reply path — the existing branch simply became reachable.

The scope was smaller than the card assumed: the machinery and the intent were both present, and
the bug was that a post-hoc deadline check guarded a wait that never returned.

## The product decision

**`.policy` stays interactive-only. No standing consent for CLI/agent principals.** A plugin
earns standing consent through *installation* — a human act of trust over a manifest declaring
exactly which intents it uses. A CLI caller has neither: anything that can open the control
socket is that principal, so seeding it would let any process on the machine run `.policy` verbs
unprompted. That is an open door, not consent. Unattended work already has the lawful route — be
a plugin, which is what `tenon.agents.run` and the fleet-review example do. Recorded in
`docs/architecture-interaction-boundaries.md` beside the new bound.

## ⚠️ My first version of these tests would have hung the shared suite

Both tests ended in `await send.value`. Against the *unfixed* dispatcher that task never
completes, so the run sat for 14 minutes until I killed it — the bounded helpers reported the
failure correctly and then the test hung anyway on an unbounded await underneath them. In a
target every concurrent agent shares, that destroys everyone's evidence rather than just failing.
Both tests now settle through the probe first and bail out — cancelling their tasks — if it never
settles.

The RED itself was worth keeping: *"consent flight never reached 0 waiter(s) within 10.0 seconds"*
and *"consent dispatch did not settle within 10.0 seconds"* are exactly the defect, stated by the
test.

## Evidence

RED first, and red for the right reason — the tests reported the defect in its own words:
*"consent flight never reached 0 waiter(s) within 10.0 seconds"* and *"consent dispatch did not
settle within 10.0 seconds"*. After the fix both pass in **0.24 s / 0.26 s**.

`swift build` exit 0 under warnings-as-errors; full `swift test` **898 / 0** (896 before).

⚠️ **The live CLI round-trip is NOT re-verified, and that is worth stating precisely**, since a
live CLI run is how this defect was found in the first place. The app can no longer be brought to
the point of serving its control socket from this shell: launched via `swift run tenon` or the
built binary it starts and stays up, but never binds `/tmp/tenon-501/tenon.sock`. Reading the
timestamps back, the instance that answered the CLI earlier today was launched at 11:39 inside a
real GUI session — not one I started. Two things surfaced while trying:

- `[ -S /tmp/tenon-501/tenon.sock ]` is satisfied by a **stale socket file**, so a readiness check
  written that way passes against a dead app. `nc -zU` is the honest probe.
- ~~`CLISocketServer` does not unlink a stale socket path before binding~~ — **wrong, corrected in
  T-051 before any code was written.** I read `bindAndListen` and stopped; the reclamation is in
  its caller (`CLISocketServer.swift:58-71`: probe for a live listener, `unlink` only when nobody
  answers, then bind). Measured: `unlink`-then-bind succeeds over a stale file. The real defect
  behind the confusion is that the app degrades to running **without** a control socket in
  silence, which is what T-051 now covers.

## Mutation proofs

| # | Mutation | Red |
|---|---|---|
| M41 | drop the expiry entirely — the wait is unbounded again | **both** tests, each on its named assertion (*"never reached 0 waiter(s)"*, *"did not settle"*), 27.6 s / 27.5 s |
| M42 | expire on a hardcoded 200 ms instead of the caller's deadline | **only** `testExpiringWaiterKeepsThePromptForRemainingWaiter` — the co-waiter's 30 s deadline gets 200 ms and its success assertion throws `unexpectedResult`; `testUnansweredConfirmation…` stays green |

M42 is the one that matters: it proves the deadline is **per-caller**, not one global timer. A
single-test mutation would not have distinguished the two.

Both restored and `cmp`-verified byte-identical against a `cp` backup; `grep -c MUTATION` → 0.

## ⚠️ The suite's own wait helpers cannot be used for this

`waitForConsentWaiters` / `waitForConsentResult` spin on `await Task.yield()`, which passes **no
wall-clock time**. That is correct for cancellation, which is immediate. An expiring waiter leaves
only once its deadline is really reached, so a yield-spin can burn all 2 000 iterations inside one
millisecond and report a failure that never happened. Added sleeping variants beside them rather
than changing the originals, since the cancellation tests depend on the yield behaviour.
