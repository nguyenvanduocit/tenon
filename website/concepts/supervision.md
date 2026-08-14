# Supervision, not orchestration

Tenon does not plan work, decompose tasks, spawn agents, schedule them, or drive
their keyboards. This is the product's central refusal, and everything else
makes more sense once you accept it.

## The argument

Agents scale execution. You can start five right now, and ten next year for the
same effort. Nothing about that is hard any more.

What has not scaled is the person who decides whether their output is correct.
Every additional workstream costs the same scarce thing: attention to notice it
needs you, and reorientation time to re-enter it after looking away.

So the useful limit on parallel agent work is not *how many agents can execute*.
It is **how many workstreams one person can supervise and then accurately
re-enter**. A tool that adds orchestration adds capacity to the side that is
already abundant.

Tenon aims at the other side.

## What that rules out

| Not in Tenon | Why |
|---|---|
| Task decomposition and planning | Your harness has the context to do it better |
| Spawning and scheduling agents | Orchestration; it belongs to the harness |
| Driving another agent's keyboard | No intent exists for it — deliberately |
| A fan-out primitive | The building block of the thing it refuses to be |
| Remote and browser control | It is a local, native macOS app |

The absence of an intent for "type into that agent's pane on its behalf" is not
an oversight to be fixed by a future release. It is the boundary.

## What that buys

Because Tenon does not own execution, agents keep their native harness behavior
exactly. Their planning, their tools, their prompts, their TUI, their
keybindings — unmodified, in a real PTY. Nothing is replayed or approximated.

That matters for a boring, decisive reason: **agent tooling changes faster than
any host can follow.** A supervisor that re-implemented agent execution would
need to chase every harness change forever, and would be wrong in between. One
that leaves execution alone is still correct when the harness updates itself
tomorrow.

## What Tenon does own

The operator's situation awareness, and the return path from a claim to the
thing that actually happened.

Concretely, five questions it should answer without you reopening every
transcript:

1. What materially changed since I last looked?
2. What requires my judgment now?
3. What is the agent claiming, and what evidence supports it?
4. Which work is blocked, drifting, stale, or in conflict?
5. What can I safely ignore for now?

Question 5 is the one people skip and the one that pays most. A supervision
surface that surfaces everything has not reduced your load; it has moved the
sorting problem into a new window.

## How success is measured

The direction is falsifiable, which is unusual enough to state plainly. The
first supervision experiment must:

- reduce median context-reorientation time by **at least 30%**;
- preserve or improve explicit-blocker detection;
- keep false-attention items **below 10%**.

And every material claim in a capsule must resolve to an exact source identity,
immutable location and hash, capture time, freshness and authority level.
Traceability errors — and claims unsupported by their own cited evidence — are
counted separately, with **zero accepted** in the reviewed sample.

Those numbers are targets for work that is not built yet. The
[Attention Inbox](/concepts/#what-is-built-and-what-is-not) is still a product
experiment; [Agent Lens](/guide/agent-lens) is the shipped step toward it, and
it works on one session at a time.

## Where this shows up in the product

- An agent can [ask a question](/guide/running-agents#let-agents-ask-instead-of-stalling)
  with typed choices, and **must attach evidence** to do it.
- Agent Lens **promotes pending questions and approvals** into the summary, and
  folds finished work into a quiet row rather than deleting it.
- Agent Lens **degrades explicitly** when it cannot bind a session with
  authority, rather than guessing which transcript you are looking at.
- Tabs can be [renamed by the agent working in them](/guide/running-agents#let-agents-label-their-own-tab),
  because choosing what to look at is the operator's first act.
