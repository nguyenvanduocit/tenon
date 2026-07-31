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
- [ ] A consent wait is bounded. When the caller supplied `timeoutMs`, that is the bound; when it
      did not, a host default applies. Expiry resolves the request as a refusal the caller can
      read — not silence
- [ ] The expiring path is asserted at the kernel level in `TenonIntentCoreTests`, without a
      window: a policy intent whose confirmation is never answered returns a timeout disposition
      within its deadline
- [ ] A CLI client that disconnects mid-wait cancels its parked request — asserted, since the
      alternative is an accumulating set of waiters no one will ever answer
- [ ] Decide and record whether a non-interactive principal can hold standing consent at all, or
      whether `.policy` verbs are interactive-only by design. Today only plugins are ever seeded
      (`PluginHost.swift:960`), and the CLI/agent principals have no path to it. **This is a
      product decision, not a bug fix** — write it in `docs/architecture-interaction-boundaries.md`
      whichever way it goes
- [ ] Mutation proofs for the bound and the cancellation

## Notes
Do not "fix" this by making `terminal.open.v1` non-policy. Opening a terminal that runs a caller's
command is exactly the authority a confirmation exists to gate; the defect is the unbounded wait,
not the gate.
