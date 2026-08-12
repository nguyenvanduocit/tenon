# T-136: Give the AI a name of its own

> Tenon has two users and one identity. Every intent an agent sends arrives wearing the human's.

- **priority**: high
- **effort**: M
- **owning PRD**: `docs/prds/agent-control.prd.md` — `AC-FR-037`, `AC-FR-041`, `AC-FR-042`, `AC-NFR-010`

## The finding

`IntentPrincipal.Kind.agent` is constructed in **exactly one place in this repository**, and it is a
test that rejects a spoof: `Tests/TenonIntentCoreTests/IntentPolicyTests.swift:707`. Nothing under
`Sources/` mints one. Every call an agent makes arrives as
`IntentPrincipal(id: "cli:local-user", kind: .cli)` (`Sources/TenonApp/AppIntentRuntime.swift:31-35`,
used at `CLICommandExecutor.swift:40,48,71`) carrying `filesystem: .all, panes: .any`
(`AppIntentRuntime.swift:383-405`), with `bypassAllPermissionPrompts` defaulting `true`
(`Sources/TenonCore/AppPreferences.swift:121`).

The cost is exact and checkable. `IntentDispatcher.effectiveConfirmation`
(`Sources/TenonIntentCore/IntentDispatcher.swift:1253-1263`) says an open-class policy intent from
an `agent` audience **must always confirm**:

```swift
guard contract.effects.confirmation == .policy,
      caller.audience == .agent,        // never true in production
      contract.contractClass == .open
else { return contract.effects.confirmation }
return .always                           // unreachable
```

That is a security guard that cannot fire, because the condition it tests is never constructed. The
`agent` audience — named in invariant 8, declared by `CoreIntentAudienceProfile.programmatic`
(`Sources/TenonCore/CoreIntentCatalog.swift:70-83`) on 34 intents — is a promise the tree has not kept.

## Why this is the foundation and not a detail

Nearly everything a swarm needs is already shipped and already declared `.programmatic`, so one
agent can already start another and read its result:

| primitive | intent | status |
|---|---|---|
| what agents exist here | `agent.inventory.v1` | shipped |
| compose an agent's command line | `agent.command.v1` | shipped |
| open a pane running it | `terminal.open.v1` | shipped |
| give it work | `terminal.write.v1` | shipped |
| wait for it | `terminal.wait.v1` (3 conditions) | shipped |
| read its result | `terminal.scrollback.read.v1` | shipped |
| the whole loop, composed | `tenon.agents.run` | shipped |

What is missing is not capability. It is **identity** — and without it there is no policy, no audit,
no per-agent scope, and no way to tell two agents apart or tell either from the person.

## Scope

**In:** mint the principal, and the two reads that only make sense once it exists.

1. `AC-FR-037` — an intent originating in a pane running an agent carries `kind: .agent`, minted by
   the host **from the pane's identity**, never self-asserted. The material is already authenticated:
   the hook boundary receives `X-Tenon-Pane-ID` plus a surface token
   (`Sources/TenonApp/AgentSessionHooks.swift:699-748`), and `$TENON_PANE_ID` is set on the pane
   (`Sources/TenonApp/TenonApp.swift:496`). A caller that merely *claims* to be an agent is still `.cli`.
2. `AC-FR-041` — declared state outranks inferred state. `PaneActivity`
   (`Sources/TenonCore/PaneActivity.swift:19-25`) has `working|idle|finishedUnseen|seen|exited` and no
   `needsHuman`, while `IdleDetector.swift:19-27` calls a pane idle when its sample is unchanged three
   times — so **a pane blocked on an approval prompt is the most "idle" pane on screen**. The one state
   that needs a human is the state inference gets backwards.
3. `AC-FR-042` — an agent principal can read a bounded snapshot of its peers: pane, declared status,
   last declared claim. No transcripts.

**Out:** `agent.ask.v1` (T-137, depends on this), any scheduler, queue, task graph or dispatch loop —
Tenon exposes primitives, an AI owns the loop. See the 2026-08-12 decision-log entries.

## Criteria

- [ ] A call from inside an agent pane arrives with `kind: .agent`, proven by a test that asserts the
      principal, not by inspection
- [ ] A caller that self-asserts `agent` without the pane's authenticated identity is refused and stays
      `.cli` — the spoof test at `IntentPolicyTests.swift:707` still passes unchanged
- [ ] `IntentDispatcher.effectiveConfirmation` is reachable: a test drives an open-class policy intent
      from a real agent principal and observes `.always`, and it **fails** if the guard is removed
- [ ] `bypassAllPermissionPrompts` does not silently disarm that guard, or the PRD records why it may
- [ ] `PaneActivity` carries a declared `needsHuman` that only an agent can write and that outranks
      `IdleDetector`; inferred state reports itself as inference
- [ ] A peer snapshot intent returns pane + declared status + last claim, and no transcript content
- [ ] Contract behaviour asserted in `TenonCoreTests`/`TenonIntentCoreTests` **without a window**
- [ ] `swift test` green **run while the machine is loaded** (see T-134 — an idle run hides this class)
- [ ] `docs/prds/agent-control.prd.md` rows moved to `shipped` with a dated receipt

## Measurement that changed the design (2026-08-12, session `workflow-T136`)

The design of record was "match the caller's controlling terminal against the pane's PTY".
**It does not work, and the measurement is the reason the task is not finished.**

`claude` holds a controlling terminal; the shell it spawns to run a tool command does not.
Measured three independent ways on this machine, with the Bash-tool sandbox **on and off**:

