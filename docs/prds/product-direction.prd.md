# PRD — Tenon product direction and human-supervision outcome

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-000` |
| Lifecycle | `partial`; product direction accepted, supervision wedge unvalidated |
| Owner | product |
| Reviewers | target operators, design, engineering, research, accessibility, security, measurement |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Primary source | [`VISION.md`](../../VISION.md) |
| Research | [`research-human-agent-supervision.md`](../research-human-agent-supervision.md), [`research-reference-terminals.md`](../research-reference-terminals.md) |
| Acceptance specification | [`product-direction.feature`](product-direction.feature) |

## 1. Executive summary

### Problem

CLI agents make execution cheap enough to run several workstreams at once, but human attention does
not scale at the same rate. More panes expose more output without answering what changed, what needs
judgment, which claim is supported, where work is blocked or conflicting, and what can safely wait.
The operator repeatedly reconstructs context from transcripts and loses time or correctness to
attention residue and out-of-the-loop automation.

A second risk is building architecture instead of product. Plugin governance, intent policy, native
hosting, evidence provenance, and isolation matter only insofar as they let Tenon evolve quickly and
help one person supervise work reliably. Permission ceremony, duplicate schemas, feature-specific
host APIs, or tests that cannot prove user interaction slow the feedback loop without increasing
customer value.

### Proposed outcome

Tenon is the human supervision layer for parallel CLI-agent work. Agents continue in their native
harnesses and real PTYs; Tenon preserves shared context, directs scarce attention, links claims back
to raw evidence, and returns the person to the exact workspace/pane/process/evidence. It opens and
behaves like a native terminal, combines session-adjacent files/changes/docs/web/plugin views in one
spatial workspace, and remains useful with no plugins.

The first product experiment is an Attention Inbox for three to five independently running Claude
Code or Codex PTYs. Explicit states and evidence-linked “since last looked” capsules should reduce
reorientation while preserving blocker detection and trust. This is not yet a shipped claim.

Architecture serves iteration: one typed semantic implementation, replaceable plugins, loud load-
time diagnostics, hot reload, bounded resources, and proportional permission policy. Trusted
bundled/development plugins run declared behavior without repeated prompts; local plugin authority is
normally reviewed once on enablement or material expansion. Only concrete high-risk actions justify
additional interruption.

### Why now

The native terminal workspace, spatial canvas, persistence, libghostty integration, built-in content,
plugin/intent runtime, CLI, palette, automations, Kanban, and host-internal Agent Lens ship. The
cross-session Attention Inbox, evidence capsules, structured signal ingestion, and fan-out outcome
measurements do not. A canonical product PRD is required to keep enabling architecture subordinate
to the next falsifiable customer outcome and to record developer velocity as a product constraint.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| current product contract/status | [`VISION.md`](../../VISION.md), [`README.md`](../../README.md), live PRD catalog | high | terminal-first shell ships; supervision wedge remains planned |
| operator problem/research | [`research-human-agent-supervision.md`](../research-human-agent-supervision.md) | medium/high | attention/reorientation is the target bottleneck; thresholds are hypotheses |
| architecture capability | source/manifests and PRD-001…014/017 | high | current workspace, evidence, plugin, CLI, agent seams |
| reference terminals | [`research-reference-terminals.md`](../research-reference-terminals.md) | medium/high | keep terminal center, stable surfaces, functional layout, avoid God objects |
| plugin research | [`research-plugin-runtimes.md`](../research-plugin-runtimes.md) | historical/medium | AI-writability/debug speed and isolation trade-offs, not current normative API |
| product-owner direction | 2026-08-09 conversation | high | permission and architecture must reduce—not add—development friction |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | One person cannot reliably understand and intervene in growing parallel CLI-agent work by watching raw panes alone. |
| Primary user? | a technical operator running multiple local Codex/Claude CLI workstreams in real repositories and PTYs |
| Success? | more verified outcomes per minute of human attention with lower reorientation and no loss of blocker detection/trust |
| Fixed constraints? | real terminal evidence, harness ownership, exact re-entry, native macOS interaction, architecture serving changeability |
| Unknown? | whether an Attention Inbox/capsules achieve the threshold; which signals remain trustworthy across harnesses |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `PDR-A-001` | Evidence-linked context compression improves practical fan-out. | controlled ≥20-event comparison | unvalidated |
| `PDR-A-002` | Explicit lifecycle states are more useful than inferred urgency in the first wedge. | false-attention/blocker study | unvalidated but preferred |
| `PDR-A-003` | Installation-scoped permission review provides enough accountability without slowing trusted development. | prompt-rate/dev-cycle and incident review | newly accepted direction |

## 3. Users, jobs, positioning, and vocabulary

The primary user is a developer or technical lead who runs several CLI agents, remains accountable
for the resulting code, and needs to intervene at high-leverage moments. They value terminal fidelity,
direct evidence, low switching cost, and fast customization more than an autonomous orchestration
platform. Secondary users are plugin/integration authors and AI coding agents extending Tenon.

- Understand what materially changed without reopening every transcript.
- Notice explicit blockers, approvals, failures, review readiness, and completion promptly.
- Separate an agent's claim from verified evidence and inspect the raw source.
- Return to the exact live process and take over naturally.
- Customize workflows quickly without architecture or permission bureaucracy.

Tenon is not an agent scheduler, planner, remote execution cloud, autonomous manager, or editor-first
IDE. Agent harnesses own execution. Tenon owns operator situation awareness and evidence navigation.

| Term | Meaning | Not to be confused with |
|---|---|---|
| supervision | understanding, prioritizing, verifying, and intervening | agent planning/spawning/execution |
| verified outcome | result supported at the represented authority by direct evidence | agent-reported completion text |
| attention item | explicit state requiring or summarizing operator awareness | every terminal output event |
| context capsule | bounded since-last-look navigation aid with evidence anchors | independent source of truth |
| exact re-entry | origin workspace, pane, process incarnation, and evidence location | opening a similar transcript/file |
| developer velocity | time/steps from idea or plugin edit to verified behavior | bypassing all safety regardless of risk |

## 4. Goals, metrics, scope, and non-goals

- `PDR-G-001` — Scale human judgment, not merely parallel execution count.
- `PDR-G-002` — Keep raw terminal/diff/command/test evidence inspectable and authoritative.
- `PDR-G-003` — Reduce context switching and restore exact live work quickly.
- `PDR-G-004` — Preserve terminal fidelity and state continuity across spatial organization.
- `PDR-G-005` — Make product experiments and integrations replaceable and AI-writable.
- `PDR-G-006` — Prefer the simplest architecture and permission policy that protects a concrete risk.

| Metric | Baseline | Initial target | Method |
|---|---|---|---|
| median context-reorientation time | raw Tenon tabs, pilot measured | ≥30% lower with Attention Inbox | ≥20 real intervention events |
| missed explicit blockers | pilot measured | no increase | blinded event review |
| false-attention items | none | <10% | item adjudication |
| traceability errors | none | 0 accepted | anchor/hash/freshness verification |
| unsupported material claims | none | 0 accepted | authority/evidence review |
| verified outcomes per attention minute | pilot measured | improve | task outcome/time study |
| outcome quality under concurrency | pilot measured | no decline | review defects/interventions |
| unchanged-manifest dev permission prompts | current measured | 0 for trusted development loop | instrumentation/usability audit |

In scope: product promise, terminal-first shell, supervision questions, evidence integrity, session
continuity, extensibility, developer velocity, proportional permissions, first Attention Inbox
experiment, measures, and stop conditions. Non-goals: owning agent execution, replacing raw evidence,
inferring confident semantic state from arbitrary terminal prose, maximizing number of open agents,
building a marketplace before product fit, or treating hardening work as value without a threat it
actually reduces.

## 5. Product experience

Tenon launches as one native terminal workspace. Workspaces live in the sidebar, own tabs, and each
tab owns a 12×12 spatial canvas. A new tab is one full libghostty terminal. Pane split, move, swap,
resize, tab/workspace navigation, and content changes preserve stable identity and live processes;
files, changes, docs, web previews, Agent Lens, Kanban, and plugins remain adjacent to the terminal.

The planned Attention Inbox gathers explicit `needs_input`, `approval`, `failed`,
`ready_for_review`, and `completed` states from supported typed sources. Each item contains goal,
material delta, claim/blocker/decision, next action, freshness, and exact raw-evidence links. Selecting
returns to the exact origin. Unsupported/stale/inferred content is labelled, and Terminal remains the
fallback evidence route.

Plugin development should feel like edit → hot reload → visible result or actionable load error.
Architecture rules prevent duplicate behavior and lost lifecycle, but must not require needless
public contracts for same-owner work. Permissions are declared/auditable and mostly invisible after
installation review. Native UI follows `docs/designs.md` and preserves keyboard/pointer/VoiceOver
parity, high information density, semantic color, and platform behavior.

## 6. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `PDR-FR-001` | Tenon **MUST** position itself as the human supervision layer for parallel CLI-agent work: agents scale execution; Tenon scales human judgment. | shipped direction | `@req-pdr-fr-001` |
| `PDR-FR-002` | The primary workflow **MUST** support a person supervising multiple independently running local CLI-agent workstreams in real repositories and PTYs. | shipped foundation; experiment planned | `@req-pdr-fr-002` |
| `PDR-FR-003` | Agent harnesses **MUST** retain planning, spawning, scheduling, execution, and terminal-process semantics; Tenon **MUST NOT** reinterpret itself as their orchestrator. | shipped | `@req-pdr-fr-003` |
| `PDR-FR-004` | Tenon **MUST** open and behave as a terminal, with one full native terminal in a new tab and terminal-native keyboard/mouse/clipboard/focus/scale/resize behavior. | shipped | `@req-pdr-fr-004` |
| `PDR-FR-005` | The shell **MUST** organize directory workspaces in a sidebar, tabs within each workspace, and a spatial pane canvas within each tab. | shipped | `@req-pdr-fr-005` |
| `PDR-FR-006` | Split/move/swap/resize/tab/workspace transitions **MUST** preserve stable pane/surface identity and exact rollback/fail-soft behavior; relaunch **MUST NOT** claim to resurrect processes. | shipped/partial quality | `@req-pdr-fr-006` |
| `PDR-FR-007` | Terminal, transcript, diff, command result, file, and test receipt **MUST** remain inspectable source evidence; summaries **MUST NOT** replace or silently upgrade them. | shipped foundation | `@req-pdr-fr-007` |
| `PDR-FR-008` | The product **MUST** help answer material change, current judgment need, claim/evidence, blocker/drift/conflict, and safe-to-ignore questions without rereading every transcript. | partial/planned cross-session | `@req-pdr-fr-008` |
| `PDR-FR-009` | Explicit attention states **SHOULD** include needs-input, approval, failed, ready-for-review, and completed with source, timestamp, and freshness. | planned | `@req-pdr-fr-009` |
| `PDR-FR-010` | Inferred urgency/tone **MUST NOT** outrank explicit typed lifecycle facts in the first supervision wedge. | planned | `@req-pdr-fr-010` |
| `PDR-FR-011` | A context capsule **MUST** contain goal, material delta since last look, current claim/blocker/decision, next action, freshness, and exact evidence links. | planned | `@req-pdr-fr-011` |
| `PDR-FR-012` | Every material capsule claim **MUST** carry source identity, immutable location, content hash, capture time, freshness, and authority level, distinguishing reported assertion from verified observation. | planned | `@req-pdr-fr-012` |
| `PDR-FR-013` | Selecting supervision evidence **MUST** return to the exact workspace, pane, live process incarnation, and relevant transcript/diff/command/test location when available. | planned on shipped identity foundation | `@req-pdr-fr-013` |
| `PDR-FR-014` | The first Attention Inbox experiment **MUST** target three to five independent Claude Code or Codex PTYs and preserve Terminal as the exact evidence fallback. | planned | `@req-pdr-fr-014` |
| `PDR-FR-015` | Host-internal Agent Lens **MUST** remain a current-session evidence projection and **MUST NOT** be represented as the cross-session Attention Inbox. | shipped | `@req-pdr-fr-015` |
| `PDR-FR-016` | Files, changes, docs, web preview, Kanban, Agent Lens, and plugin views **SHOULD** coexist with terminals in one window to reduce workflow switching without becoming an editor-centric IDE. | shipped/continuous | `@req-pdr-fr-016` |
| `PDR-FR-017` | Plugins **MUST** enable replaceable agent adapters and supervision experiments through governed current surfaces while the terminal workspace remains useful with every plugin disabled. | shipped foundation | `@req-pdr-fr-017` |
| `PDR-FR-018` | The common plugin authoring loop **MUST** be edit, hot reload, and either visible behavior or a load-time actionable diagnostic; AI-written code **MUST** fail loudly rather than silently against invented APIs. | partial/continuous | `@req-pdr-fr-018` |
| `PDR-FR-019` | Same-owner behavior **MUST** prefer simple typed/local calls; public contracts **MUST** exist only for real independent ownership, discovery, authority, compatibility, result-cardinality, or lifetime needs. | shipped normative | `@req-pdr-fr-019` |
| `PDR-FR-020` | Permission policy **MUST** optimize developer velocity: trusted bundled/development plugins auto-use declared grants, local authority is reviewed at enablement/material expansion, and unchanged ordinary operations **MUST NOT** repeatedly prompt. | planned/partial | `@req-pdr-fr-020` |
| `PDR-FR-021` | Extra per-operation confirmation **MUST** name a concrete sensitive, external, destructive, or difficult-to-reverse risk; permission ceremony **MUST NOT** be added solely for architectural purity. | planned policy | `@req-pdr-fr-021` |
| `PDR-FR-022` | Product and architecture decisions **MUST** prefer a coherent thin vertical slice with source/test/visual evidence over a broad framework lacking a current user outcome. | continuous | `@req-pdr-fr-022` |
| `PDR-FR-023` | The plugin platform **MUST** remain enabling architecture; customer value and prioritization **MUST** be expressed as faster, safer human judgment rather than API count. | shipped direction | `@req-pdr-fr-023` |
| `PDR-FR-024` | The Attention Inbox experiment **MUST** compare against raw Tenon tabs across at least 20 real intervention events containing input, failure, review, completion, and conflict cases. | planned | `@req-pdr-fr-024` |
| `PDR-FR-025` | The experiment **MUST** reduce median context-reorientation time by at least 30% without increasing missed explicit blockers. | planned metric | `@req-pdr-fr-025` |
| `PDR-FR-026` | Fewer than 10% of Inbox items **MAY** be false-attention items in the reviewed sample. | planned metric | `@req-pdr-fr-026` |
| `PDR-FR-027` | Accepted traceability and unsupported-material-claim errors **MUST** both be zero in the reviewed experiment sample. | planned metric | `@req-pdr-fr-027` |
| `PDR-FR-028` | Verified outcomes per human-attention minute **MUST** improve and reviewed outcome quality **MUST NOT** decline as concurrent workstreams increase. | planned metric | `@req-pdr-fr-028` |
| `PDR-FR-029` | If simple notifications match capsule benefit, the product **MUST** narrow to reliable agent-aware signaling rather than preserve unnecessary context machinery. | planned stop rule | `@req-pdr-fr-029` |
| `PDR-FR-030` | If operators still reread whole transcripts, inferred urgency creates excessive false attention, or errors rise with concurrency, the experiment **MUST** revise/narrow the capsule or supervision claim before rollout. | planned stop rule | `@req-pdr-fr-030` |
| `PDR-FR-031` | Product status **MUST** distinguish shipped foundation, partial current-session supervision, and planned cross-session outcomes; future behavior **MUST NOT** be described as shipped. | shipped process | `@req-pdr-fr-031` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `PDR-NFR-001` | terminal fidelity | Real libghostty surfaces **MUST** preserve native interaction and remain central; the app build consumes the pinned prebuilt framework rather than rebuilding Ghostty. | shipped | `@req-pdr-nfr-001` |
| `PDR-NFR-002` | evidence integrity | Material claims **MUST** be reversible, freshness-aware, authority-labelled, and deterministically checked before display as verified. | planned/partial | `@req-pdr-nfr-002` |
| `PDR-NFR-003` | privacy/security | Evidence summarization **MUST** be read-only, minimum-scope, tool-free, secret-free, explicit-provider only, and treat model output as untrusted candidate data. | planned | `@req-pdr-nfr-003` |
| `PDR-NFR-004` | performance | Pointer/layout and terminal interaction **MUST** remain responsive with several live surfaces; high-frequency geometry **MUST NOT** reconstruct processes/filesystems/hosts. | shipped/continuous | `@req-pdr-nfr-004` |
| `PDR-NFR-005` | reliability | Catalog/state/schema/filesystem drift **MUST** fail soft while committed work, live surface identity, and exact evidence fallback remain available. | shipped/continuous | `@req-pdr-nfr-005` |
| `PDR-NFR-006` | accessibility | All supervision, workspace, terminal-adjacent, and permission-review outcomes **MUST** preserve keyboard, pointer, VoiceOver, focus, contrast, and non-color-only parity. | partial/continuous | `@req-pdr-nfr-006` |
| `PDR-NFR-007` | native design | Host UI **MUST** use Tenon's normative density, typography, semantic colors, geometry, components, and platform interaction rather than feature-local visual systems. | shipped process | `@req-pdr-nfr-007` |
| `PDR-NFR-008` | developer velocity | Median trusted plugin edit-to-visible-result time and number of manual permission/architecture steps **MUST** be measured and **MUST NOT** regress without a named risk/outcome justification. | planned measurement | `@req-pdr-nfr-008` |
| `PDR-NFR-009` | changeability | Layout rules, content identity, resource lifetime, plugin adapters, and supervision experiments **MUST** remain separable enough to replace one without reconstructing unrelated state. | shipped/continuous | `@req-pdr-nfr-009` |
| `PDR-NFR-010` | measurement | Product claims **MUST** carry baseline, sample, method, threshold, authority, and failure criteria; “more agents open” **MUST NOT** be a success metric. | planned/continuous | `@req-pdr-nfr-010` |
| `PDR-NFR-011` | observability | Shipped/partial/planned state, degraded evidence, unsupported providers, stale capsules, and failed re-entry **MUST** be explicit and recoverable. | partial | `@req-pdr-nfr-011` |
| `PDR-NFR-012` | architecture | Every implemented interaction **MUST** obey PRD-011, but architecture ceremony **MUST** remain proportional and may not substitute for product evidence. | shipped/continuous | `@req-pdr-nfr-012` |

## 7. Acceptance and architecture

[`product-direction.feature`](product-direction.feature) maps all 43 requirements. Shipped product
contract examples link to owning feature PRDs; planned supervision and velocity examples are tagged
`@pending` until research receipts exist.

The supervision path observes typed provider facts and immutable evidence, publishes bounded
attention/capsule state, and returns through existing workspace/pane identities. It does not create a
generic authority, take over agent processes, or treat summaries as evidence. Permission UX is a
policy projection over PRD-010/011, not a new mechanism.

## 8. Delivery matrix, roadmap, risks, and decisions

| Requirements | Evidence | State |
|---|---|---|
| 001…007, 015…019, 023, 031, NFR-001/004/005/007/009/012 | current shell, terminal, plugins, Agent Lens, architecture PRDs/source/tests | shipped/continuous |
| 008…014 | Agent Lens provides session-local foundation; cross-session states/capsules/inbox/re-entry assembly | partial/planned |
| 020…021 and NFR-008 | bundled standing consent exists; simplified local installation review and velocity measurements remain | planned/partial |
| 022, 024…030 and NFR-002/003/006/010/011 | delivery principle and falsifiable Attention Inbox experiment | planned/continuous |

Roadmap order:

1. keep terminal/workspace interaction and evidence routes reliable;
2. remove developer-loop permission/architecture friction and instrument edit-to-result;
3. complete provider-typed lifecycle signals and exact source identities;
4. build the smallest Attention Inbox/capsule experiment for three to five PTYs;
5. run ≥20-event comparison and narrow/stop if thresholds fail;
6. only then broaden adapters, inference, or marketplace/release investment.

Risks are building a prettier multiplexer instead of supervision, false confidence from summaries,
prompt fatigue, architecture becoming bureaucracy, inference noise, cross-session identity mistakes,
and faster switching with worse decisions. Explicit signals, raw anchors, zero-error evidence gates,
proportional installation policy, thin slices, exact re-entry, and falsifiable stop rules mitigate them.

Decisions: human judgment is the product bottleneck; real PTYs/harnesses keep execution ownership;
raw evidence is authoritative; Agent Lens is not yet the Inbox; the first wedge uses explicit states;
success is verified outcomes per attention minute, not agent count; plugins serve replaceability and
AI-writability; developer velocity comes before permission ceremony; extra architecture/security
cost requires a concrete risk and must stay proportional.

## 9. Verification receipts and change history

| Date | Evidence | Result |
|---|---|---|
| 2026-07-30 | human-agent supervision research | medium-confidence wedge and falsifiable thresholds; no runtime claim |
| 2026-08-09 | current source/docs audit | native foundation mapped; Inbox/capsules/fan-out remain planned |
| 2026-08-09 | product-owner direction | permission and architecture explicitly subordinate to development speed and product outcomes |

Initial canonical PRD created 2026-08-09. It packages `VISION.md` without changing its authority and
adds the explicit low-friction permission/developer-velocity decision.
