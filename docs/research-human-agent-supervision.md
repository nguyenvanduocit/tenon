# Research: human supervision for parallel agent work

**Date:** 2026-07-30

**Status:** product research and falsifiable direction; not an implementation contract

**Confidence labels:** `HIGH` means directly supported by primary product evidence,
peer-reviewed research, or the live repository. `MEDIUM` means a reasoned transfer from
adjacent research that Tenon still needs to validate. `LOW` means a useful hypothesis with
material uncertainty.

## Research question

As agent execution becomes cheap and parallel, what limits the amount of useful work one
person can supervise, and where can Tenon improve that limit?

## Conclusion

**HIGH:** The bottleneck is moving from producing agent work to directing human attention
across that work. OpenAI describes the core challenge as directing, supervising, and
collaborating with agents at scale. Its internal usage data reports that users at the 99th
percentile generated more than 60 hours of agent turns per day by June 2026, distributed
across multiple parallel agents. GitHub and Warp are also building unified agent-management
surfaces. Parallel execution is already becoming a standard product capability.

**MEDIUM:** Tenon's strongest opportunity is the **human supervision layer** above
user-run CLI agents:

> Preserve shared context, direct scarce human attention, and make parallel CLI-agent work
> understandable, verifiable, and steerable.

Agents and their harnesses own planning, spawning, scheduling, and execution. Tenon owns
the operator's situation awareness: what changed, what needs judgment now, what evidence
supports a claim, where work is blocked or conflicting, and what can safely wait.

**MEDIUM:** Evidence-linked context compression can raise practical human fan-out, but the
effect size and correct interface are unproven. Tenon should treat this as an experiment
with explicit failure criteria, not as a completed product claim.

## Why more panes do not solve the problem

A multiplexer increases the number of visible processes. It does not automatically reduce
the cost of reconstructing each process's goal, decisions, state, and evidence.

Three established findings explain why that distinction matters:

1. **Working memory is bounded (`HIGH`).** Cowan's review argues for a limited focus of
   attention rather than unlimited active context. It does not justify a fixed “number of
   agents” limit, but it does reject the premise that adding visible streams scales human
   comprehension linearly.
2. **Task switching leaves attention residue (`HIGH`).** Leroy found that unfinished work
   impairs performance on a subsequent task. Re-entering an agent thread therefore has a
   real cognitive cost beyond the time spent clicking between panes.
3. **Automation can reduce situation awareness (`HIGH`).** Endsley and Kiris found an
   out-of-the-loop performance problem when operators supervise automation.

**MEDIUM transfer hypothesis:** In software-agent supervision, a compact status badge
without inspectable evidence may create the same failure mode: confidence without enough
understanding to diagnose or intervene.

These findings support a design target, not a direct proof of Tenon's proposed UI.
Software agents differ from laboratory memory tasks and supervisory-control systems.
Tenon must validate the transfer empirically.

## A fan-out lens

Human-robot interaction research models **fan-out** using two quantities:

- **neglect time:** how long an autonomous unit operates before human attention is needed;
- **interaction time:** how long the human needs to restore acceptable understanding and
  performance when attention returns.

For homogeneous independent units, the rough model is:

```text
estimated fan-out ≈ 1 + neglect time / interaction time
```

**MEDIUM:** This homogeneous, independent-unit model is an estimated upper-bound lens, not
a safety guarantee or a validated capacity formula for CLI agents. Agent tasks are
heterogeneous, coupled, bursty, and capable of producing misleading summaries. False
alarms, dependencies, risk, and context-switch overhead all lower the practical limit.

The model nevertheless identifies two legitimate Tenon levers:

1. increase safe neglect time by exposing explicit state transitions and escalating real
   blockers promptly;
2. reduce interaction time with fresh, evidence-linked context capsules and direct return
   to the originating terminal state.

The product metric is therefore not “agents open.” It is **verified outcomes per minute of
human attention at an acceptable error rate**.

## The operator's five questions

Tenon's supervision surface should let a person answer these questions without reading
every transcript:

1. **What materially changed since I last looked?**
2. **What requires my judgment now?**
3. **What is the agent claiming, and what evidence supports it?**
4. **Which work is blocked, drifting, stale, or in conflict?**
5. **What can I safely ignore for now?**

The raw terminal transcript, diff, command result, and test receipt remain the evidence.
Generated summaries are navigation aids. They do not become an independent source of
truth.

## Proposed wedge: Attention Inbox

**MEDIUM recommendation:** Start with an Attention Inbox for three to five independently
running Claude Code or Codex PTYs. The experiment has three elements.

### 1. Explicit attention signals

Prefer structured, inspectable states such as:

- `needs_input`
- `approval`
- `failed`
- `ready_for_review`
- `completed`

The first version should prioritize explicit signals over inferred emotional tone or
free-form guesses about urgency. Agent-specific adapters can normalize source data while
preserving the original source and timestamp.

### 2. Evidence-linked context capsules

Each capsule should contain:

- the workstream goal;
- the material delta since the operator last viewed it;
- the current claim, blocker, or requested decision;
- the next expected action;
- links to the originating transcript position, diff, command and exit code, or test
  receipt;
- source, timestamp, and freshness state.

Every material claim must be reversible back to an exact evidence anchor with source
identity, location, content hash, capture time, and freshness. Capsules must distinguish an
agent-reported assertion from a verified observation. For example, transcript text saying
“tests passed” remains an agent assertion until a direct command receipt or artifact
supports it. A stale capsule must say that it is stale.

