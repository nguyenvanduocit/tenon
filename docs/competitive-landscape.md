# Competitive landscape — human supervision for parallel agents

**Original scan:** 2026-07-24

**Reframed:** 2026-07-30
**Scope:** Native terminal workspaces, agent command centers, orchestrators, and the
human-attention problem that Tenon chooses to own.

**Confidence labels:** `HIGH` means directly supported by primary product evidence or live
repository evidence. `MEDIUM` means multiple sources point in the same direction but
product details remain incomplete. `LOW` means a hypothesis that needs direct validation.

## Position

> **Tenon is the human supervision layer for parallel CLI-agent work.**

Agents and their harnesses own planning, spawning, scheduling, and execution. Tenon
preserves shared context, directs scarce human attention, and makes those workstreams
understandable, verifiable, and steerable.

The competitive question is therefore not “How many agents can this app run?” It is:

> How much parallel agent work can one person supervise without losing context,
> correctness, or trust?

**HIGH:** Parallel execution, isolated worktrees, session lists, status, review, and
steering are becoming standard capabilities. OpenAI calls the Codex app a command center
for multiple agents. GitHub positions Agent HQ as a unified workflow for different agents.
Warp Oz launches, tracks, governs, and steers multiple harnesses at cloud scale. A product
position based only on multiplexing or launching agents is crowded.

**MEDIUM hypothesis:** Existing products expose threads, artifacts, diffs, audit trails,
notifications, and review queues, but this scan did not perform a feature-level audit
against Tenon's five operator questions, evidence anchors, freshness, or exact re-entry.
Tenon's opportunity is to test whether combining those capabilities into a terminal-native
supervision loop measurably improves human reorientation and judgment.

## The market by layer

| Layer | Representative products | Primary value | Competitive implication for Tenon |
|---|---|---|---|
| Native terminal workspace | cmux, Mux0, Supacode, Factory Floor, Forge, Muxy, and many libghostty projects | PTYs, tabs, splits, worktrees, browser/diff/status surfaces | Terminal quality and workspace continuity are required foundations. |
| Agent command center | OpenAI Codex app, GitHub Agent HQ, Conductor | Parallel threads, delegation, worktrees, review, steering | Multi-agent visibility and handoff are table stakes. |
| Agent orchestration platform | Warp Oz and workflow-oriented agent platforms | Spawn, schedule, automate, govern, and scale agent execution | Tenon integrates with execution owned by agent harnesses; its product value sits at the human-attention boundary. |
| Human supervision layer | Tenon's target position | Situation awareness, evidence-linked context, attention prioritization, exact re-entry | This is the hypothesis Tenon must prove through measurable operator outcomes. |

The native-terminal product list comes from the earlier `awesome-libghostty` scan and is
directionally useful, not a complete current census (`MEDIUM`). The claims about OpenAI,
GitHub, and Warp are based on their own product announcements (`HIGH`).

## Tenon's customer value

The product should answer five questions without forcing the operator to reread every
transcript:

1. What materially changed since I last looked?
2. What requires my judgment now?
3. What is the agent claiming, and what evidence supports it?
4. Which work is blocked, drifting, stale, or in conflict?
5. What can I safely ignore for now?

This defines a different optimization target from a session grid. Tenon optimizes
**verified outcomes per minute of human attention**, with error rate and provenance as
hard constraints.

## Product boundary

Tenon's terminal-first boundary is strategically useful:

- CLI agents continue to execute as ordinary processes in real PTYs.
- Users retain the native harness behavior, configuration, and portability of Codex,
  Claude Code, and future agent tools.
- Tenon can observe and organize multiple harnesses without reimplementing their execution
  semantics.
- Every condensed claim can return to the originating transcript, diff, command result,
  test receipt, or artifact.

This boundary lets Tenon specialize in supervision while agent vendors continue to improve
execution.

## Role of the plugin architecture

The plugin platform is enabling architecture for the product position:

- adapters can normalize different agent harnesses without hard-coding each one into the
  native host;
