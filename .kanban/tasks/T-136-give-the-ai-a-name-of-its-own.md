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

**Out:** `agent.ask.v1` (T-139, depends on this), any scheduler, queue, task graph or dispatch loop —
Tenon exposes primitives, an AI owns the loop. See the 2026-08-12 decision-log entries.

## Criteria

- [x] A call from inside an agent pane arrives with `kind: .agent`, proven by a test that asserts the
      principal, not by inspection — `AgentPrincipalMintTests.testACallFromInsideAnAgentPaneCarriesTheAgentPrincipal`
- [x] A caller that self-asserts `agent` without the pane's authenticated identity is refused and stays
      `.cli` — the spoof test at `IntentPolicyTests.swift:707` still passes unchanged
- [x] `IntentDispatcher.effectiveConfirmation` is reachable: a test drives an open-class policy intent
      from a real agent principal and observes `.always`, and it **fails** if the guard is removed
- [x] `bypassAllPermissionPrompts` does not silently disarm that guard, or the PRD records why it may —
      **it does disarm it**, recorded in the PRD decision log (2026-08-12) and in the receipt
- [ ] `PaneActivity` carries a declared `needsHuman` that only an agent can write and that outranks
      `IdleDetector`; inferred state reports itself as inference
- [ ] A peer snapshot intent returns pane + declared status + last claim, and no transcript content
- [ ] Contract behaviour asserted in `TenonCoreTests`/`TenonIntentCoreTests` **without a window** —
      partial: the pure admission rule is in `TenonCoreTests/AgentCallerAdmissionTests` (20, no window),
      and the mint's own tests are headless in `TenonAppStateTests` because minting needs the app's
      composition root. Reopens with `AC-FR-041`/`AC-FR-042`, whose contracts belong in the core targets.
- [x] `swift test` green **run while the machine is loaded** — two independent full runs while a peer
      agent was actively building and editing this tree: `Executed 2051 tests, with 0 failures` both times
- [x] `docs/prds/agent-control.prd.md` `AC-FR-037` moved to `shipped` with a dated receipt

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

Released 2026-08-12 by session `5d1e7e00` — the mint is wired, green, and mutation-checked;
nothing is held. Files written this session (all landed green, none left mid-edit):

- `Sources/TenonCore/AgentCallerAdmission.swift` — `AgentPaneOccupancy` + `candidate(for:)`
- `Sources/TenonApp/AgentCallerProvenance.swift` — `ancestry(ofProcess:)`, `processGroupID(of:)`,
  `AgentPaneOccupancyReader`
- `Sources/TenonApp/AgentSessionHooks.swift` — `AgentBoundPane`, `AgentSessionRegistry.boundPanes()`
- `Sources/TenonApp/CLISocketServer.swift` — `LOCAL_PEERPID` at accept, `onRequest` carries `CLIRequestOrigin`
- `Sources/TenonApp/CLICommandExecutor.swift` — `CLIRequestOrigin`, `callerPrincipal`, the mint
- `Sources/TenonApp/AppIntentRuntime.swift` — `agentPrincipal(forPane:)`, `trustedGrants(over:reachesTheNetwork:)`
- `Sources/TenonApp/TenonApp.swift` — the composition-root wiring (one closure)
- `Tests/TenonAppStateTests/AgentPrincipalMintTests.swift` (new, 10 tests)
- `Tests/TenonCoreTests/AgentCallerAdmissionTests.swift` (+6), `Tests/TenonAppStateTests/CLISocketServerTests.swift` (+1)
- `docs/architecture-interaction-boundaries.md`, `docs/prds/agent-control.{prd.md,feature}`, `Tenon.xcodeproj`

Untouched and free: `Sources/TenonCore/PaneActivity.swift`, `Sources/TenonCore/CoreIntentCatalog.swift`
(⚠️ the latter is also in T-133's expected set — check the board before editing).

## Landed 2026-08-12 — the mint is wired

`AC-FR-037` is `shipped`. `tenon-cli` called from inside an agent's process subtree now
authorizes as `agent:pane:<uuid>` with `kind: .agent`; every other caller stays
`cli:local-user`.

**The boundary question was settled before the code**, as required.
`docs/architecture-interaction-boundaries.md:617-646` now states what "never enter the intent
dispatcher" permits: the registry contributes **membership only** (pane UUID + surface token,
both host-minted — no `sessionID`, no `transcriptPath`, no activity payload), and the hook's
declared process group acts **only as a veto**. The pid identity is matched against is always
the host's own kernel read of its PTY, so a forged hook post can deny a pane an agent identity
and can never confer one.

**The chain**: `LOCAL_PEERPID` read on the accept thread before the client sends a byte →
carried on the request as `CLIRequestOrigin` → `pbi_ppid` walked outward (bound 12) →
`AgentCallerAdmission.admit` matched nearest-first against candidates built from
`AgentSessionRegistry.boundPanes()` cross-checked with `SurfacePool.agentTerminalIdentity`.

**The narrowing**: the agent principal's grants are the CLI's with `network: .none` — the
`network` and `web.view` capabilities are not granted at all, and `shell.open` keeps its
filesystem scope while losing its network scope. Everything the supervised loop needs
(`terminal.open/write/wait/scrollback.read`, `filesystem.*`, `workspace.*`, `agent.*`) still
resolves, so the mint does not break the CLI it replaces.

### Three limits, stated rather than hidden

1. **Identity arrives late.** `AgentSessionRegistry.record` returns early without a
   session-bearing hook (`AgentSessionHooks.swift:110-112`), so an agent's calls before its
   first tool call mint `.cli`. Accepted: the window closes at the first tool call, every
   earlier signal available today is either UI-dependent or unauthenticated, and the failure
   direction is the status quo.
2. **`bypassAllPermissionPrompts` still disarms the forced re-ask.** The guard is now
   *reachable* and recorded in telemetry; it is *not yet a barrier* on a default install,
   because `PluginUIPrompt.swift:225-231` answers `.always` with `.allowOnce` before a prompt
   is drawn. Fixing that means defaulting the switch off or making it exclude agent-audience
   open contracts — neither is in this task's scope, and both are now recorded in the PRD.
3. **A plugin may declare `[.cli]` without `.agent`.** An agent-minted caller is then denied
   `audienceCannotInvoke` where the person succeeds. That is the audience system working, but
   it is a real difference from the identity it replaces. No shipped plugin does this.

## Still open — `AC-FR-041` and `AC-FR-042` were not started

Both sit behind the mint and the mint now exists, so they are unblocked:

- `AC-FR-041` — `PaneActivity` (`Sources/TenonCore/PaneActivity.swift:19-25`) gains a declared
  `needsHuman` only an agent principal can write, outranking `IdleDetector`; inferred state
  reports itself as inference.
- `AC-FR-042` — a bounded peer snapshot: pane, declared status, last claim. No transcript.
