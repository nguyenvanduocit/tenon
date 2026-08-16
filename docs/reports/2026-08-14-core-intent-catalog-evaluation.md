# Core intent catalog evaluation — 2026-08-14

**Status: dated evidence, not a status board.** Like the CLI capability survey beside it,
this report is never edited to stay current; when it and the tree disagree, the tree wins.
Anything actionable here lives as a `.kanban` task and a decision-log entry in the owning
PRD — this report is where a claim came from, never where its status lives.

**Method.** Every one of the 51 definitions in `Sources/TenonCore/CoreIntentCatalog.swift`
(read in full at lines 534–2213 on 2026-08-14) was scored against the five clauses of the
legible boundary principle derived in
[`../research-intent-design-principles.md`](../research-intent-design-principles.md):

1. boundary placed where trust changes owner;
2. declared before execution;
3. only bounded, typed values cross — policy must be able to decide from the payload and
   scope alone;
4. closed vocabulary, unknowns refused;
5. name never re-means after shipping.

Clauses 1, 2, and 5 are satisfied **by construction** for the whole catalog: every entry is
a compiled, fitness-tested contract behind the audience exhaustive switch
(`CoreIntentCatalog.swift:70-147`), and every name carries its major version, with two
contracts already at `.v2` (`filesystem.directory.list.v2`, `workspace.pane.close.v2`)
proving the breaking path is exercised, not theoretical. The per-intent work below is
therefore about clauses 3 and 4, plus the effect/confirmation/binding metadata.

## Verdicts by domain

Verdict key: ✓ conforms · ✓* conforms with a note · ⚠ finding (see Findings).

### Filesystem — lane `filesystem`, programmatic, capability `filesystem.read`/`filesystem.write` with path argument scope

| Intent | Effects | Verdict |
|---|---|---|
| `filesystem.directory.list.v2` | read | ✓ cursor-paged, 256-entry bound, metadata opt-in priced in the description |
| `filesystem.file.read.v1` | read | ✓ cursor carries file identity; a changed file returns `invalidated` instead of shifted bytes — the "continuation token is not a handle" doctrine, working |
| `filesystem.path.exists.v1` | read | ✓ |
| `filesystem.file.write.v1` | write · policy | ✓ multi-page staging is a value protocol, not a handle: host-owned staging, atomic commit rename, forged or out-of-sequence cursors fail closed |
| `filesystem.directory.create.v1` | write · policy | ✓ refuses implicit ancestors — explicitness over convenience |
| `filesystem.file.create.v1` | write · policy | ✓ fails if destination exists |
| `filesystem.path.move.v1` | write · policy | ✓ **both** `sourcePath` and `destinationPath` are in the capability's argument scope (`:551-554`) — policy reads the whole subject by value |
| `filesystem.path.trash.v1` | destructive · policy | ✓ recoverable Trash; see "deliberate absences" — there is no irreversible delete in the vocabulary at all |

### File/OS hand-off — lane `system`, programmatic, capability `shell.open`

| Intent | Effects | Verdict |
|---|---|---|
| `file.reveal.v1` | write · policy · external | ✓ |
| `file.open.v1` (`open` class) | write · policy · external | ✓ provider-selectable without a kernel chooser |
| `url.open.v1` (`open` class) | write · policy · external | ✓* same capability, different subject binding (path vs URL), rationale in a code comment (`:559-561`) — the capability/subject separation stated where it is used |

### Clipboard — lane `system`, pluginOnly

| Intent | Effects | Verdict |
|---|---|---|
| `clipboard.write.v1` | write · external | ⚠ **F2** — the catalog's only external-effect write with no capability binding and no inherent user interaction |

### Process — lane `process`, programmatic, capability `process.exec`

| Intent | Effects | Verdict |
|---|---|---|
| `process.exec.v1` | write · policy · external | ✓* **the designated escape hatch, held honestly** — see F1 |

### Terminal — lanes `terminalImmediate`/`terminalWait`, programmatic, capabilities `terminal.write`/`terminal.read`

| Intent | Effects | Verdict |
|---|---|---|
| `terminal.write.v1` | write · policy · external | ✓* payload is semantically opaque (keystrokes); authority attaches to scope + capability, not content — fd-write class, see F1 |
| `terminal.run.v1` | write · policy · external | ⚠ **F3** — contract conforms; the provider path under it violates the fail-closed-bound clause today (T-159) |
| `terminal.open.v1` | write · policy · external | ✓* returns a `paneID` that "confers no ownership" — designation-not-authority written into the contract description; same provider-path exposure as F3 |
| `terminal.viewport.read.v1` | read | ✓ one bounded observation |
| `terminal.scrollback.read.v1` | read | ✓ admits the emulator has no stable row identity; resize returns `invalidated` rather than shifted rows |
| `terminal.process.read.v1` | read | ✓ names its own refusal: "no CPU, memory, or footprint figure crosses this contract" |
| `terminal.wait.v1` | read | ✓ closed condition enum, `timeoutMs ≤ 55s` inside the 60s dispatcher deadline, exactly one result; its lane counterexample is already recorded in the law |

