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

## Owner / files (agent lock)

_Unclaimed._ Expected: `Sources/TenonApp/AppIntentRuntime.swift`,
`Sources/TenonApp/CLICommandExecutor.swift`, `Sources/TenonApp/AgentSessionHooks.swift`,
`Sources/TenonCore/PaneActivity.swift`, `Sources/TenonCore/CoreIntentCatalog.swift`,
`Sources/TenonIntentCore/IntentDispatcher.swift` (read-mostly), plus tests and the PRD pair.
⚠️ `CoreIntentCatalog.swift` also appears in T-133's expected set — check the board before editing.
