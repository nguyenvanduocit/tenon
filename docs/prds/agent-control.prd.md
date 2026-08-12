# PRD — Agent-native control and coordination

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-017` |
| Lifecycle | `partial` — `AC-FR-031…036` shipped 2026-08-10; the coordination contracts remain proposed |
| Owner | planned agent-control domain, with agent-lens, intent-bus, terminal-surface, and cli-control adapters |
| Reviewers | product, native UI, accessibility, security, runtime, agent integrations, CLI, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Target release | TBD after provider-lifecycle characterization |
| Related work | [`automations.prd.md`](automations.prd.md), [`agent-lens.prd.md`](agent-lens.prd.md), [`cli-control.prd.md`](cli-control.prd.md), [`terminal.prd.md`](terminal.prd.md), Herdr 0.8.0 source reference |
| Acceptance specification | [`agent-control.feature`](agent-control.feature) |

## 1. Executive summary

### Problem

Tenon can already open a terminal, write a command, wait for command completion, and page
scrollback. `tenon.agents.run` composes those primitives into one visible run-to-result helper,
while Agent Lens privately projects rich Claude and Codex session evidence for a person. These
two capabilities do not yet form a public agent-control contract.

An automation, CLI caller, or another agent cannot ask Tenon which live panes contain supported
agents, address the exact agent incarnation, distinguish working from waiting for input, submit
one prompt and atomically wait for the resulting turn, or fail promptly when the pane occupant
changes. Authors must coordinate terminal bytes and command-finished baselines themselves. That
works for one-shot commands but is too weak for reliable multi-turn agent coordination.

### Proposed outcome

Tenon will expose a provider-neutral agent-control vocabulary over the same canonical intent
path used by plugins, CLI callers, and agent adapters. A caller can inspect a bounded agent
snapshot, give an agent a workspace-local name, start a supported agent in an explicitly
prepared pane, queue or submit a prompt, answer a typed provider interaction, and wait for a
semantic state transition while Tenon pins the exact pane/surface/provider incarnation. The
first release supports Claude and Codex only and makes the ordinary path power-first: observation
does not interrupt, an installed automation can run its declared coordination after one trust
decision, and repeated calls do not repeatedly ask for the same permission.

The feature does not make Tenon a background daemon. Agents continue to run in real PTYs,
topology remains owned by workspace/terminal intents, and Agent Lens remains the full human
evidence surface. A person may deliberately delegate bounded provider questions and approvals
to an installed automation; Tenon's own permission dialog, authority expansion, arbitrary key
injection, and stale-identity retargeting are never delegated.

### Why now

The checked-in Herdr 0.8.0 reference demonstrates that reliable automation comes from three
separate primitives—layout, raw pane, and recognized agent—plus stable identity, semantic
lifecycle state, and an atomic prompt-and-wait operation. Its wait implementation captures an
event baseline before submission, requires observable activity, and refuses pane replacement;
its detection model distinguishes lifecycle-authoritative hooks from screen-derived fallback.

Tenon already has the harder substrate: stable pane/surface identity, bounded intent dispatch,
concurrent terminal waits, guarded PTY input, Claude/Codex hook ingestion, and evidence-aware
Agent Lens state. The missing product boundary is a convenient public adapter over that
substrate: broad enough to finish real unattended workflows, while keeping exact identity and
irreversible authority boundaries explicit.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| Herdr product and automation model | [`references/herdr/README.md`](../../references/herdr/README.md), [`agent-automation.mdx`](../../references/herdr/docs/next/website/src/content/docs/agent-automation.mdx), 2026-08-09 inspection | high | Background runtime, layout/pane/agent separation, JSON IDs, start/prompt/wait/read workflows |
| Herdr public agent schema | [`src/api/schema/agents.rs`](../../references/herdr/src/api/schema/agents.rs) | high | Bounded request and snapshot shapes for start, prompt, wait, read, identity, status, and session reference |
| Herdr atomic wait semantics | [`src/api/wait.rs`](../../references/herdr/src/api/wait.rs), [`src/api/event_hub.rs`](../../references/herdr/src/api/event_hub.rs) | high | Pre-submit event baseline, state version gate, prompt-stalled timeout, identity pinning, close/move/replacement refusal |
| Herdr authority arbitration | [`src/detect/mod.rs`](../../references/herdr/src/detect/mod.rs), [`src/pane/agent_detection.rs`](../../references/herdr/src/pane/agent_detection.rs), [`integrations.mdx`](../../references/herdr/docs/next/website/src/content/docs/integrations.mdx) | high | Hook authority and screen fallback must not compete; unknown state is not completion evidence |
| Herdr continuity model | [`session-state.mdx`](../../references/herdr/docs/next/website/src/content/docs/session-state.mdx) | high | Detach, cold restore, native agent resume, and live handoff are different guarantees; waits/subscriptions do not survive handoff |
| Tenon one-shot agent composition | [`PluginRuntimeBootstrap.swift`](../../Sources/TenonCore/PluginRuntimeBootstrap.swift), [`automations.prd.md`](automations.prd.md) | high | Existing `tenon.agents.run` is caller-local composition over terminal open/write/wait/scrollback, not semantic agent control |
| Tenon semantic evidence and guarded input | [`AgentLensDomain.swift`](../../Sources/TenonApp/AgentLensDomain.swift), [`AgentSessionHooks.swift`](../../Sources/TenonApp/AgentSessionHooks.swift), [`design-agent-lens.md`](../design-agent-lens.md) | high | Claude/Codex lifecycle facts, surface-incarnation binding, evidence authority, bounded input queue, and human-facing statuses exist privately |
| Tenon public interaction law | [`architecture-interaction-boundaries.md`](../architecture-interaction-boundaries.md) | high | Public finite agent operations must be INTENTs; built-in UI stays DIRECT; pane continuity should be an opaque value, not a second resource handle |
| Product request | User request and follow-up, 2026-08-09 | high | Agent-facing automation is strategically important; convenience and delegated power outrank permission ceremony that protects no concrete risk |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| What core problem are we solving? | Reliable semantic coordination of live CLI agents without reducing them to terminal timing and byte heuristics. | Source inspection, 2026-08-09 |
| Who experiences it? | Automation/plugin authors, CLI scripts, and agents coordinating two to five visible agent workstreams; operators supervise the result. | VISION and Herdr comparison |
| How will we know it worked? | Atomic prompt waits never succeed for the wrong occupant, unknown state never masquerades as completion, and a three-agent example coordinates through one canonical contract. | Metrics and acceptance below |
| Which constraints cannot move? | Real PTYs, one typed semantic implementation, canonical intent policy, exact live identity, non-automatable Tenon permission expansion, bounded lifetimes, and Tenon's native visual language. | Interaction law, Agent Lens design, designs.md |
| What remains unknown? | Whether current Claude/Codex hook facts are complete enough to author every required public state without adding a new provider adapter signal. | Phase 0 characterization |

### Assumptions to validate

| ID | Assumption | Validation method | Owner | Due/state |
|---|---|---|---|---|
| `AC-A-001` | Current Claude and Codex integrations can author `working`, `needs_input`, `settled`, and `failed` with explicit confidence. | Record at least 30 real turns per provider, including approval, question, interrupt, failure, and idle return. | agent integrations | blocking discovery |
| `AC-A-002` | A workspace-local human alias layered over an incarnation-bound reference is both script-friendly and occupant-safe. | Prototype CLI/plugin flows, ambiguity/replacement mutations, and five operator interviews. | product/runtime | planned |
| `AC-A-003` | Eight concurrent lifecycle waits cover the intended human-scale fleet without queue starvation. | Stress 8 active waits plus unrelated terminal and workspace intents. | runtime/test | planned |
| `AC-A-004` | A bounded typed interaction envelope—kind, prompt, and offered choices—is sufficient for useful question/approval automation without exposing the transcript or tool ledger. | Build the example coordinator and exercise real Claude/Codex question and approval turns. | product/integrations | planned |

## 3. Users and jobs

### Primary user

The primary user is an automation or plugin author—and often another coding agent—coordinating
several Claude or Codex sessions that remain visible in Tenon. They need machine-readable
identity and state, deterministic waits, and typed failures. Their current workaround is to
open panes, send shell text, poll terminal output, and guess whether the same process is still
there.

### Secondary users and affected actors

- The human operator who chooses once which installed automations may observe, coordinate, or
  answer provider interactions, can revoke that trust, and retains exact re-entry to every pane.
- CLI authors who need the same semantics without a second `tenon-cli agent` protocol.
- Agent integration maintainers who translate provider facts into one normalized state model.
- Plugin authors who need declared installation trust, rather than repeated prompts, while their
  principal, scope, deadline, and cancellation remain in force across every composed action.
- Accessibility users who rely on existing Agent Lens, pane, and attention surfaces rather than
  a separate automation-only UI.

### Jobs to be done

- When several live agents are working, I want a bounded inventory of their semantic state so I
  can decide which one to prompt, wait on, or return to without reading every pane.
- When I delegate a turn, I want prompt submission and completion waiting to be one atomic
  operation so a fast transition cannot be missed.
- When a pane is closed, moved to a new surface incarnation, or taken over by another process, I
  want the pending operation to fail explicitly instead of succeeding against the wrong agent.
- When an agent needs approval or an answer, I want a trusted coordinator to inspect the bounded
  choices and respond structurally, or surface the exact pane when I have not delegated that power.
- When an agent is already working, I want to queue the next bounded turn instead of writing my
  own wait-then-prompt loop.
- When coordination fails, I want the exact pane and typed reason so I can inspect and recover in
  Terminal or Agent Lens.

### Product vocabulary

| Term | Meaning in this PRD | Not to be confused with |
|---|---|---|
| agent | A supported provider process currently controlling a Tenon PTY surface | a model API, plugin runtime, or arbitrary pane process |
| agent snapshot | Bounded public state, identity, workspace-local alias, and current typed interaction envelope | Agent Lens transcript, tool ledger, or evidence ledger |
| agent reference | Opaque, re-presented value bound to pane, surface incarnation, and provider identity | a host resource handle or workspace-local display alias |
| agent alias | Optional human name unique within one workspace and resolved to an exact live reference before control | authority, global identity, or a retargeting fallback |
| interaction reference | Opaque value for one provider-authored pending question or approval | Tenon permission prompt or permission to answer a later interaction |
| settled | The current agent turn has returned to an authoritative ready-for-input state | pane process exit, business success, tests passing, or user having reviewed the result |
| needs input | The provider has authoritative evidence that a question/approval/decision is pending | generic idle text or inferred urgency |
| activity version | Host-owned monotonic state-transition version for one agent incarnation | event sequence shared across all panes |

### Product posture: power first, progressive trust

Tenon interrupts only when an action crosses a concrete authority boundary. The product does
not make users reconfirm unchanged, already-declared behavior merely because it is automated.

| Profile | Included behavior | Default confirmation behavior |
|---|---|---|
| **Observe** | list, get, wait, bounded alias and interaction metadata | no per-call confirmation after ordinary capability/scope eligibility |
| **Coordinate** | start, rename, queue/prompt | one policy decision per declared contract; an installed plugin may receive standing consent from its reviewed manifest, and an attended CLI/agent caller may acquire standing consent |
| **Operate** | answer any provider question or approval through the exact pending interaction and offered choices | `agent.respond.v1` is a separately declared contract with explicit standing trust; once granted, calls do not reprompt |

All profiles still resolve current scope, pin the exact surface incarnation, enforce bounds,
admission, deadlines, cancellation, and telemetry, and fail visibly on ambiguity. Tenon's own
policy dialog, a request to expand scope, secrets disclosure, arbitrary key sequences, and fuzzy
retargeting stay outside delegation. These are reliability and authority boundaries, not
permission ceremony.

## 4. Goals and success measures

### Goals

- `AC-G-001` — Give plugin, CLI, and agent callers one reliable semantic control vocabulary.
- `AC-G-002` — Make prompt-to-settlement race-free and occupant-safe for fast and long turns.
- `AC-G-003` — Make declared automation unattended after one explicit trust decision and reserve
  repeated interruption for concrete authority expansion.
- `AC-G-004` — Keep topology, raw terminal control, semantic agent control, and rich evidence
  separate and composable.

### Success metrics

| ID | Metric | Baseline | Target | Measurement method | Review window |
|---|---|---|---|---|---|
| `AC-M-001` | Wrong-occupant successful waits | no semantic wait exists | 0 across replacement, close, relaunch, and provider-change mutation suite | deterministic integration tests plus installed runs | release gate |
| `AC-M-002` | Unknown state accepted as settled/completed | current callers can infer from terminal output | 0 | contract tests and provider outage runs | release gate |
| `AC-M-003` | Prompt accepted but no lifecycle effect observed | untyped today | typed `agent_prompt_stalled` within 5 seconds | true-provider installed runs | release gate |
| `AC-M-004` | Concurrent coordinator completion | `tenon.agents.run` covers one-shot commands only | three live supported agents can be prompted and awaited concurrently in 30/30 test runs | opt-in example plus true-provider receipt | pilot |
| `AC-M-005` | Event-to-wait settlement latency | TBD | p95 at or below 250 ms for local synthetic provider facts | release-build benchmark on Apple Silicon | pilot |
| `AC-M-006` | Repeated permission interruptions after standing trust | unknown | 0 for unchanged calls inside the same declared contract and authorized scope | installed plugin and attended CLI/agent acceptance runs | release gate |
| `AC-M-007` | Busy-agent coordination requiring caller-side wait loops | every caller must compose wait then prompt | 0 for bounded `whenReady` prompts; host queues and attributes delivery | coordinator and cancellation tests | pilot |

### Guardrail metrics

| ID | Regression to prevent | Limit | Measurement method |
|---|---|---|---|
| `AC-GM-001` | Rich Agent Lens evidence exposed through public snapshots | zero transcript/session paths, message history, tool bodies, evidence anchors, or raw hooks; only the current bounded typed interaction envelope is public | schema and source-inventory fitness tests |
| `AC-GM-002` | Agent waits starving unrelated work | maximum 8 active agent-wait lane requests, while terminal/workspace lanes remain responsive | admission and concurrency tests |
| `AC-GM-003` | Automation escapes its explicit delegation | zero raw logical-key, Tenon-policy-answer, scope-expansion, or stale-interaction paths; provider approval is accepted only through `agent.respond.v1` and exact standing trust | catalog, policy, and mutation tests |
| `AC-GM-004` | Main-thread provider/detection work | zero filesystem, process, hook decoding, or wait polling on MainActor | concurrency assertions and Instruments receipt |

## 5. Scope

### In scope

- A bounded public agent snapshot, workspace-local alias, typed pending-interaction envelope, and
  opaque incarnation-bound reference.
- Provider adapters for Claude and Codex, with explicit state authority/confidence.
- `agent.list.v1`, `agent.get.v1`, `agent.start.v1`, `agent.rename.v1`, `agent.prompt.v1`,
  `agent.respond.v1`, and `agent.wait.v1` canonical core intents for `{plugin, cli, agent}`.
- Starting a supported agent in an already prepared, explicitly scoped empty terminal pane.
- Immediate or bounded `whenReady` prompt delivery, atomic prompt plus optional wait, structured
  response to the exact pending provider interaction, standalone semantic wait, typed
  timeout/stall/replacement failures, and bounded concurrent waits.
- Progressive trust profiles in which reads do not interrupt, installed plugins may run declared
  coordination unattended, and attended CLI/agent callers may acquire standing consent.
- Built-in Swift/SwiftUI calling the same typed agent-control service DIRECT where needed.
- One opt-in example coordinator exercising three visible agents.
- Installed Claude and Codex characterization and end-to-end receipts.

### Non-goals

- Replacing Claude, Codex, or their own agent/session runtimes.
- A background server, detach/reattach process persistence, remote attach, live process handoff,
  or cold native-session resume. Tenon app/process lifecycle remains as specified by PRD-009.
- Screen-text manifests as completion authority in the first release.
- Supporting arbitrary providers before they have authoritative identity and lifecycle adapters.
- Public transcript history, tool bodies, evidence anchors, session paths, or raw hooks; the only
  public Agent Lens-adjacent content is the current bounded typed interaction envelope.
- Raw `agent.send-keys`, answering Tenon's own policy dialog, or expanding authority from an agent
  response. Provider-native questions and approvals are intentionally delegable through the exact
  pending interaction contract.
- A permanent global agent-name registry; v1 aliases are workspace-local convenience metadata.
- A public agent lifecycle event/subscription in the first release.
- A new core palette row, generic app principal, or handwritten CLI agent command API.
- Replacing or silently changing the existing `tenon.agents.run` run-to-result helper.

### Later possibilities

- Provider-owned adapters for additional agents after authority and installed evidence exist.
- Explicit resumable session references and cold restart only after PRD-009 owns the process
  continuity promise.
- A public lifecycle event for high-volume observers if one-shot waits prove insufficient.
- Broader Agent Lens history/tool automation through a separately reviewed, explicit evidence contract.

## 6. User experience

### Entry points

- Plugins call the seven contracts through `tenon.intents.send` after declaring them in
  `intents.uses`.
- CLI callers use `tenon-cli intent list`, `intent describe`, and `intent send`; no domain verb
  enters CLI control-plane framing.
- Agent adapters project the same catalog and send path under the `agent` principal.
- Built-in surfaces use a typed `AgentControlService` DIRECT and mint no app principal.
- No core contract appears directly in the palette. A plugin may provide a user-facing intent
  with presentation metadata and call the agent contracts under its own principal.

### Primary flow

1. The coordinator creates or selects a terminal pane through existing workspace/terminal
   contracts and carries its explicit `paneID` in intent scope.
2. It sends `agent.start.v1` with provider, optional alias, and argument tokens. The start operation changes no
   topology and returns only after the expected provider owns that surface with authoritative
   identity, or returns a typed failure while leaving the pane inspectable.
3. The response includes an opaque `agentRef`, optional workspace-local alias, normalized state,
   `activityVersion`, provider, and pane/workspace/tab identity.
4. The coordinator sends `agent.prompt.v1` with that reference, prompt text, delivery policy,
   and an optional wait clause. If the agent is busy, `whenReady` keeps the finite request pending;
   Tenon captures identity and transition baselines immediately before actual input delivery.
5. The call returns once the same incarnation reaches `settled`, `needs_input`, or `failed`, or
   returns a typed stall, timeout, cancellation, or identity failure.
6. If the agent reaches `needs_input`, the snapshot may carry the current bounded typed interaction.
   A caller with `agent.respond.v1` trust can answer that exact interaction and optionally wait for
   the next state; otherwise the same result is an exact handoff to the person.
7. The coordinator may use `terminal.scrollback.read.v1` for bounded text evidence and existing
   workspace focus/content intents for exact re-entry. Agent Lens remains the human semantic view.

### Existing-agent flow

1. A user starts Claude or Codex manually in a Tenon pane.
2. Once authoritative identity exists, `agent.list.v1` includes its bounded snapshot.
3. A caller can assign or discover a workspace-local alias, resolves it to the returned opaque
   reference, and prompts or waits without taking ownership of the underlying process.

### Alternate and edge flows

- **Already matching:** standalone `agent.wait.v1` returns immediately when the current state is
  requested and no `afterVersion` is supplied. Prompt+wait always requires a post-submit
  transition and cannot succeed from the pre-prompt state.
- **Busy:** default `whenReady` delivery queues a bounded prompt and captures its causal baseline
  only when that prompt is actually delivered. `immediate` delivery remains available and returns
  `agent_busy` without writing.
- **Cancellation:** caller cancellation settles the finite intent and removes its waiter or queued
  prompt; it does not kill the agent or close the pane.
- **Unknown authority:** state is `unknown`; start/get may report it, but prompt and waits for
  `settled` return explicit insufficient-authority failure until semantic authority is available.
- **Pane replacement/closure:** the pending operation returns `agent_not_running` or
  `agent_identity_changed` and never retargets by pane position, provider label, or recent cwd.
- **Start timeout:** the pane remains visible with the submitted command/output and exact failure;
  the caller may inspect or close it through existing contracts.
- **Needs input:** authorized observation receives the current bounded interaction kind, prompt,
  and offered choices. A trusted caller may answer by exact `interactionRef`; a stale or replaced
  interaction never retargets. Without response trust, the person uses the provider UI or Agent Lens.
- **Trust:** installed plugins use reviewed declared grants without repeated prompts. CLI and agent
  callers begin without seeded control trust but may acquire standing consent during an attended
  call. Read-only observation remains usable headlessly.
- **App shutdown:** active requests settle with a typed host-unavailable/cancelled result; no wait
  or reference is claimed to survive relaunch.

### Accessibility and input parity

The first delivery adds no standalone native screen. Existing Agent Lens, pane chrome,
attention, notifications, and focus actions remain the human surfaces and must keep keyboard,
pointer, and VoiceOver parity under their owning PRDs. Any future agent inventory UI must reuse
Launcher/Palette row density, `TenonTheme` semantic tokens, native controls, and non-color status
from [`designs.md`](../designs.md); Herdr informs workflow only, never Tenon pixels.

## 7. Requirements

### Functional requirements

| ID | Requirement | Priority | Delivery | Acceptance reference |
|---|---|---|---|---|
| `AC-FR-001` | Agent coordination **MUST** keep workspace topology, raw terminal control, semantic agent control, and rich evidence as separate composable product primitives. | must | planned | `@req-ac-fr-001` |
| `AC-FR-002` | Built-in UI and all public adapters **MUST** call one typed agent-control semantic implementation; provider or adapter code **MUST NOT** reimplement state rules. | must | planned | `@req-ac-fr-002` |
| `AC-FR-003` | A public agent snapshot **MUST** contain opaque reference, optional workspace-local alias, provider, normalized state, activity version, pane/workspace/tab IDs, focus/seen metadata when available, update time, authority confidence, and at most one current bounded typed interaction envelope. | must | planned | `@req-ac-fr-003` |
| `AC-FR-004` | Public snapshots **MUST NOT** expose transcript/session paths, message history, tool inputs/results, evidence anchors, secrets, or raw hook payloads; a current interaction envelope **MAY** expose its opaque reference, kind, bounded prompt, offered choice IDs/labels, and freeform-allowed flag. | must | planned | `@req-ac-fr-004` |
| `AC-FR-005` | `agentRef` **MUST** be an opaque value bound to pane ID, host-minted surface incarnation, and provider identity; dropping it **MUST** own no host lifetime. | must | planned | `@req-ac-fr-005` |
| `AC-FR-006` | Re-presenting a stale, malformed, wrong-principal, or wrong-scope reference **MUST** fail typed and **MUST NOT** fall back to provider name, cwd, focus, alias, or recent pane order; alias lookup **MUST** resolve uniquely before execution pins the exact live reference. | must | planned | `@req-ac-fr-006` |
| `AC-FR-007` | `agent.list.v1` and `agent.get.v1` **MUST** return policy-filtered bounded snapshots and preserve explicit unknown/insufficient authority. | must | planned | `@req-ac-fr-007` |
| `AC-FR-008` | Normalized states **MUST** be exactly `starting`, `working`, `needs_input`, `settled`, `failed`, and `unknown`; every transition **MUST** advance a monotonic activity version for that incarnation. | must | planned | `@req-ac-fr-008` |
| `AC-FR-009` | Provider lifecycle hooks **MUST** outrank weaker observation only while their exact pane/surface/provider binding is active; competing authorities **MUST NOT** publish state concurrently. | must | planned | `@req-ac-fr-009` |
| `AC-FR-010` | `unknown` **MUST NOT** satisfy a wait for `settled`, imply successful completion, or authorize prompt delivery. | must | planned | `@req-ac-fr-010` |
| `AC-FR-011` | `agent.start.v1` **MUST** target an explicit existing pane through intent scope, **MUST NOT** create/move/split/focus topology, and **MUST** refuse a pane that is not an available interactive shell. | must | planned | `@req-ac-fr-011` |
| `AC-FR-012` | Start **MUST** accept only the exact supported provider inventory and an array of bounded argument tokens; control characters or unsafe shell encoding **MUST** fail before any input is written. | must | planned | `@req-ac-fr-012` |
| `AC-FR-013` | Start **MUST** return success only after the expected provider owns the same surface and has authoritative identity; timeout or replacement **MUST** leave the pane visible and return typed failure. | must | planned | `@req-ac-fr-013` |
| `AC-FR-014` | `agent.prompt.v1` **MUST** validate the reference and live foreground identity immediately before each input frame, sanitize bracketed-paste termination, and serialize text plus commit through the existing guarded input service. | must | planned | `@req-ac-fr-014` |
| `AC-FR-015` | Prompt **MUST** reject an empty/oversized body, unknown authority, or a pending start before writing bytes; a working target **MUST** either fail immediately when `delivery=immediate` or enter a bounded FIFO when `delivery=whenReady`, which is the default. | must | planned | `@req-ac-fr-015` |
| `AC-FR-016` | Prompt with wait **MUST** capture event sequence, identity, and activity version before submission, then require a post-submit transition before any settled state can satisfy the call. | must | planned | `@req-ac-fr-016` |
| `AC-FR-017` | A prompt that produces no observed transition within 5 seconds **MUST** return `agent_prompt_stalled`; a shorter caller deadline **MUST** return the ordinary deadline error. | must | planned | `@req-ac-fr-017` |
| `AC-FR-018` | Prompt+wait **MUST** default to `settled`, `needs_input`, or `failed`; explicit waits **MAY** select any normalized state except that `unknown` never counts as successful completion; queued prompt baselines **MUST** be captured at actual delivery, not enqueue time. | must | planned | `@req-ac-fr-018` |
| `AC-FR-019` | `agent.wait.v1` **MUST** be one finite request/reply with explicit timeout, optional `afterVersion`, exact identity pinning, and typed close/replacement/cancellation failure. | must | planned | `@req-ac-fr-019` |
| `AC-FR-020` | Wait setup **MUST** close the snapshot/subscription race: a transition occurring between baseline capture and waiter registration **MUST** still be observed once. | must | planned | `@req-ac-fr-020` |
| `AC-FR-021` | Public agent control **MUST NOT** duplicate terminal read, focus, close, or workspace placement; callers **MUST** use the existing canonical intents for those operations. | must | planned | `@req-ac-fr-021` |
| `AC-FR-022` | The first release **MUST NOT** expose logical-key sending, Tenon-policy answering, transcript/tool evidence, scope expansion, or a public lifecycle subscription/event; provider questions and approvals **MAY** be answered only through `agent.respond.v1` against the exact pending interaction. | must | planned | `@req-ac-fr-022` |
| `AC-FR-023` | The seven contracts **MUST** use the same catalog, schema, policy, declared-use, capability, consent, scope, deadline, admission, cancellation, and telemetry path for plugin, CLI, and agent principals. | must | planned | `@req-ac-fr-023` |
| `AC-FR-024` | Existing `tenon.agents.run` **MUST** retain its current run-to-result behavior and caller authority; adoption of semantic agent control **MUST NOT** silently change its contract. | must | planned | `@req-ac-fr-024` |
| `AC-FR-025` | An opt-in installed example **MUST** prepare three visible panes, assign aliases, start or discover supported agents, queue/prompt and wait concurrently, optionally answer one declared interaction, retain each exact reference, and publish a bounded aggregate under standing installation trust. | should | planned | `@req-ac-fr-025` |
| `AC-FR-026` | `agent.rename.v1` **MUST** set or clear a bounded workspace-local alias for the exact live incarnation; comparison **MUST** be normalized and collision **MUST** return `agent_alias_conflict` without changing either agent. | must | planned | `@req-ac-fr-026` |
| `AC-FR-027` | Alias lookup **MUST** be policy-filtered and unique within the requested workspace, return an exact `agentRef`, grant no authority, and never retarget a queued or active operation after resolution. | must | planned | `@req-ac-fr-027` |
| `AC-FR-028` | `agent.respond.v1` **MUST** accept the exact live `agentRef` and `interactionRef`, one offered choice ID or bounded freeform response permitted by that interaction, and an optional atomic wait; stale, replaced, ambiguous, or non-offered responses **MUST** write nothing. | must | planned | `@req-ac-fr-028` |
| `AC-FR-029` | Observe contracts (`list/get/wait`) **MUST NOT** request per-call confirmation after capability and scope eligibility; Coordinate contracts (`start/rename/prompt`) **MUST** consume existing contract standing consent when present. | must | planned | `@req-ac-fr-029` |
| `AC-FR-030` | Any provider-interaction response **MUST** require separately declared `agent.respond.v1` standing trust; installed plugins **MAY** receive it through reviewed installation, attended CLI/agent callers **MAY** acquire it explicitly, and unchanged authorized calls **MUST NOT** reprompt. No standing consent may answer Tenon's own policy prompt or expand scope. | must | planned | `@req-ac-fr-030` |
| `AC-FR-031` | `agent.inventory.v1` **MUST** return only the supported agents this machine actually has, each with a stable id, a human label, the argument tokens this person habitually passes it, and an optional short description of that habit. | must | shipped | `@req-ac-fr-031` |
| `AC-FR-032` | The inventory **MUST NOT** expose an executable path, raw shell history, or any command line that was not composed for the caller's own request. | must | shipped | `@req-ac-fr-032` |
| `AC-FR-033` | `agent.command.v1` **MUST** compose one command line for a named installed agent, starting nothing and mutating nothing, and **MUST** fail typed with `agent-unavailable` when the requested agent is unknown or absent. | must | shipped | `@req-ac-fr-033` |
| `AC-FR-034` | Composition **MUST** carry this person's habitual argument tokens ahead of any provider subcommand unless the caller explicitly opts out, and **MUST** quote every token so a prompt, path, or identifier cannot become shell syntax; a session identifier that is not one **MUST** be refused before composition. | must | shipped | `@req-ac-fr-034` |
| `AC-FR-035` | A session **MUST** resume through its own provider's spelling when the requested agent recorded it, and **MUST** otherwise be handed to the requested agent as a prompt naming that session's transcript path and its recording agent; a cross-agent request with no transcript path **MUST** fail typed with `agent-handoff-unresolved` rather than starting an agent with no context. | must | shipped | `@req-ac-fr-035` |
| `AC-FR-036` | One composition **MUST** produce every agent command line Tenon runs: built-in UI calls it DIRECT and every public caller reaches it through `agent.command.v1`; no plugin may assemble an agent command line or shell quoting of its own. | must | shipped | `@req-ac-fr-036` |
| `AC-FR-037` | An intent that originates inside a pane running an agent **MUST** carry a principal of kind `agent`, minted by the host from the pane's own identity. It **MUST NOT** borrow the human's `cli:local-user`. | must | shipped | `@req-ac-fr-037`; `CLICommandExecutor.callerPrincipal`, `AppIntentRuntime.agentPrincipal(forPane:)`, `AgentCallerAdmission.candidate/admit`, `AgentPaneOccupancyReader.candidates`; `AgentPrincipalMintTests`, `AgentCallerAdmissionTests`, `CLISocketServerTests.testTheHandlerReceivesTheKernelsPeerProcessIDForTheConnection` |
| `AC-FR-038` | `agent.ask.v1` **MUST** let a running agent declare a question in its own words with offered choices, evidence anchors, and a caller-set deadline bounded by the host, block until answered or expired, and return a typed value rather than keystrokes. | must | proposed | `@req-ac-fr-038` |
| `AC-FR-039` | A declared question **MUST** be recorded against the pane, not the asking process, so it survives context compaction, provider timeout, and the death of the agent that asked. | must | proposed | `@req-ac-fr-039` |
| `AC-FR-040` | A question **MAY** be addressed to the human or to another agent principal; the host **MUST** route and record both identically and **MUST NOT** schedule, queue, or place any work as a result. | must | proposed | `@req-ac-fr-040` |
| `AC-FR-041` | State an agent declares about itself — including `needsHuman` — **MUST** outrank state Tenon infers from the screen, and inferred state **MUST** report itself as inference. | must | proposed | `@req-ac-fr-041` |
| `AC-FR-042` | An agent principal **MUST** be able to read a bounded snapshot of its peers — pane, declared status, and last declared claim — without reading their transcripts. | must | proposed | `@req-ac-fr-042` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `AC-NFR-001` | boundedness | List snapshots **MUST** contain at most 32 agents; aliases at most 64 Unicode scalars; interaction prompt/response at most 8 KiB; prompt text at most 32 KiB; start arguments at most 64 tokens/8 KiB total; each agent queue at most 8 items; start timeout 3…300 seconds; prompt/respond/wait timeout at most 10 minutes. | planned | `@req-ac-nfr-001` |
| `AC-NFR-002` | concurrency | Agent wait-like work **MUST** have a distinct bounded lane with at most 8 active requests; immediate list/get/rename work **MUST** use a separate serial lane; global/per-principal admission remains authoritative. | planned | `@req-ac-nfr-002` |
| `AC-NFR-003` | responsiveness | Local synthetic provider fact to matching wait settlement **MUST** be p95 ≤250 ms, and agent work **MUST NOT** block MainActor or unrelated lanes. | planned | `@req-ac-nfr-003` |
| `AC-NFR-004` | trust/privacy | Public results **MUST** expose only the allowlisted current interaction envelope while telemetry redacts prompt/response content; read/control authority **MUST** bind to existing terminal capabilities, and standing consent **MUST** remove repeated ceremony without bypassing scope or identity checks. | planned | `@req-ac-nfr-004` |
| `AC-NFR-005` | lifecycle | Every start/rename/prompt/respond/wait **MUST** settle exactly once on success, timeout, cancellation, app shutdown, pane close, surface replacement, provider identity change, or pending-interaction replacement; no queue item or waiter survives app relaunch. | planned | `@req-ac-nfr-005` |
| `AC-NFR-006` | architecture | Implementation **MUST** update the normative/source intent inventories, exact audience/lane maps, architecture fitness tests, and stale-surface deletion in one reviewed vertical slice. | planned | `@req-ac-nfr-006` |
| `AC-NFR-007` | compatibility | Existing terminal intents, CLI framing, Agent Lens behavior, and `tenon.agents.run` **MUST** remain source-compatible; unsupported or older integrations degrade to `unknown`. | planned | `@req-ac-nfr-007` |
| `AC-NFR-008` | design/accessibility | Any host-native state projection **MUST** reuse TenonTheme, Launcher/Palette density, non-color status, keyboard focus, and VoiceOver labels; no feature-local tokens are allowed. | planned | `@req-ac-nfr-008` |
| `AC-NFR-009` | verification | Headless contract/mutation proof **MUST** be complemented by installed Claude and Codex receipts covering fast turn, queued turn, question response, delegated approval, interrupt, replacement, standing consent, and three-agent concurrency. | planned | `@req-ac-nfr-009` |
| `AC-NFR-010` | portability | The declared channel **MUST** be the only first-class source of an agent's questions and status. Provider-specific extraction (today `ClaudeToolFacts`) **MAY** remain as labelled inference of lower authority, and **MUST NOT** be extended to a new provider to add a capability. | must | proposed | `@req-ac-nfr-010` |

## 8. Acceptance specification

[`agent-control.feature`](agent-control.feature) maps all 45 requirements. Gherkin examples
exercise observable behavior; source symbols and test names remain in the delivery matrix.

| Requirements | Feature rule | Automation seam | State |
|---|---|---|---|
| `AC-FR-031…036` | One place knows how this person runs an agent | pure composer, provider over an injected detector, shipped-plugin runtimes | shipped |
| `AC-FR-001…010`, `AC-NFR-004` | Bounded snapshots preserve identity and authority | pure service/schema, provider fixtures, policy integration | draft |
| `AC-FR-011…013`, `AC-NFR-001` | Start controls an occupant, never topology | hosted SurfacePool, shell/provider integration | draft |
| `AC-FR-014…020`, `AC-NFR-002/003/005` | Prompt and waits are atomic and finite | event-journal race tests, input queue, mailbox tests | draft |
| `AC-FR-021…024`, `AC-FR-026…030`, `AC-NFR-004/006/007` | One public vocabulary adds progressive trust, aliases, and structured response without changing ownership | catalog/policy/fitness/CLI/plugin adapter tests | draft |
| `AC-FR-025`, `AC-NFR-008/009` | A visible trusted fleet proves the product boundary | opt-in installed example, hosted app, installed providers | manual/red |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Semantic owner/caller | Classification | Why this rung applies | Public inventory change? |
|---|---|---|---|---|
| Provider/session/lifecycle fact arrives | provider adapter → host | EVENT | A fact already happened; publisher receives no domain reply | no public event; extend host-private inventory evidence only if needed |
| Built-in Agent Lens/attention reads state or submits a human gesture | TenonApp → typed service | DIRECT | Same semantic owner, no public adapter or independent lifetime | no app principal; add/enlarge DIRECT inventory only with required justification |
| `agent.inventory.v1`, `agent.command.v1` | plugin/CLI/agent → host | INTENT (shipped) | Two finite replies over host-owned knowledge — what is installed, and the line that would run it. Neither starts anything, so neither owns a lifetime | shipped: two core intents, programmatic audience, `agentImmediate` lane, `terminal.write` binding |
| Built-in Launcher composes the same line | TenonApp → `AgentLaunchComposer` | DIRECT (shipped) | Same semantic owner as the composition; one implementation, reached two ways | no second public path; `AgentLaunchSuggestion.commandLine` delegates |
| `agent.list.v1`, `agent.get.v1` | plugin/CLI/agent → host | INTENT | One bounded finite reply across a public principal boundary | add two core intents, programmatic audience, `agentImmediate` lane |
| `agent.start.v1` | plugin/CLI/agent → host | INTENT | One finite start/readiness result; pane process remains separately owned by terminal surface | add core intent, programmatic audience, `agentWait` lane |
| `agent.rename.v1` | plugin/CLI/agent → host | INTENT | One finite metadata mutation across a public principal boundary | add core intent, programmatic audience, `agentImmediate` lane |
| `agent.prompt.v1` | plugin/CLI/agent → host | INTENT | One finite delivered-or-settled result even when bounded queueing/waiting is asynchronous | add core intent, programmatic audience, `agentWait` lane |
| `agent.respond.v1` | plugin/CLI/agent → host | INTENT | One finite response to an exact provider interaction, optionally ending at a later semantic state | add core intent, programmatic audience, `agentWait` lane |
| `agent.wait.v1` | plugin/CLI/agent → host | INTENT | One terminal result with deadline; no handle remains after reply | add core intent, programmatic audience, `agentWait` lane |
| `agentRef` | host → caller → host | pure value carried by INTENT | Dropping it leaks nothing; re-presentation proves continuity like a cursor | no resource/control-plane operation |
| Read transcript, focus/close pane, place topology | existing public principals → host | existing INTENT | Existing terminal/workspace contracts already own these finite operations | no duplicate agent contracts |

Two of the additions have shipped (T-104) and the rest remain planned:

```text
agent.inventory.v1   shipped
agent.command.v1     shipped
```

| Contract | Required scope | Input | One terminal result |
|---|---|---|---|
| `agent.inventory.v1` | none | `{}` | `{ agents: [{ id, label, arguments, habit }] }` |
| `agent.command.v1` | none | `{ agent, prompt?, session?: { agent, sessionID, transcriptPath? }, includeUserOptions? }` | `{ agent, commandLine, arguments, handoff }` |

Their domain errors are `dev.tenon.core.agent-unavailable` and
`dev.tenon.core.agent-handoff-unresolved`; a malformed session identifier or a control
character in any token is refused as kernel `invalidInput` before composition.

The planned canonical core intent addition is exact:

```text
agent.list.v1
agent.get.v1
agent.start.v1
agent.rename.v1
agent.prompt.v1
agent.respond.v1
agent.wait.v1
```

The v1 contract shape is intentionally coherent rather than artificially minimal. Workspace,
tab, and pane designation stays in `options.scope`; those IDs are never copied into input as
authority. Output snapshots repeat resolved IDs only so a caller can log and recover precisely.

| Contract | Required scope | Input | One terminal result |
|---|---|---|---|
| `agent.list.v1` | `workspaceID` | `{ alias? }` | `{ agents: AgentSnapshot[], truncated: Bool }` |
| `agent.get.v1` | `paneID` | `{}` | `{ agent: AgentSnapshot }` |
| `agent.start.v1` | `paneID` | `{ provider, alias?, arguments?, timeoutMs? }` | `{ agent: AgentSnapshot }` after authoritative readiness |
| `agent.rename.v1` | `paneID` | `{ agentRef, alias? }` | `{ agent: AgentSnapshot }` after set/clear |
| `agent.prompt.v1` | `paneID` | `{ agentRef, text, delivery?: immediate\|whenReady, wait?: { until?, timeoutMs? } }` | `{ agent: AgentSnapshot, prompted: true }` after actual delivery or requested settlement |
| `agent.respond.v1` | `paneID` | `{ agentRef, interactionRef, choiceID? xor text?, wait?: { until?, timeoutMs? } }` | `{ agent: AgentSnapshot, responded: true }` after exact response or requested settlement |
| `agent.wait.v1` | `paneID` | `{ agentRef, until?, afterVersion?, timeoutMs }` | `{ agent: AgentSnapshot }` |

`AgentSnapshot` contains only the allowlisted fields from FR-003/004. Its optional
`pendingInteraction` is one current envelope with `interactionRef`, kind, bounded prompt,
offered choice IDs/labels, and whether bounded freeform is accepted; it is not transcript history.
`authority` is an enum, not a prose confidence score, and must distinguish at least authoritative
provider lifecycle from insufficient authority. `truncated` is mandatory on list so the 32-entry
bound cannot be mistaken for completeness.

The domain error inventory is also finite: `agent_not_found`, `agent_identity_changed`,
`agent_authority_insufficient`, `agent_busy`, `agent_not_ready`, `agent_pane_busy`,
`unsupported_agent_provider`, `invalid_agent_argument`, `invalid_agent_prompt`,
`invalid_agent_response`, `agent_alias_conflict`, `agent_interaction_not_found`,
`agent_interaction_changed`, `agent_start_timeout`, and `agent_prompt_stalled`, plus the kernel's
existing policy, scope, deadline, cancellation, admission, provider, and host-unavailable errors.
An implementation may refine a message, but must not route these failures through terminal text
parsing.

The planned execution-lane addition is also exact: `agentImmediate` is serial and owns
list/get/rename; `agentWait` has concurrency 8 and owns start/prompt/respond/wait. The
implementation change must update
`docs/architecture-interaction-boundaries.md`, `CoreIntentName`, audience and lane switches,
catalog definitions, provider registration, capability bindings, source inventories, and fitness
tests together. It may not weaken a test in isolation.

### Native design-system constraints

No new native surface is required for the first vertical slice. State appearing in existing
Agent Lens, attention, pane header, notification, Launcher, or Palette surfaces must use their
current anatomy and `TenonTheme`. A later inventory screen must first define a compact density
budget from Launcher/Palette rather than copy Herdr's TUI rows or tokens.

### Domain and ownership map

| Product domain | Existing owner/source | Expected change | Retrieval/tests |
|---|---|---|---|
| planned `agent-control` | not yet declared; first source addition must add it to `docs/domains.md` with Excludes | typed normalized state, aliases, interaction envelopes, opaque references, finite start/rename/prompt/respond/wait semantics | retrieve starting set by new tag, then search every touched symbol edge |
| `agent-lens` | Agent Lens domain, hook server, registry, reducer, input queue | expose normalized lifecycle plus one bounded current interaction envelope; keep history, tools, and evidence private | AgentLens/provider fixtures and boundary tests |
| `terminal-surface` | SurfacePool and terminal provider | foreground identity, guarded input, surface incarnation, available-shell check | hosted surface/provider tests |
| `intent-bus` | CoreIntentCatalog and dispatcher | seven contracts, two lanes, progressive confirmation policy, capability/telemetry | catalog, mailbox, fitness, latency tests |
| `cli-control` | existing socket and intent action parser | no new control vocabulary; catalog projection only | end-to-end intent list/describe/send tests |
| `automation` | existing scheduler and `tenon.agents.run` | opt-in example consumer; no scheduler semantic change | example and automation integration tests |

The implementation must read `docs/domains.md` again at edit time. A new source file may not use
`agent-control` until that domain is declared in the same change, and tag retrieval must always
be followed by symbol-edge search.

### Data, resource, and lifecycle model

- `AgentControlService` owns a bounded map from `(paneID, surfaceToken)` to normalized public
  state, activity version, provider identity, and authority confidence. It owns no PTY.
- `SurfacePool` continues to own the terminal process/resource; pane close or a new materialized
  surface invalidates the old reference.
- `agentRef` is an authenticated/opaque value, not a handle. It can cross hot reload and be
  persisted by a caller, but expiration is proved only by a typed refusal when re-presented.
- A workspace-local alias is metadata on the currently bound agent entry. Lookup can discover a
  reference but cannot authorize it, and a resolved operation never follows a later alias change.
- Each queued prompt retains its original principal, scope, deadline, cancellation, and content
  bound. Delivery re-runs authorization and identity checks, captures the causal baseline at that
  moment, and removes the item exactly once.
- Each interaction reference is valid only for the current pending provider interaction on the
  exact incarnation. A provider transition or replacement invalidates it before input.
- Each wait captures the current global event sequence and target activity version, then
  registers against the exact incarnation. Its lifetime ends at one reply, cancellation,
  timeout, app shutdown, or identity loss.
- The internal event journal is bounded; setup must snapshot before subscription and replay the
  setup window so overflow/race cannot produce a false success. Overflow fails visibly.
- State entries are removed when the surface is released; hidden tabs and workspace navigation do
  not change identity or cancel the agent.
- No start/prompt/respond/wait or queued delivery is restored after app relaunch. Restored layout remains PRD-001/009 state;
  a restored pane without a live authoritative provider is absent or `unknown`.

### Trust and privacy

- Callers remain `plugin`, `cli`, or `agent`; no `core` or generic app authority is minted.
- `agent.list/get/wait` are Observe operations: they require existing read capability and scope
  eligibility but no per-call confirmation.
- `agent.start/rename/prompt/respond` require existing terminal-write/process authority appropriate to their
  typed provider adapter; the contract grants no broader permission than its underlying service.
- Installed plugins may consume reviewed standing consent for their declared Coordinate/Operate
  contracts. CLI and agent principals receive no seeded control consent, but an attended request
  may acquire existing caller/contract standing consent. Once present, unchanged calls do not
  reprompt; policy, capability, scope, admission, deadline, cancellation, and telemetry still run.
- The opaque reference is a designation, never authority. Policy resolves and authorizes the
  current pane for every invocation.
- Prompt bodies are content, not shell syntax. Start arguments remain an array and are encoded by
  the host for the user's shell; they are never joined by the caller.
- Public schemas exclude transcript paths, identifying session IDs, message/tool history,
  evidence anchors, and raw hook documents. The current bounded interaction prompt/choices are
  intentionally public to authorized callers; telemetry excludes that content and all responses.
- `agent.respond.v1` may answer only the exact current provider interaction using its offered
  choice or allowed bounded text. It cannot answer Tenon's intent-policy UI, manufacture standing
  consent, press arbitrary keys, or broaden the caller's scope.

### Compatibility

- macOS and installed Tenon app requirements remain unchanged.
- Initial providers are exactly Claude and Codex; unsupported providers do not borrow a label or
  screen heuristic and remain ordinary terminal processes.
- Older/missing provider hooks yield explicit `unknown`/insufficient-authority behavior.
- Existing public names and behavior remain unchanged. The seven new names are versioned from
  their first release and cannot be renamed without normal contract migration.
- CLI protocol framing does not change unless the catalog projection itself requires a wire
  version update; domain work remains `intent send`.

## 10. Delivery plan

### Requirement delivery matrix

| Requirements | State | Implementation/source | Test/evidence | Remaining gap |
|---|---|---|---|---|
| `AC-FR-001…010` | planned | new typed service; adapters over AgentSessionRegistry/Agent Lens facts | provider characterization, state reducer/schema tests | authority completeness unknown |
| `AC-FR-011…013` | planned | SurfacePool/terminal provider adapter | available-shell, quoting, process identity, installed starts | no implementation |
| `AC-FR-014…020` | planned | guarded input service plus bounded internal journal/waiter | race, stall, replacement, cancellation, fast-turn mutations | no implementation |
| `AC-FR-021…024`, `AC-FR-026…030` | planned | CoreIntentCatalog/provider registrations, policy profiles, alias/interaction adapters | fitness/catalog/consent/CLI/plugin compatibility | architecture inventory and permission review change required |
| `AC-FR-025` | planned | `examples/agent-coordinator` or reviewed successor | headless + installed three-agent receipt | validate provider cost/time |
| `AC-NFR-001…009` | planned | bounds, lanes, redaction, lifecycle, UI reuse | unit/integration/performance/Instruments/manual receipts | no implementation |
| `AC-FR-031…036` | shipped | `AgentLaunchComposer` (`Sources/TenonApp/AgentLaunchCommand.swift`), `AgentIntentProvider`, the `agentInventory`/`agentCommand` rows in `CoreIntentCatalog`, `AgentLaunchSuggestion.commandLine`, and the two shipped plugins that call them | `AgentLaunchCommandTests`, `AgentIntentProviderTests`, `CoreIntentCatalogTests`, `InteractionBoundaryFitnessTests`, `KanbanPluginTests`, `WorkspaceScopedViewStateTests` | no CLI-audience receipt against a real machine; the handoff prompt is unproven against a live agent on the other side |

### Phases

| Phase | User-visible outcome | Included requirements | Exit criteria | Rollback/fallback |
|---|---|---|---|---|
| `0 — authority characterization` | Honest go/no-go for Claude and Codex state | AC-A-001…004 | 30-turn/provider evidence matrix; no unresolved authority collision; exact public snapshot approved | keep current terminal and Agent Lens paths; stop feature if settled/needs-input cannot be authoritative |
| `1 — observe, name, and wait` | Callers can list/get exact agents, use aliases, and wait without permission ceremony | FR-001…010, FR-019/020/023, FR-026/027/029, NFR-001…007 | catalog/fitness green, alias/replacement mutations green, headless read/wait receipts | feature-flag provider off; callers retain terminal intents |
| `2 — coordinate and respond` | Trusted callers can start, queue/prompt, answer a typed interaction, and atomically await the next state | FR-011…018, FR-021/022/024, FR-028…030, NFR-001…009 | true-provider fast/queue/stall/question/approval/interrupt runs green; standing consent does not reprompt | disable control contracts while observe contracts remain, or remove whole unreleased slice |
| `3 — trusted fleet example` | One opt-in three-agent coordinator proves unattended composition | FR-025 | 30/30 runs, bounded aggregate, exact interaction response, installed trust review | keep example out of bundled inventory |

### Migration and rollout

All seven contracts ship behind one internal availability gate until Claude and Codex receipts
pass. Catalog discovery must report unavailable providers honestly rather than advertising a
contract that will infer state. No persisted migration is required because references are opaque
and incarnation-scoped. Diagnostics count start/prompt/respond/wait outcomes, queue latency,
consent reuse, and state-authority class,
never prompt/evidence content. Roll back by removing the unreleased catalog slice and provider
registration together; terminal intents, `tenon.agents.run`, and Agent Lens remain functional.

## 11. Dependencies, risks, and mitigations

### Dependencies

| Dependency | Owner | Needed by | Failure/fallback |
|---|---|---|---|
| Claude/Codex authoritative lifecycle and interaction facts | Agent Lens/provider adapters | phases 0–3 | expose `unknown`; do not ship prompt/wait/respond for that provider |
| Stable surface incarnation and foreground identity | terminal-surface | start/prompt/respond/wait | typed identity failure; pane remains inspectable |
| Canonical intent catalog/policy/admission | intent-bus | all public operations | no handwritten adapter; feature does not ship |
| Guarded Agent Lens input service | agent-lens/terminal-surface | prompt/respond | refuse public input until shared service is available |
| Existing terminal scrollback/focus/close intents | terminal/workspace providers | evidence and recovery | Terminal/Agent Lens manual recovery remains |

### Risks

| ID | Risk | Likelihood | Impact | Mitigation | Trigger/owner |
|---|---|---|---|---|---|
| `AC-R-001` | A provider hook misses a transition and false-settles a turn | medium | high | phase-0 authority matrix; unknown over inference; installed adversarial runs | any unexplained idle/settled transition; integrations |
| `AC-R-002` | A stale reference controls a new pane occupant | low after design | critical | surface token + provider binding + policy re-resolution on every call | replacement mutation succeeds; runtime/security |
| `AC-R-003` | Agent contracts duplicate terminal/workspace APIs | medium | medium | exact seven-intent inventory; reuse read/focus/close/topology contracts | new proposed duplicate verb; architecture reviewer |
| `AC-R-004` | Waits or queued prompts exhaust admission or block unrelated operations | medium | high | separate bounded lane, max 8 active requests and 8 queued items per agent, global/principal caps, responsiveness tests | queue latency/timeout growth; intent-bus |
| `AC-R-005` | Delegated provider approval is mistaken for authority to answer Tenon's own policy or a later interaction | medium | critical | separate exact interaction reference, declared standing trust, no keys, policy/scope re-check, replacement mutations | any cross-interaction, policy-dialog, or scope-expansion success; security/runtime |
| `AC-R-006` | Public interaction envelopes leak more Agent Lens evidence than intended | medium | high | one current bounded envelope, capability/scope filter, redacted telemetry, negative schema tests | snapshot/history key drift; privacy reviewer |
| `AC-R-007` | Herdr's background-runtime promise is accidentally implied | medium | medium | explicit non-goal and app-shutdown failure semantics | copy/UX claims persistence; product reviewer |
| `AC-R-008` | Existing `tenon.agents.run` becomes ambiguous | medium | medium | preserve contract; document one-shot command composition versus live semantic control | compatibility test change; automation owner |

## 12. Open questions and decisions

### Open questions

| ID | Question | Why it matters | Owner | Due/blocking state |
|---|---|---|---|---|
| `AC-Q-001` | Can current Claude and Codex facts author every normalized state after interrupts, approval cancellation, and nested/subagent activity? | Blocks FR-008…020 and provider availability. | integrations | phase 0 / blocking |
| `AC-Q-002` | Should `agentRef` be a signed opaque string or an opaque object whose fields remain non-authoritative? | Affects schema evolution, logs, and caller ergonomics. | runtime/security | before phase 1 |
| `AC-Q-003` | Is `failed` a provider lifecycle state or only a typed terminal outcome attached to the latest turn? | Prevents conflating process failure, tool failure, and business failure. | product/Agent Lens | phase 0 |
| `AC-Q-004` | Does starting an agent require native session binding, foreground-process proof, or both before success? | Changes start latency and missing-hook behavior. | integrations/terminal | before phase 2 |
| `AC-Q-005` | Is p95 ≤250 ms the right event-to-wait target on supported hardware? | Converts responsiveness from aspiration to release budget. | performance | phase 1 benchmark |
| `AC-Q-006` | Which provider hooks expose stable interaction IDs, offered choices, freeform allowance, and replacement facts for Claude and Codex? | Blocks exact `agent.respond.v1` semantics and determines whether one provider must ship later. | integrations | phase 0 / blocking for respond |
| `AC-Q-007` | Should installed-plugin review present Coordinate and Operate as two user-facing toggles or one declared contract list with risk copy? | Changes comprehension and revocation UX, not runtime authority semantics. | product/security/native UI | before phase 2 |

### Decision log

| Date | Decision | Rationale/evidence | Requirements affected | Supersedes |
|---|---|---|---|---|
| 2026-08-12 | The agent declares; Tenon does not scrape. `agent.ask.v1` (agent states its own question) becomes the first-class path, ahead of `agent.respond.v1` (Tenon extracts a provider's question and answers it). | Extraction needs a scraper per provider — `Sources/TenonApp/ClaudeToolFacts.swift:74-92` parses Claude's `AskUserQuestion` schema today, and each new agent is another one. Nothing implements `agent.respond.v1` yet, so redirecting costs no shipped behaviour. | FR-038…040, NFR-010 | `agent.respond.v1` as the primary answer path; it survives as the labelled fallback for providers that do not declare |
| 2026-08-12 | An AI may orchestrate other AIs through Tenon's primitives. Tenon still owns no scheduler, queue, task graph, or dispatch loop. | Product owner's direction, 2026-08-12. The substrate is largely shipped already — `agent.inventory.v1`, `agent.command.v1`, `terminal.open/write/wait/scrollback.read.v1` are all `.programmatic`, so one agent can already start another and read its result; what is missing is identity, peer observation and a durable ask channel. Evidence that the loop belongs outside the host: orca retired its own coordinator (`orchestration coordinator-start` → "Retired: load the current orchestration skill") and never implemented `decompose()` (`references/orca/src/main/runtime/orchestration/coordinator.ts:185-196`). Building a scheduler here would adopt what the broadest rival abandoned. | FR-037, FR-040, FR-042 | the reading of `VISION.md:8-9` that treats agent-initiated spawning as out of scope |
| 2026-08-12 | The agent principal is minted from the pane, not self-asserted. | `IntentPrincipal.Kind.agent` is constructed in exactly one place in the repository and it is a spoof-rejection test (`Tests/TenonIntentCoreTests/IntentPolicyTests.swift:707`); nothing in `Sources/` mints one, so every agent call arrives as `cli:local-user` with `filesystem: .all, panes: .any` (`Sources/TenonApp/AppIntentRuntime.swift:31-35, 383-405`) and the dispatcher's agent hardening at `IntentDispatcher.swift:1253-1263` is unreachable by construction. Self-assertion would keep it unreachable. | FR-037 | none |
| 2026-08-12 | Pane provenance is proven by **process ancestry**, not by the caller's controlling terminal. | The controlling-terminal route was the design of record and it does not work, because the agent that matters detaches its tool subprocesses from the pane's PTY. Measured on this machine 2026-08-12, three independent ways: `claude` (pid 18432) holds `ttys020`, while the shell it spawns to run a tool command reports `proc_bsdinfo.e_tdev == UInt32.max`, shows `??` under `ps -o tty=`, is its own process-group leader, and fails `open("/dev/tty")` — identically with the Bash-tool sandbox on and off. A tty rule would therefore mint nothing in production, which is the same disease this task exists to cure: a guard whose condition is never constructed. Ancestry survives `setsid` because `setsid` does not change a parent, and it is strictly more precise for the distinction the product needs — a human typing at the pane's shell prompt descends from the *shell*, not from the agent, so they keep the ordinary CLI identity while the agent's own subprocesses do not. `LOCAL_PEERPID` supplies the kernel-attested starting pid, so no CLI wire-protocol change is needed. | FR-037 | matching the caller's controlling terminal against the pane's PTY |
| 2026-08-12 | `bypassAllPermissionPrompts` **does** disarm the agent confirmation hardening, and this is recorded rather than silently accepted. | `IntentDispatcher.effectiveConfirmation` forces `.always` for an open-class policy contract called by an `agent` audience (`Sources/TenonIntentCore/IntentDispatcher.swift:1253-1263`), and the `.always` branch resolves through `confirmationAuthorizer.authorize` (`:1190-1198`). In the app that authorizer is `PluginUIPrompt.confirmationAuthorizer()`, whose first statement returns `standingPermissionAnswer()` when set (`Sources/TenonApp/PluginUIPrompt.swift:225-231`), and that answer is `.allowOnce` whenever `bypassAllPermissionPrompts` is true — which is its default (`Sources/TenonCore/AppPreferences.swift:121`). So on a default install the forced re-ask is answered "allow" without a human seeing it. The switch is doing exactly what it says (bypass *all* prompts); the finding is that the agent narrowing buys nothing until the switch is either defaulted off or made to exclude agent-audience open contracts. | FR-037, NFR-004 | the reading that `effectiveConfirmation` alone hardens agent calls |
| 2026-08-12 | The hook binding registry **may** feed the mint, and `docs/architecture-interaction-boundaries.md` now says so in the passage that raised the doubt. | The EVENT inventory says hook facts "never enter the intent dispatcher" (`docs/architecture-interaction-boundaries.md:617-623`), and a principal is a dispatcher input, so the question was settled before code. The rule bars provider-reported *content* from becoming a dispatcher argument, result or grant; it does not bar the host from knowing which of its own panes is occupied. Two structural properties keep the mint inside it: the registry contributes **membership only** — pane UUID and surface token, both host-minted, with no `sessionID`, `transcriptPath`, `hookEventName` or activity payload read on that path — and the hook's declared process group is used **only as a veto**, never as a source. The pid matched against the caller's ancestry is always the host's own kernel read (`SurfacePool.agentTerminalIdentity`). A forged hook can deny a pane an agent identity; it can never confer one. | FR-037 | the reading that the passage forbids any use of the binding registry by host code |
| 2026-08-12 | Occupancy is the hook registry's binding set **cross-checked against the host's own PTY read**, not the binding alone. | `AgentSessionRegistry.record` (`Sources/TenonApp/AgentSessionHooks.swift:109-120`) does **not** run `AgentHookAdmission.admits` — that check lives only on the live-ingestion path (`Sources/TenonApp/AgentLensSession.swift:611`), so the stored `processGroupID` is a client-written value nothing has validated. Two consequences the mint has to answer: a binding survives the agent that made it until `retainOnly` prunes the dead pane, so a human typing at the recovered shell prompt of a pane where an agent used to run would otherwise mint `.agent`; and the stored group is not evidence on its own. Requiring `declaredProcessGroupID == getpgid(observedForegroundPID)` answers both — the agent must still be the pane's foreground process, and the value that identity is matched on is the host's. | FR-037 | minting from `AgentLensPool.models`, and minting from the binding registry unchecked |
| 2026-08-12 | The agent principal's identity **arrives late**, and that is accepted rather than papered over. | `AgentSessionRegistry.record` returns early without a non-empty `sessionID` and a resolvable transcript path (`Sources/TenonApp/AgentSessionHooks.swift:110-112`), so an agent that has started but not yet emitted a session-bearing hook is not in the registry and its earliest `tenon-cli` calls mint `.cli`. Accepted for three reasons: the window closes at the agent's first tool call, which is the same event that would carry any earlier signal; every alternative earlier signal available today is either UI-dependent (`AgentLensPool`) or unauthenticated (the pane's foreground `comm`, which any process can be named after); and the failure direction is the status quo — a late identity means the human's principal, never a wider one. | FR-037 | claiming the mint is complete from the pane's first instant |
| 2026-08-12 | The agent principal is narrowed on the **network** axis: every capability it holds carries `network: .none`, against `cliPrincipal`'s `.all`. | The narrowing had to be strict (a principal with the same grants is theatre) and had to leave the supervised loop intact (`terminal.open/write/wait/scrollback.read`, `filesystem.*`, `workspace.*`, `agent.*` are how one agent supervises another, and `AC-FR-024` forbids silently changing `tenon.agents.run`). Network is the one axis where the agent loses something real and loses nothing it needs: an agent's own process already has network access, so routing a fetch through Tenon adds the human's authority without adding capability, and `url.open.v1` against a remote address stops being a way for an agent to drive the human's browser. Pane scope was considered and rejected — restricting `panes` to the agent's own pane would break `terminal.open.v1`, which creates a pane that by definition is not the caller's. | FR-037, NFR-004 | granting the agent principal `cliPrincipal`'s grant set unchanged |
| 2026-08-12 | Agent principals are **per pane** (`agent:pane:<uuid>`), bounded by a 64-entry FIFO in the runtime. | `PolicyEngine` keys grants by the whole `IntentPrincipal` (`grantsByPrincipal[principal]`, `Sources/TenonIntentCore/IntentPolicy.swift:1020-1038`), so a per-pane id needs per-pane registration; a single shared id would have avoided that and would also have made the two agents this product exists to tell apart indistinguishable, which is the finding the task opens with. Registration is idempotent and eviction calls `removePrincipal`, so the map is bounded per invariant 10 without new lifecycle wiring. | FR-037, FR-042 | one process-wide agent principal |
| 2026-08-09 | Create a separate agent-control PRD rather than enlarge schedule automation or Agent Lens. | Agent control owns a public semantic boundary; PRD-013 owns scheduled plugin workflows and PRD-012 owns private human evidence. | all | none |
| 2026-08-09 | Copy Herdr's primitive separation and atomicity, not its server/TUI architecture. | Tenon is a native supervision app with governed intents and existing PTYs; background runtime is a different product promise. | FR-001, FR-011, FR-016…020 | direct Herdr feature parity |
| 2026-08-09 | Use an opaque re-presented value, not a permanent alias or resource handle. | Pane/surface continuity must survive async calls without creating a second lifetime owner. | FR-005/006 | global agent-name registry |
| 2026-08-09 | Initial draft limited the release to five intents and refused approval response. | This established the minimum reliable identity/wait substrate before product-convenience review. | FR-007, FR-011, FR-014, FR-019, FR-021/022 | broad agent API mirror |
| 2026-08-09 | Initial draft rejected prompt while working. | A naive queue can make completion of the active turn satisfy the wrong request. | FR-015/016 | Herdr-compatible prompt-while-working behavior |
| 2026-08-09 | Unknown never means complete. | Missing authority must reduce automation, not fabricate confidence. | FR-008…010, FR-018 | screen-silence completion inference |
| 2026-08-09 | Optimize for power after one trust decision: Observe does not interrupt; Coordinate and Operate may use standing consent. | Product feedback prioritizes useful unattended automation; Tenon's interaction law already preserves capability, scope, bounds, and telemetry after consent. | FR-023, FR-029/030, NFR-004 | repeated per-operation permission posture |
| 2026-08-09 | Add workspace-local aliases, bounded busy-agent queueing, and exact structured provider response, expanding v1 to seven intents. | These remove three high-frequency caller workarounds while exact references, delivery-time baselines, and interaction IDs prevent convenience from becoming fuzzy control. | FR-003…006, FR-015/018, FR-022, FR-026…030 | five-intent minimum and unconditional busy rejection |
| 2026-08-10 | Ship inventory and composition ahead of phase 0, as their own slice. | They need none of the lifecycle authority phase 0 is characterizing, and the gap they close was already costing product behavior: three shipped callers each invented their own `claude` command and silently dropped the options the person runs their agent with. | FR-031…036 | waiting for the identity/wait substrate before any agent contract |
| 2026-08-10 | Bind both contracts to `terminal.write` rather than mint an agent capability. | A caller that cannot write to a terminal can do nothing with either answer, and the composed line is only useful through `terminal.open.v1`, which that capability already gates. A new permission would have added review ceremony without narrowing authority. | FR-031, FR-033, NFR-004 | a distinct `agent.read` capability in every manifest |
| 2026-08-10 | A cross-agent continuation is a prompt naming the transcript, not a synthesized digest. | Neither CLI can resume the other's session, and the agent being handed the work is better at deciding how much of a transcript it needs than a summarizer would be. The host states the path, the format, and the reading order; the agent reads. | FR-035 | host-generated summary file, or a public transcript-read intent |
| 2026-08-10 | The habitual options come first, ahead of any provider subcommand. | `codex` takes its options before its subcommand and `claude` accepts them anywhere, so one ordering is correct for both — measured from `codex --help` and `claude --help` on 2026-08-10. | FR-034 | per-provider argument interleaving |

## 13. Verification receipts

| Date | Worktree/commit | Environment | Scope/command | Result | Known exclusions |
|---|---|---|---|---|---|
| 2026-08-12 | current dirty tree, session `5d1e7e00` (T-136) | headless `swift test --disable-automatic-resolution` on macOS (Darwin 25.4.0); `xcodebuild build-for-testing` on Xcode 17C52; live-process probes on the same machine | `AgentPrincipalMintTests` 10, `AgentCallerAdmissionTests` 20 (14 existing + 6 occupancy), `CLISocketServerTests` +1; full suite `Executed 2051 tests, with 0 failures`; `xcodebuild build-for-testing` `** TEST BUILD SUCCEEDED **`; `xcodegen generate` then `git diff -- Tenon.xcodeproj` shows only the added test file | **`AC-FR-037` shipped — the `.agent` principal now exists in production.** `CLISocketServer` reads `LOCAL_PEERPID` on the accept thread before the client sends a byte and carries it on the request; `AgentPaneOccupancyReader` builds candidates from the hook binding registry cross-checked against `SurfacePool.agentTerminalIdentity`; `CLICommandExecutor.callerPrincipal` walks `pbi_ppid` outward and mints `agent:pane:<uuid>` through `AppIntentRuntime.agentPrincipal(forPane:)`, whose grants are `trustedGrants(reachesTheNetwork: false)` — strictly narrower than the CLI's on the network axis, identical everywhere else. `IntentDispatcher.effectiveConfirmation` is now reachable: driven from a minted principal it answers `.always`, and it answers `.policy` for the person. Mutation-checked one at a time, each restored and re-compared byte-for-byte afterwards: `return .always` → `contract.effects.confirmation` reddens `testTheDispatchersAgentHardeningFiresOnAMintedPrincipal`; the mint returning `cliPrincipal` reddens `testACallFromInsideAnAgentPaneCarriesTheAgentPrincipal`; admitting the first candidate without the ancestry walk reddens `testACallerOutsideEveryAgentSubtreeStaysCLI`; `reachesTheNetwork: false` → `true` reddens `testTheAgentPrincipalIsStrictlyNarrowerThanTheCLIPrincipal`; dropping the declared/observed process-group cross-check reddens `testAPaneThatMovedOnFromItsBoundAgentIsNotACandidate`; replacing the accept-time `LOCAL_PEERPID` read with `.unknown` reddens `testTheHandlerReceivesTheKernelsPeerProcessIDForTheConnection`. The spoof test at `IntentPolicyTests.swift:707` passes unchanged. | **`AC-FR-041` and `AC-FR-042` untouched — not started this session.** Three honest limits on what shipped: (1) identity arrives late, because `AgentSessionRegistry.record` needs a session-bearing hook, so an agent's calls before its first tool call mint `.cli`; (2) `bypassAllPermissionPrompts` still answers the forced `.always` with `.allowOnce` before any prompt is drawn (`PluginUIPrompt.swift:225-231`, default `true` at `AppPreferences.swift:121`), so on a default install the re-ask is granted without a human seeing it — the guard is now *reachable* and *recorded in telemetry*, and it is *not yet a barrier* until the switch is defaulted off or made to exclude agent-audience open contracts; (3) a third-party plugin may declare an intent for `[.cli]` without `.agent`, in which case an agent-minted caller is denied `audienceCannotInvoke` where the person succeeds — correct behaviour by the audience system, but a real difference from the identity it replaces. No shipped plugin declares such an intent (all use `["plugin", "user"]`). |
| 2026-08-09 | current dirty Tenon tree; Herdr reference 0.8.0 | source inspection only | README/docs plus agent schema, CLI, wait, event hub, detection, integrations, persistence; Tenon Agent Lens, runtime helper, PRDs, architecture law | PRD and acceptance model drafted from source evidence | no build, provider run, UI run, or implementation exists |
| 2026-08-12 | current dirty tree, session `workflow-T136` | headless `swift test` on macOS 15.4 (Darwin 25.4.0); live-process probes on the same machine | `AgentCallerAdmissionTests` 14, `AgentCallerProvenanceTests` 5; full suite `Executed 2020 tests, with 0 failures` | **`AC-FR-037` stays `proposed` — the decidable rule landed, the mint did not.** `AgentCallerAdmission` (pane admission from process ancestry) and `AgentCallerProvenance` (`LOCAL_PEERPID` + `pbi_ppid`) are green, but nothing in `Sources/` constructs an `.agent` principal yet: the socket does not capture the peer pid, `CLICommandExecutor` still passes `cliPrincipal`, and the narrowed capability grant is unwritten. Blocked on an open design question — agent occupancy per pane is known only to `AgentLensPool`, which is populated when a human opens Agent Lens (`Sources/TenonApp/AgentLensSession.swift:857-886`), so minting from it would make identity depend on whether someone looked. `AC-FR-041`/`AC-FR-042` not started. Mutation-checked: ambiguity refusal and the `pid > 1` launchd guard each turn a named test red when removed; loosening `didFill` to `returnCode >= 0` is an **equivalent** mutation here, since the `parent > 1` guard below already rejects a zeroed struct. One earlier full run under load reported 1 failure whose name was lost to a `tail -40` capture; two later full runs were green, so it is unidentified and presumed the T-134 flake class rather than shown to be |
| 2026-08-10 | current dirty tree, session `c437029d` (T-104) | headless `swift test` on macOS 15.4 | `AgentLaunchCommandTests` 11, `AgentIntentProviderTests` 10, `CoreIntentCatalogTests` 10, `InteractionBoundaryFitnessTests` 20, `KanbanPluginTests` 31, `WorkspaceScopedViewStateTests` 9; full suite | `AC-FR-031…036` shipped and green | `AC-FR-001…030` untouched; no CLI-principal receipt; the handoff prompt has not been read by a live agent on the other side; `codex`/`claude` transcript layouts were confirmed by inspection on one machine only |

## 14. Change history

| Date | Change | Why | Author/decision owner |
|---|---|---|---|
| 2026-08-09 | Initial proposed PRD | Translate Herdr's strongest agent-native automation lessons into Tenon's product and architecture boundaries. | product/runtime review pending |
| 2026-08-09 | Power-first revision | Replace conservative permission posture with progressive trust; add aliases, queued prompts, and structured question/approval response. | product direction from user feedback |
| 2026-08-10 | `AC-FR-031…036` added and shipped (T-104) | One composition now produces every agent command line Tenon runs, and a session recorded by one agent can be continued by another. | user-directed; session `c437029d` |