| probe | `claude` (pid 18432) | its tool subprocess |
|---|---|---|
| `proc_bsdinfo.e_tdev` | `268435476` | `UInt32.max` (none) |
| `ps -o tty=` | `ttys020` | `??` |
| `open("/dev/tty")` | succeeds | fails |

A tty rule would mint nothing in production — the same disease this task exists to cure. The
design brief's contrary measurement (`node`/`caffeinate` children of `claude` inheriting the
tty) is true but measured the wrong children: those are not the channel an agent runs
`tenon-cli` through.

**Ancestry replaces it.** `setsid` does not change a parent, so walking `pbi_ppid` from
`LOCAL_PEERPID` still reaches the agent. It is also strictly more precise for what this
product must tell apart: a human typing at the pane's shell prompt descends from the *shell*,
not from the agent. No CLI wire-protocol change is needed.

## Landed

- `AgentCallerAdmission.admit` + `.ancestry` — the whole decidable rule, pure, 14 tests
- `AgentCallerProvenance` — `LOCAL_PEERPID` + `pbi_ppid` readers, 5 tests against live pids
- PRD decision log: the tty→ancestry reversal, and the `bypassAllPermissionPrompts` finding

## Not landed — the mint is not wired, so no `.agent` principal exists in production yet

Remaining, in order: capture the peer pid at `CLISocketServer` accept and widen `onRequest`;
assemble `[AgentPaneCandidate]`; mint in `CLICommandExecutor`; grant the new principal a set
strictly narrower than `cliPrincipal`'s (skipping this makes every agent call fail
`missingCapability`).

**The open design question that stopped it**, and it is not mechanical: nothing today answers
"which panes are running an agent" independently of the UI. `AgentLensPool.models`
(`Sources/TenonApp/AgentLensSession.swift:857-886`) is populated lazily by `model(for:)` when
a pane's Agent Lens is opened, so minting from it would make a caller's *identity* depend on
whether a human had looked at the pane. That is the wrong foundation for a policy input.

### A candidate answer, found 2026-08-12 — the hook registry already is that state

`AgentSessionHooks`'s binding registry is host-owned occupancy and nobody proposed it:

- `record(_:)` (`Sources/TenonApp/AgentSessionHooks.swift:109`) is driven by **the agent's own
  hook POST**, not by anything a human does.
- Its key is `Key(paneID:surfaceToken:)` (`:113`) — exactly the authenticated pair the mint needs,
  and the surface token is per-pane-materialization, exported only into that PTY.
- `binding(paneID:surfaceToken:)` (`:124`) answers "is an agent bound to this pane" directly.
- `retainOnly(_:)` (`:128`) bounds the lifetime to live panes.
- The file already classifies it, at `:26`: "the registry below is **host-private DIRECT state**".

**Two things to settle before using it, and neither is a detail.**

1. **Occupancy lags the agent.** `record` returns early unless the event carries a non-empty
   `sessionID` and a resolvable transcript path (`:110-112`). An agent that has started but not yet
   emitted a session-bearing hook is not in the registry, so its first calls would mint `.cli`. Is
   an identity that arrives late acceptable, or does occupancy need a second, earlier signal?
2. **The boundary doc may forbid exactly this.** `docs/architecture-interaction-boundaries.md:617-623`
   classifies these as "host-private agent lifecycle facts reported by Codex and Claude provider
   hooks" and says they "are not exposed to plugins, and **never enter the intent dispatcher**" — and
   a principal is an input to the dispatcher. Minting is host code rather than a plugin read, so this
   is plausibly inside the rule rather than against it; but it is close enough that the answer belongs
   in the boundary document and the PRD decision log **before** the code, not after.

   Corroboration for the mechanism, from the same passage: `:620` records that the hook already
   "resolves the provider ancestor's process group rather than reporting its own identity". Process
   ancestry is therefore not a new idea being smuggled in for the mint — it is the identity rule this
   boundary already uses, which is a point in favour of `AgentCallerAdmission` reading the way it does.

`AC-FR-041` and `AC-FR-042` were not started; both sit behind the mint.

## Owner / files (agent lock)

**Claimed by session `workflow-T136`** (2026-08-12). Files locked:

Released on 2026-08-12 — the session ended without wiring the mint, so nothing is held. Files
actually written (all landed green; none left mid-edit):

- `Sources/TenonCore/AgentCallerAdmission.swift` (new)
- `Sources/TenonApp/AgentCallerProvenance.swift` (new)
- `Tests/TenonCoreTests/AgentCallerAdmissionTests.swift` (new)
- `Tests/TenonAppStateTests/AgentCallerProvenanceTests.swift` (new)
- `docs/prds/agent-control.prd.md` (decision log + receipt)

Untouched, and free for the next session: `AppIntentRuntime.swift`, `CLICommandExecutor.swift`,
`CLISocketServer.swift`, `TenonApp.swift`, `PaneActivity.swift`, and `CoreIntentCatalog.swift`
(⚠️ the last is also in T-133's expected set — check the board before editing).

Original expectation: `Sources/TenonApp/AppIntentRuntime.swift`,
`Sources/TenonApp/CLICommandExecutor.swift`, `Sources/TenonApp/AgentSessionHooks.swift`,
`Sources/TenonCore/PaneActivity.swift`, `Sources/TenonCore/CoreIntentCatalog.swift`,
`Sources/TenonIntentCore/IntentDispatcher.swift` (read-mostly), plus tests and the PRD pair.
⚠️ `CoreIntentCatalog.swift` also appears in T-133's expected set — check the board before editing.