### Browser surface — lane `browser`, pluginOnly, capability `web.view`

| Intent | Effects | Verdict |
|---|---|---|
| `browser.surface.load.v1` | write · policy · external | ✓ URL in argument scope |
| `browser.surface.back.v1` / `forward.v1` / `reload.v1` | write · external | ✓ caller-owned surface by bounded `surfaceID` value |

Navigation verbs only — see "deliberate absences" for what is *not* here.

### User interaction — lanes `userPrompt`/`userNotification`, pluginOnly, no capability binding

| Intent | Effects | Verdict |
|---|---|---|
| `ui.pick.v1` | write | ✓ bounded exact list (≤256); cancellation is a value (`selectedID: null`), not an exception path |
| `ui.prompt.v1` | write | ✓ |
| `ui.confirm.v1` | write | ✓ carries `destructive: boolean` so the host can render weight honestly |
| `ui.toast.v1` | write | ✓ closed `kind` enum |

No capability binding is coherent here: the interaction **is** the mediation — the person
sees the dialog the intent creates. That reasoning is exactly why F2 flags clipboard, where
no person sees anything.

### Secrets — lane `secrets`, pluginOnly, capability `secrets`

| Intent | Effects | Verdict |
|---|---|---|
| `secrets.get.v1` | read | ✓ caller-isolated namespace; Keychain correctly an intent, not a storage facility (the law's own §scoped-facility rationale) |
| `secrets.set.v1` | write · policy | ✓ |
| `secrets.delete.v1` | destructive · **always** | ✓ the catalog's only `confirmation: .always` — the one operation where repeat-prompt cost is accepted |

### Workspace — lane `workspace`, programmatic, capability `workspace.control`

| Intent | Effects | Verdict |
|---|---|---|
| `workspace.state.v1` | read | ✓ cursor+limit snapshot |
| `workspace.identity.set.v1` | write | ✓ base64 image "decoded, bounded, and normalized to a small PNG before it enters workspace state" — validation at the boundary, stated in the contract |
| `workspace.pane.owner.v1` | read | ✓ |
| `workspace.tab.create.v1` | write | ✓ |
| `workspace.tab.focus.v1` | write | ✓ target from invocation scope, not payload |
| `workspace.tab.close.v1` | destructive · policy | ✓ `close-refused` for the last tab — refusal over silent emptying |
| `workspace.pane.split.v1` | write | ✓ closed axis enum |
| `workspace.pane.focus.v1` | write | ✓ |
| `workspace.pane.close.v2` | destructive · policy | ✓ the exercised `.v2` path |
| `workspace.pane.content.set.v1` | write | ✓ |
| `workspace.pane.title.set.v1` | write | ✓* truncates an over-long title instead of refusing — see F4 |
| `workspace.content.open.v1` | write | ✓ placement is host policy, "never opens a tab" — the caller states outcome, not layout |
| `workspace.tab.next.v1` / `previous.v1` | write | ✓ |
| `workspace.pane.focus-next.v1` | write | ✓ |
| `workspace.select.v1` | write | ✓ |

### Network — lane `network`, programmatic, capability `network` with URL argument scope

| Intent | Effects | Verdict |
|---|---|---|
| `network.fetch.v1` | write · policy · external | ✓ closed method enum, URL readable by policy, text-only bodies — binary is refused rather than smuggled |

### Agent — lanes `agentImmediate`/`agentWait`, programmatic, capability `terminal.write`

| Intent | Effects | Verdict |
|---|---|---|
| `agent.inventory.v1` | read | ✓* data minimization in the contract ("no executable path and no shell history"); knowledge gated behind `terminal.write` — the only use of the answer is to drive a terminal, so a caller that cannot act cannot enumerate, an anti-profiling choice worth keeping deliberate |
| `agent.command.v1` | read | ✓ "starts nothing and writes nothing" — composition separated from execution |
| `agent.ask.v1` | write | ✓ **the catalog's best contract**: `evidence` is *required* with `minItems: 1` — the VISION tenet "evidence-linked compression" enforced by schema, not convention; typed choice values; expiry as a value (`status: expired`); nothing written into any terminal |

## Deliberate absences — the vocabulary's refusals, named

Conformance to clause 4 shows most clearly in what is *not* in the catalog. None of these
absences is an oversight; each removes an attack or deception class:

- **No `clipboard.read`.** Plugins can hand text to the person, never harvest what the
  person copied elsewhere.
- **No irreversible filesystem delete.** `filesystem.path.trash.v1` is the strongest verb
  that exists; recovery stays in the user's hands.
- **No browser script evaluation or DOM read.** Four navigation verbs; a plugin cannot turn
  the caller-owned surface into a scraping or injection engine.
- **No terminal resource telemetry.** `terminal.process.read.v1` says so in its own
  description; identity crosses, footprint does not.
- **No process spawn-and-keep.** `process.exec.v1` is run-to-completion with bounded
  output and a 60s ceiling; long-lived processes live in the RESOURCE mechanism
  (`process.stream`), where teardown-on-reload is defined.

## Findings

**F1 — the two honest opaque channels are load-bearing and must stay lonely.**
`process.exec.v1` and `terminal.write.v1`/`run.v1` are the catalog's ioctl-class contracts:
policy cannot read intent from argv or keystrokes. The catalog handles this the only honest
way — `process.exec` declares **no** filesystem path bindings precisely because "a child
can access the invoking user's files and network through argv or its own syscalls, so
filesystem path bindings would imply confinement the host does not enforce"
(`CoreIntentCatalog.swift:566-568`), and the gate is standing consent to one named
capability plus pane scope. The io_uring lesson applies as maintenance guidance, not as a
defect: these contracts must never gain convenience variants (a shell-string exec, an
unscoped write), never widen audience, and any future flexibility request should produce a
new narrow verb instead. No change; recorded so the next reviewer refuses the widening.

**F2 — `clipboard.write.v1` has no capability binding (⚠, routed to T-164).**
The definition (`CoreIntentCatalog.swift:959-979`) passes no `bindings:`, and the default
is `[]` (`:2262`), so zero `CapabilityRequirement`s are generated
(`Sources/TenonIntentCore/IntentDispatchRule.swift:215-216`). Every other external-effect
write in the catalog either carries a capability binding or inherently shows the person a
dialog. Clipboard replacement is a real attack class (paste hijacking), and this is the one
contract where an installed plugin acts externally with neither a grant to revoke nor
anything visible. Manifest declaration plus install-time standing consent may be the
deliberate gate (the Android install-permission model) — but if so, the decision is
recorded nowhere. T-164 verifies which it is and either adds the binding or records the
decision. Confidence: HIGH on the mechanics, MEDIUM on whether it is a gap or an
undocumented decision.

**F3 — a bound in the terminal provider path does not fail closed (already T-159).**
The contracts bound `command` correctly, but the provider under `terminal.open.v1`/
`run.v1` flushes the command into the PTY before the shell exists, and the macOS canonical
input queue caps at 1024 bytes and **silently discards the rest** — root-caused and
live-reproduced on 2026-08-14 (task T-159). This is the Binder lesson in its exact form: a
limit that drops silently is not a bound. The fix belongs to the provider (deliver after
shell-ready, or refuse loudly), not to the contract. This report adds the principle-level
framing to the already-filed task; nothing new to route.

**F4 — `workspace.pane.title.set.v1` coerces instead of refusing (accepted, one line).**
An over-long title is truncated rather than refused (`CoreIntentCatalog.swift:1848-1855`),
which reads against clause 4. The boundary is intact — the kernel still refuses payloads
over the 4096 schema bound; truncation is a *display* decision by the owning provider, with
its rationale in a code comment ("a 70-character label is a working label"). Accepted as
is; noted so the pattern is copied only for display-bound values, never for subjects of
policy.

**F5 — read-knowledge gated by acting-capability is a pattern worth writing down (no
defect).** `agent.inventory.v1` and `agent.command.v1` are reads that require the
`terminal.write` capability. This inverts a common design (reads cheap, writes gated) for a
good reason — the answer's only use is to act, and enumeration is itself a capability
(Android API 30's package-visibility lesson). If a future read intent serves a caller that
genuinely cannot act, it needs a new deliberate audience decision, not a copy of this
binding.

## Coverage

Evaluated: all 51 contract definitions (schemas, effects, confirmations, bindings, lanes,
audiences, timeouts, error lists), the audience and lane exhaustive switches, and the
binding-to-requirement path in `IntentDispatchRule.swift:215-216`. **Not** evaluated:
provider implementations behind the contracts (except T-159, taken from its task file's
live reproduction), the policy engine's grant/consent stores, and the plugin-owned intents
of bundled plugins — each is a different review. No intent was executed; every claim above
is from source read on 2026-08-14.