- public contracts make source, freshness, authority, and provenance governable;
- supervision experiments can evolve without duplicating domain semantics;
- built-in and third-party surfaces use the same reviewed boundaries.

The customer-facing differentiation is safer and faster judgment. Plugin extensibility
makes that value adaptable across agent tools and protects the architecture from private
integration paths.

Muxy remains a relevant technical comparator because it demonstrates a JavaScriptCore
extension host, permissions, webview UI, and an extension store. Its existence validates
extension demand (`HIGH`, from the inspected repository in the earlier technical
research). The competitive decision for Tenon comes from what the extension system
enables: trustworthy cross-harness supervision.

## Initial wedge

**MEDIUM recommendation:** Build an Attention Inbox for three to five user-run Codex or
Claude Code PTYs.

The wedge consists of:

- explicit states such as `needs_input`, `approval`, `failed`, `ready_for_review`, and
  `completed`;
- a fresh “since you last looked” context capsule with goal, material delta, requested
  judgment, blocker, next action, and evidence links;
- exact return to the source workspace, pane, process, and evidence.

This direction is not a claim about current runtime support. It is a product experiment
specified in [`research-human-agent-supervision.md`](research-human-agent-supervision.md).
Any public implementation must follow
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).

## Competitive proof

The position survives only if Tenon changes operator outcomes. Compare the Attention Inbox
with raw tabs over at least 20 intervention events.

Initial falsifiable thresholds:

- median context-reorientation time improves by at least 30%;
- missed explicit blockers do not increase;
- false-attention items remain below 10%;
- traceability error remains zero: every material claim resolves to its exact source
  anchor, hash, and freshness state;
- unsupported-claim error remains zero in the reviewed sample;
- verified outcomes per human-attention minute improve;
- outcome quality does not decline as concurrent workstreams increase.

**MEDIUM:** If simple notifications provide the same benefit, Tenon should narrow the
claim to reliable agent-aware terminal signaling. If users repeatedly reopen complete
transcripts to regain trust, the context capsule has not preserved enough evidence. If
operator errors rise with concurrency, faster navigation has not solved supervision.

## Risks

### Summary-induced overconfidence (`HIGH`)

An attractive generated summary can hide missing, stale, or semantically unrelated
evidence. Context capsules must show exact anchors, hashes, freshness, and authority;
distinguish reported assertions from verified observations; and preserve direct access to
raw sources.

### A second noisy inbox (`HIGH`)

An attention surface can become another stream the user must manage. Explicit structured
signals should precede inferred urgency, and false-attention rate is a release metric.

### Vendor convergence (`HIGH`)

OpenAI, GitHub, and Warp are already investing in context continuity, review queues,
artifacts, audit trails, and steering. Tenon must differentiate through cross-harness,
terminal-native, evidence-linked supervision and measurable reduction in human
reorientation cost.

### Coupled workstreams (`MEDIUM`)

Safe fan-out is lower when agents touch shared code, depend on one another, or operate at
different risk levels. A flat count of active agents is not a capacity measure.

## Sources

### Primary product sources

- [OpenAI — Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/)
- [OpenAI — How agents are transforming work](https://openai.com/index/how-agents-are-transforming-work/)
- [GitHub — Introducing Agent HQ](https://github.blog/news-insights/company-news/welcome-home-agents/)
- [Warp — A single pane of glass for managing all of your cloud agents](https://www.warp.dev/blog/multi-harness-cloud-agent-orchestration)
- [Warp — Introducing Oz](https://www.warp.dev/blog/oz-orchestration-platform-cloud-agents)
- [Muxy repository](https://github.com/muxy-app/muxy)

### Category scan and adjacent products

- [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
- [cmux](https://cmux.com/)
- [Conductor](https://www.conductor.build/)
- [Supacode research page](https://rywalker.com/research/supacode)

The cognitive and supervisory-control evidence behind the attention thesis is collected in
[`research-human-agent-supervision.md`](research-human-agent-supervision.md).
