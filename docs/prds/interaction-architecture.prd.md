# PRD — Deterministic interaction boundaries and the intent kernel

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-011` |
| Lifecycle | `shipped`, normative |
| Owner | architecture, intent-kernel, plugin-host, CLI, palette, agent adapters, and host application domains |
| Reviewers | product, architecture, security, plugin runtime, CLI/agent, performance, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-020, T-042, T-078 |
| Normative source | [`architecture-interaction-boundaries.md`](../architecture-interaction-boundaries.md) |
| Intent specification | [`design-intent-bus.md`](../design-intent-bus.md) |
| Acceptance specification | [`interaction-architecture.feature`](interaction-architecture.feature) |

## 1. Executive summary

### Problem

Tenon has typed Swift host code, independently reloadable plugins, CLI and agent adapters,
palette and keybinding projections, events, long-lived terminal/browser resources, and declarative
UI. If each feature chooses a convenient mechanism, the same product operation appears through
several public paths, policy differs by caller, local UI pays remote-dispatch cost, event channels
become hidden commands, and lifecycle work is orphaned. This is the context-loss pattern that lets
one change restore a control while silently removing another route.

### Proposed outcome

Every exact semantic interaction is classified by one ordered law. Exact protocol lifecycle uses
closed CONTROL PLANE; independently owned declarative state uses CONTRIBUTION; an already-happened
fact uses EVENT; multi-result, large pull, or caller-owned lifetime uses RESOURCE/STREAM/TASK;
same-owner internal work uses typed DIRECT; exactly three plugin-private facilities use SCOPED
FACILITY; finite unicast request/reply across an owner or adapter boundary uses INTENT. An
under-specified interaction cannot ship.

Built-in SwiftUI and providers share one typed domain implementation. Plugins, CLI, and agents
enter one intent kernel for finite public work. Palette and registered product keybindings project
plugin-owned intent presentation; focused-view controls remain local. Exact inventories, DIRECT
growth gates, source-wide stale-path deletion, and architecture tests make the choice enforceable.

### Why now

T-020 established the canonical intent bus, T-042 proved two-way communication needs no seventh
CHANNEL mechanism, and T-078 closed execution-lane isolation and backpressure. The current law also
contains the live launcher, tab reorder, Copy ID, pane header, Agent Lens, Automations, and install-
channel decisions. A canonical PRD/Gherkin pair is needed so those facts remain one regression
contract rather than scattered architecture prose.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| ordered law and inventories | [`architecture-interaction-boundaries.md`](../architecture-interaction-boundaries.md) | high | normative classification, audiences, lanes, change protocol |
| intent kernel | [`design-intent-bus.md`](../design-intent-bus.md), `TenonIntentCore` | high | contracts, envelope, policy, providers, lifecycle, backpressure |
| architecture gates | `InteractionBoundaryFitnessTests`, `DirectInventoryGateTests` | high | adapter/local split, exact surfaces, DIRECT growth review |
| contract/lane gates | `CoreIntentCatalogTests`, intent mailbox/dispatcher/policy tests | high | exact catalog, profiles, pipeline, outcomes, lanes |
| latency receipt | `IntentKernelLatencyBudgetTests`, law measurement dated 2026-08-07 | high | debug CPU ratio below normative 700× ceiling |
| historical designs/tasks | T-020/T-042/T-078 and migration audit | medium | superseded handwritten paths and resolved counterexamples |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Choose one mechanism and one semantic implementation for every interaction, consistently across current and future callers. |
| Primary users? | feature engineers, plugin authors, CLI/agent integrators, reviewers, and users who expect route parity |
| Success? | deterministic classification, no duplicate public protocol, exact policy/lifecycle parity, measurable bounds and latency |
| Fixed constraints? | the user-provided AGENTS boundary law, normative architecture document, exact inventories and fitness tests |
| Unknown? | no current classification gap; a concrete falsifying counterexample would reopen the law through ADR review |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `IAR-A-001` | Six product mechanisms plus a closed control plane remain sufficient. | classify every new interaction; record counterexamples | supported; T-042 found no CHANNEL need |
| `IAR-A-002` | Compiled validation and sealed lookup remain within the current latency ceiling as catalog use grows. | release/debug benchmark and mutation tests | continuous |

## 3. Users, jobs, and vocabulary

The primary user is an engineer or AI agent changing Tenon. They need to know which boundary owns
a behavior before writing code. The affected plugin/CLI/agent author needs one discoverable
contract, while the person using the app needs launcher, keybinding, tab, pane, and native focused
controls to retain their appropriate routes without duplicate semantics.

- Classify a new interaction from owner, cardinality, lifetime, and reachability—not taste.
- Reuse the same typed domain behavior from native UI and all public adapters.
- Add one contract without opening a generic command or capability escape hatch.
- Cancel/reload/disable without duplicate effects or unresolved calls.
- Review inventory and regression evidence in the same change as behavior.

| Term | Meaning | Not to be confused with |
|---|---|---|
| semantic owner | components that ship, trust, install, reload, and evolve atomically | Swift target, actor, thread, or process |
| principal | host-minted caller identity used by policy | UI control or semantic owner |
| public adapter boundary | plugin, CLI, agent, palette, or registered product-keybinding projection | every in-process call |
| classification unit | one exact semantic interaction | a file, namespace, feature, or English verb |
| control plane | exact mechanism/protocol lifecycle operations | an extensible seventh product mechanism |
| designation | caller-supplied workspace/tab/pane target | authorization to use it |

## 4. Goals, measures, scope, and constraints

- `IAR-G-001` — Two reviewers applying the ordered law reach the same classification.
- `IAR-G-002` — One domain behavior has one implementation and at most one public protocol.
- `IAR-G-003` — Every public call has common schema, policy, provider, lifecycle, and telemetry.
- `IAR-G-004` — Same-owner UI remains typed, responsive, and free of unnecessary dispatch cost.
- `IAR-G-005` — Every new inventory surface or DIRECT exception is an explicit reviewed change.

Targets: zero generic app/core authority principal; zero core intents outside exact profiles; zero
core intents in zero or multiple lanes; zero finite adapter bypasses; zero product verbs in control
plane; zero duplicate public paths after a migration; exact `tenon` and scoped-facility inventory;
one dispatcher send ≤700× CPU of the equivalent actor DIRECT call in the specified test; all queues,
resources, payloads, deadlines, projections, and histories bounded.

In scope: classification, semantic ownership, principals, adapters, intent contracts, dispatch,
provider selection, policy, consent, cancellation, idempotency, generation/lane lifecycle,
backpressure, discovery projections, telemetry, performance, exact inventories, and change protocol.
Non-goals: using the intent bus as an internal function-call convention, generic app commands,
event replies, indefinitely held intents, provider-specific policy, automatic retry of side effects,
or a new public mechanism without a falsifying counterexample and ADR migration.

## 5. User experience

This architecture is primarily observed through consistent behavior. Native focused controls call
typed host services directly. Plugin-owned commands appear through the same manifest projection in
palette, launcher where eligible, and registered product keybindings; their invocation enters the
same intent dispatcher. CLI and agent discovery show only their policy-filtered contract set. A
denied call returns a structured reason, a cancelled call distinguishes whether work started, and a
provider reload never silently reroutes an admitted request.

Adding or changing an interaction requires the author to record semantic owner, principal,
cardinality, lifetime, authority, failure, and backpressure; update normative and source inventory;
add a failing fitness test; delete the superseded public route; perform stale-surface search and
verification; and obtain an independent reviewer pass. Host-native projections and diagnostics
follow [`designs.md`](../designs.md), including keyboard, pointer, VoiceOver, focus, contrast, and
non-color-only outcome parity.

## 6. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `IAR-FR-001` | Classification **MUST** derive semantic ownership from atomic ship/rollback, trust, independent install/reload, public discovery/provider need, and compatibility—not file, module, actor, thread, or process placement. | shipped | `@req-iar-fr-001` |
| `IAR-FR-002` | Policy **MUST** use host-minted principals distinct from owners and surfaces; built-in host code **MUST NOT** mint a generic app/core authority principal. | shipped | `@req-iar-fr-002` |
| `IAR-FR-003` | Plugin runtime, CLI socket, agent/MCP projection, palette, and registered product keybindings **MUST** count as public adapter boundaries; a focused-view control without public registration **MUST NOT**. | shipped | `@req-iar-fr-003` |
| `IAR-FR-004` | The system **MUST** classify one exact semantic interaction; mechanism setup/teardown **MUST** remain that mechanism's reserved lifecycle rather than a new product interaction. | shipped | `@req-iar-fr-004` |
| `IAR-FR-005` | The ordered decision law **MUST** be applied exactly: reserved control, CONTRIBUTION, EVENT, RESOURCE/STREAM/TASK, DIRECT, SCOPED FACILITY, then INTENT; evaluation **MUST** stop at the first match. | shipped | `@req-iar-fr-005` |
| `IAR-FR-006` | Independently owned declarative state/registration whose snapshot the contributor owns and host validates/reconciles/renders **MUST** use CONTRIBUTION and **MUST NOT** mutate host state during publication. | shipped | `@req-iar-fr-006` |
| `IAR-FR-007` | An immutable fact that already happened on a publisher-owned channel **MUST** use EVENT; the publisher **MUST NOT** await observers or receive their results. | shipped | `@req-iar-fr-007` |
| `IAR-FR-008` | Multi-result output, large pull bodies, or caller-owned lifetimes usable after initial reply **MUST** use a bounded RESOURCE/STREAM/TASK with explicit read/progress/cancel/teardown. | shipped | `@req-iar-fr-008` |
| `IAR-FR-009` | Same-owner work outside public adapters **MUST** use typed DIRECT calls and **MUST NOT** serialize through `IntentValue` or string routing merely to cross code/actor/test seams. | shipped | `@req-iar-fr-009` |
| `IAR-FR-010` | SCOPED FACILITY **MUST** remain exactly plugin-private settings, storage, and log with no provider choice, external discovery, cross-plugin address, or arbitrary authority. | shipped | `@req-iar-fr-010` |
| `IAR-FR-011` | A finite unicast request/reply crossing an independent owner or public adapter after earlier rungs fail **MUST** use one canonical INTENT and settle exactly once. | shipped | `@req-iar-fr-011` |
| `IAR-FR-012` | An interaction with unclear owner, result cardinality, lifetime, authority, failure, or backpressure **MUST NOT** be implemented until those facts make classification repeatable. | shipped process | `@req-iar-fr-012` |
| `IAR-FR-013` | Built-in UI and public adapters **MUST** reach one typed application/domain implementation; provider adapters validate/authorize/translate but **MUST NOT** duplicate domain semantics. | shipped | `@req-iar-fr-013` |
| `IAR-FR-014` | Code inside one plugin **MUST** call ordinary local JavaScript for its own implementation; it **MUST NOT** self-send an intent merely to organize internal code. | shipped | `@req-iar-fr-014` |
| `IAR-FR-015` | The DIRECT inventory **MUST** be explicit and pinned; a new or enlarged entry **MUST** carry exactly one `why not a plugin` or `host-native core` clause and update the count/length gate. | shipped | `@req-iar-fr-015` |
| `IAR-FR-016` | Each intent contract **MUST** have one versioned canonical name, owner, input/output schema, error vocabulary, effects, audiences, authority bindings, timeout, lifecycle, and compatibility rule compiled before invocation. | shipped | `@req-iar-fr-016` |
| `IAR-FR-017` | The host **MUST** mint immutable request/trace/parent IDs, caller, resolved scope, deadline, target, and idempotency metadata; payload fields **MUST NOT** overwrite them and live native/JS values **MUST NOT** enter the envelope. | shipped | `@req-iar-fr-017` |
| `IAR-FR-018` | Every public adapter **MUST** enter the common ordered pipeline for bounds, schema, declared use/policy, provider/consent, idempotency, lease/admission, asynchronous execution, output validation, settlement, and audit. | shipped | `@req-iar-fr-018` |
| `IAR-FR-019` | Caller designation **MUST NOT** equal authority; policy **MUST** authorize exact audience, declared use, grant/capability, resolved argument/scope, consent, target eligibility, and provider readiness. | shipped | `@req-iar-fr-019` |
| `IAR-FR-020` | Provider resolution **MUST** be deterministic from eligible active providers, explicit target, stable default, or explicit ambiguity; a provider **MUST NOT** inherit caller authority. | shipped | `@req-iar-fr-020` |
| `IAR-FR-021` | A request **MUST** settle once with validated success or structured domain/kernel failure; late replies **MUST NOT** settle twice and invalid provider output **MUST NOT** reach callers. | shipped | `@req-iar-fr-021` |
| `IAR-FR-022` | Cancel/deadline before physical start **MUST** report `notStarted`; after start **MUST** report `unknown` absent durable completion, retain admission until physical completion, and **MUST NOT** imply rollback. | shipped | `@req-iar-fr-022` |
| `IAR-FR-023` | The kernel **MUST NOT** automatically retry/fallback after start; keyed retry **MUST** atomically bind principal/contract/input/target/provider, join/replay one result, and reject changed input/target. | shipped | `@req-iar-fr-023` |
| `IAR-FR-024` | Provider generations **MUST** stage before atomic activation; admitted calls **MUST** lease one generation; failed staging preserves last good and retirement drains/cancels every lane before shutdown. | shipped | `@req-iar-fr-024` |
| `IAR-FR-025` | Every core intent **MUST** belong to exactly one closed execution lane with a distinct bounded mailbox; adding lanes **MUST NOT** multiply global admission. | shipped | `@req-iar-fr-025` |
| `IAR-FR-026` | `terminalWait` **MUST** admit at most 8 concurrent independent waits; every other core lane **MUST** remain serial unless this law and its counterexample evidence change together. | shipped | `@req-iar-fr-026` |
| `IAR-FR-027` | Lane admission **MUST** bound request count and bytes globally, per principal, and per lane, reserve interactive capacity, preserve per-principal FIFO with fairness, and return explicit overload rather than drop intents. | shipped | `@req-iar-fr-027` |
| `IAR-FR-028` | The dispatcher **MUST** reject a causal wait cycle, bound causal depth, rate-limit/coalesce progress, and keep fire-and-forget reactions on EVENT rather than detached intents. | shipped | `@req-iar-fr-028` |
| `IAR-FR-029` | `CoreIntentName` **MUST** own the exact versioned core inventory and execution-lane classification; adding/removing/renaming/changing it **MUST** follow the same change protocol. | shipped | `@req-iar-fr-029` |
| `IAR-FR-030` | Core intent audiences **MUST** be exactly programmatic `{plugin, cli, agent}` or plugin-only `{plugin}`; no core intent **MUST** expose `user`, generic app, or `core` authority. | shipped | `@req-iar-fr-030` |
| `IAR-FR-031` | Palette, launcher, and registered product-keybinding commands **MUST** project plugin-owned intent presentation metadata and invoke that plugin intent through one shared adapter; core intents **MUST NOT** be listed directly. | shipped | `@req-iar-fr-031` |
| `IAR-FR-032` | A host-wide/discoverable/rebindable product keybinding **MUST** use the plugin-owned projection; editor/palette/list/Ghostty controls consumed only by the focused view **MUST** stay same-owner DIRECT/local. | shipped | `@req-iar-fr-032` |
| `IAR-FR-033` | CLI direct control **MUST** be limited to `ping` and same-channel activation/focus; domain work **MUST** use policy-filtered `intent list`, `intent describe`, and `intent send`. | shipped | `@req-iar-fr-033` |
| `IAR-FR-034` | Agent/MCP adapters **MUST** project only the agent audience with canonical schemas/effect annotations/confirmation, bind listing to one policy revision, and map cancellation/progress to the same internal lifecycle. | shipped | `@req-iar-fr-034` |
| `IAR-FR-035` | Two-way request/reply **MUST** use declared intent(s), notification **MUST** use EVENT, and long work **MUST** use a bounded value/resource pattern; a duplex CHANNEL or event-with-reply **MUST NOT** be added. | shipped | `@req-iar-fr-035` |
| `IAR-FR-036` | Plugin event publication **MUST** use manifest-declared owner-local names qualified by host identity; observation **MUST** be separately declared and publisher **MUST** learn no listener identity/count. | shipped | `@req-iar-fr-036` |
| `IAR-FR-037` | Contributions **MUST** remain immutable bounded snapshots diffed/reconciled by host; owner UI facts may return through EVENT callbacks, while resulting product effects **MUST** use the already classified route. | shipped | `@req-iar-fr-037` |
| `IAR-FR-038` | CONTROL PLANE **MUST** remain the exact protocol/registry/provider/request/resource/plugin lifecycle set and **MUST NOT** carry product verbs; it is not extensible by plugins. | shipped | `@req-iar-fr-038` |
| `IAR-FR-039` | The exact public `tenon` path inventory **MUST** match the normative/source inventory; finite host effects **MUST** exist only under `tenon.intents.send`. | shipped | `@req-iar-fr-039` |
| `IAR-FR-040` | Any interaction change **MUST** record classification facts, update normative/source inventory, add a pre-acceptance fitness test, delete superseded public paths, search stale surfaces, run relevant verification, and receive independent review in the same vertical slice. | shipped process | `@req-iar-fr-040` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `IAR-NFR-001` | determinism | Two reviewers using the same owner/cardinality/lifetime/reachability facts **MUST** obtain the same first-match classification. | shipped/continuous | `@req-iar-nfr-001` |
| `IAR-NFR-002` | boundedness | Payload/result, schema, projection, mailbox, admission, progress, telemetry, resource, deadline, and retained-idempotency state **MUST** have finite central bounds and explicit overflow. | shipped | `@req-iar-nfr-002` |
| `IAR-NFR-003` | performance | One `IntentDispatcher.send` **MUST** cost at most 700× CPU of the equivalent one-actor-hop typed DIRECT operation under the documented 15-sample test. | shipped | `@req-iar-nfr-003` |
| `IAR-NFR-004` | responsiveness | Filesystem, process, network, schema compilation, plugin execution, and unbounded resource work **MUST NOT** run on `MainActor`; unrelated lanes/providers/UI retain forward progress. | shipped | `@req-iar-nfr-004` |
| `IAR-NFR-005` | security | Principals, envelopes, grants, scopes, effects, provider authority, and confirmation **MUST** be host controlled and resist confused-deputy forwarding. | shipped | `@req-iar-nfr-005` |
| `IAR-NFR-006` | privacy | Telemetry **MUST** record structured identity/timing/outcome while redacting payload/result by default and restricting stack/invalid-result detail to privileged inspection. | shipped | `@req-iar-nfr-006` |
| `IAR-NFR-007` | lifecycle | Queued, started, cancelled, idempotent, leased, draining, and retired work **MUST** each have one explicit terminal/physical ownership transition. | shipped | `@req-iar-nfr-007` |
| `IAR-NFR-008` | compatibility | Same-major schemas **MUST** remain compatible; breaking input/output changes mint a new major and old contracts remain callable during migration. | shipped | `@req-iar-nfr-008` |
| `IAR-NFR-009` | observability | Discovery/denial/provider/generation/trace/queue/outcome explanations **MUST** be structured and attributable across plugin, CLI, agent, and privileged inspector views. | shipped | `@req-iar-nfr-009` |
| `IAR-NFR-010` | verification | Exact inventories, audiences, lanes, adapters, local controls, duplicates, latency, boundaries, lifecycle, policy, and shipped-plugin use **MUST** be mechanically gated. | shipped process | `@req-iar-nfr-010` |
| `IAR-NFR-011` | accessibility | Palette/launcher/keybinding projections and native local controls **MUST** preserve keyboard, pointer, VoiceOver, focus, and outcome parity through their one owning action path. | shipped/continuous | `@req-iar-nfr-011` |
| `IAR-NFR-012` | resilience | Invalid input/output, missing/ambiguous provider, overload, denial, deadline, cancellation, reload, and retirement **MUST** fail explicitly without duplicate effect or unrelated-state loss. | shipped | `@req-iar-nfr-012` |

## 7. Acceptance and architecture

[`interaction-architecture.feature`](interaction-architecture.feature) maps all 52 requirements.
The normative law remains the authority; this PRD packages its product contract and does not weaken
it. Tests span pure classification/inventory source gates, contract/policy/dispatcher/mailbox tests,
host adapter fitness, CLI/plugin projections, latency measurements, and shipped plugin manifests.

```text
built-in SwiftUI ───────────────────────────────► typed application service
plugin / CLI / agent ─► common intent kernel ─► provider adapter ─► same service
palette / launcher / registered keybinding ─► plugin-owned intent ──────────┘
```

Native visual presentation remains owned by PRD-001/002/003/005 and `docs/designs.md`. Domain
ownership follows `docs/domains.md`; architecture classification never replaces the required
source-symbol edge search.

## 8. Delivery matrix, risks, and decisions

| Requirements | Evidence | State |
|---|---|---|
| 001…015 | normative law, interaction and DIRECT inventory gates | shipped/normative |
| 016…028 | `TenonIntentCore`, dispatcher/policy/mailbox/idempotency/schema tests | shipped |
| 029…039 | core catalog, plugin built-ins, palette/keybinding/CLI/agent projections and fitness tests | shipped |
| 040 and NFR set | change protocol, source gates, latency test, lifecycle and shipped-plugin suite | shipped process/continuous |

Risks are DIRECT growth by convenience, commands hidden in events/control plane, duplicate semantic
implementations, generic principals, core actions leaking into palette, adapter policy drift,
cancelled started work releasing capacity early, lane explosion, schema bureaucracy, and performance
gates becoming flaky. The ordered law, exact profiles/inventories, DIRECT length gate, shared typed
services, physical-completion accounting, closed lanes, compiled schemas, and CPU-ratio receipt
mitigate them.

Decisions: six mechanisms are sufficient; control plane is closed, not a seventh mechanism; no
CHANNEL rung; same-owner host code is DIRECT; plugin-private facilities are exactly three; all
finite public operations are canonical intents; provider authority never inherits caller authority;
core audiences are only the two exact profiles; palette/keybindings project plugin-owned contracts;
`terminalWait` alone has concurrency 8; every migration deletes its former public path.

## 9. Verification receipts and change history

| Date | Worktree | Result | Exclusions |
|---|---|---|---|
| 2026-08-07 | documented Apple Silicon debug measurement | intent kernel medians 393.4×…416.8×, worst sample 463.4× under 700× ceiling | release-build p95 remains a separate continuous receipt |
| 2026-08-09 | current dirty tree, documentation audit | law, exact inventories, source/test gates, current launcher/tab/pane additions mapped | no architecture behavior changed in this documentation pass |

Initial canonical PRD created 2026-08-09. A future change to the ordered law requires a concrete
counterexample, ADR-quality trade-off analysis, inventory migration, and enforcement update.