### 3. Exact re-entry

Selecting an item should return the operator to the originating workspace, pane, process,
and relevant evidence. The terminal process remains owned by its PTY session; the Inbox
does not replace the CLI or reinterpret agent execution.

## Product and architecture boundaries

This direction preserves Tenon's terminal-first architecture:

- CLI agents continue to run as ordinary processes in real PTYs.
- Agent harnesses remain responsible for their own execution semantics.
- Tenon observes, organizes, and presents supervision information.
- Plugins provide adapters and product extensions through Tenon's governed public
  contracts.
- Raw evidence remains available even when an adapter or generated summary fails.

The plugin runtime is enabling architecture: it allows Tenon to support changing agent
harnesses, evolve supervision experiments, and govern provenance without baking every
integration into the host. The customer value is faster, safer human judgment.

Any implemented interaction must still follow
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md). This
research intentionally does not invent a new public `tenon` path, intent, event, resource,
facility, audience, or lifecycle operation.

## Falsifiable product experiment

Compare the Attention Inbox with raw Tenon tabs over at least 20 real intervention events.
Use tasks that include a mix of input requests, failures, review handoffs, completions, and
one or more cross-workstream conflicts.

Initial success thresholds:

- median context-reorientation time improves by at least 30%;
- missed explicit blockers do not increase;
- fewer than 10% of Inbox items are false-attention items;
- traceability error is zero: every material capsule claim resolves to its exact source
  anchor, hash, and freshness state;
- unsupported-claim error is zero in the reviewed sample: the cited evidence entails the
  claim at the authority level shown to the operator;
- verified outcomes per human-attention minute improve;
- outcome quality does not decline as the number of concurrent workstreams increases.

**MEDIUM:** These thresholds are deliberately demanding but provisional. A pilot should
calibrate them before they become a release gate.

Failure criteria:

- If notifications provide the same benefit as capsules, narrow the product to reliable
  agent-aware terminal signaling.
- If users still reopen complete transcripts to regain trust, the capsule lacks necessary
  evidence or context.
- If inferred urgency produces excessive false attention, retain explicit states and remove
  that inference.
- If operator errors increase with concurrency despite faster navigation, Tenon is
  optimizing switching rather than supervision.

## Source integrity and security boundary

**HIGH:** Terminal state is not automatically a complete semantic transcript, and a
provider's transcript or tool output can contain attacker-influenced instructions.
Adapters should prefer explicit, typed lifecycle hooks and preserve source confidence.
Viewport or free-form transcript inference is a low-confidence fallback, never the
authority for goal, completion, or approval state.

Evidence summarization must use a read-only broker with no tools, no side effects, and no
ambient secret access. The broker receives an immutable, user-selected minimum evidence
bundle and, if a model is configured, may send it only to that configured provider. Model
output is an untrusted candidate: deterministic validation must require exact source
anchors, hashes, and freshness before display, and the UI must preserve the distinction
between reported assertions and verified observations. Raw sources remain local and
inspectable. The historical threat analysis in
[`research-plugin-runtimes.md`](research-plugin-runtimes.md) is useful threat evidence;
any implementation needs a current normative ingestion threat model and authenticated,
typed lifecycle signals.

## Implementation status

**HIGH:** Tenon implements the native terminal workspace, spatial canvas,
libghostty surfaces, built-in slot surfaces, and plugin runtime described in
[`../VISION.md`](../VISION.md). The Attention Inbox, evidence-linked context capsules,
structured signal ingestion, and fan-out measurements in this document are product targets;
they are not claims about current runtime support.

## Primary sources

### Current market

- [OpenAI — Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/)
- [OpenAI — How agents are transforming work](https://openai.com/index/how-agents-are-transforming-work/)
- [GitHub — Introducing Agent HQ](https://github.blog/news-insights/company-news/welcome-home-agents/)
- [Warp — A single pane of glass for managing all of your cloud agents](https://www.warp.dev/blog/multi-harness-cloud-agent-orchestration)
- [Warp — Introducing Oz](https://www.warp.dev/blog/oz-orchestration-platform-cloud-agents)

### Human attention and supervisory control

- Nelson Cowan, [“The magical number 4 in short-term memory: A reconsideration of
  mental storage capacity”](https://doi.org/10.1017/S0140525X01003922), *Behavioral and
  Brain Sciences*, 2001.
- Sophie Leroy, [“Why is it so hard to do my work? The challenge of attention residue when
  switching between work tasks”](https://doi.org/10.1016/j.obhdp.2009.04.002),
  *Organizational Behavior and Human Decision Processes*, 2009.
- Mica R. Endsley and Esin O. Kiris, [“The Out-of-the-Loop Performance Problem and Level of
  Control in Automation”](https://doi.org/10.1518/001872095779064555), *Human Factors*,
  1995.
- Michael A. Goodrich and Dan R. Olsen Jr.,
  [“Metrics for Evaluating Human-Robot Interactions”](https://scholarsarchive.byu.edu/facpub/1052/),
  2003.
- Jacob W. Crandall et al., [“Validating Human-Robot Interaction Schemes in Multitasking
  Environments”](https://doi.org/10.1109/TSMCA.2005.850587), *IEEE Transactions on
  Systems, Man, and Cybernetics*, 2005.
