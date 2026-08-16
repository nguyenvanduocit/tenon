# Agent Lens

Agent Lens turns a live agent pane into something you can scan in seconds
instead of scrolling. It is a second *presentation mode* over a terminal pane
whose PTY is already running — not a second pane, and not a transcript viewer
bolted on the side.

## Session and Terminal are the same pane

A pane running a supported agent offers two modes:

- **Session** — one chronological narrative of what the agent is doing.
- **Terminal** — the raw libghostty surface, exactly as it always was.

Switching between them may detach the terminal renderer, but it does **not**
replace the terminal surface, restart the foreground process, replay input, or
discard scrollback. You are looking at one pane two ways. Terminal is always
available as exact re-entry.

## What Session shows you

The default projection is built to answer four questions fast:

1. What is this agent trying to accomplish?
2. What is it doing right now?
3. Does it need my judgment?
4. What materially happened, in order?

Everything lives on **one evidence-ordered timeline**: conversation, tool
lifecycles, subagent work, interaction requests and diagnostics. Session does
not split "chat" from "activity", because the thing you are reconstructing is a
single sequence of events.

Some deliberate choices in how it condenses:

- **Instructions are context, not events.** System, developer, project and skill
  instructions stay collapsed in the inspector unless you ask for them. They
  explain the agent; they are not things it did.
- **Finished work folds, it does not vanish.** Adjacent tool, plan and change
  facts collapse into one quiet row, and expanding it returns every original
  fact with its stable ID. Nothing is deleted to make the view tidy.
- **Pending questions and approvals are promoted** into the session summary.
  Those are the rows that need you.
- **Evidence is one action away**, and the timeline itself shows only what you
  need to scan safely: authority and freshness.
- **Reported and observed are distinguished.** An agent saying it ran the tests
  and a test run Tenon watched happen are not the same claim, and Session does
  not flatten them into one.

A narrow pane reflows Markdown tables into labeled fields rather than making
you scroll sideways — a supervision surface that needs horizontal scrolling is
not doing its job.

## Answering a question from Session

When the agent is showing a question, you can answer it in Session. Tenon sends
one provider-specific selection frame — Claude receives the option hotkey plus
Return, Codex receives only the committing hotkey — into the live TUI. It is the
same keystroke you would have typed, delivered to the same process.

## Clicking a file the agent cited

When an agent writes a path in its prose, that path is resolved and clickable:
the click opens the file in a pane beside it. The claim and its cited file stay
in the same window, one click apart.

## When it cannot bind a session

Agent Lens needs an **authoritative** binding between the pane and the
provider's own session record. It will not guess.

Specifically, it rejects a stale process, a child-agent fact, a mismatched
process group, or a rotated terminal-surface token. When binding is unavailable
it **degrades explicitly**: it tells you it is degraded and hands you Terminal,
which was the exact evidence path all along.

This is the correct failure. The newest transcript in a directory, picked by
modification time, is a guess — and a supervision tool that guesses which
session you are looking at is worse than one that admits it does not know.

::: tip Codex needs its hook installed
For Codex, check that the additive hook was installed in the active
`CODEX_HOME`, that the provider approved it, and that the transcript is a
current-user regular JSONL file under `CODEX_HOME/sessions`. See
[Troubleshooting](/guide/troubleshooting#agent-lens-says-it-is-degraded).
:::

## What Agent Lens is not

It is not a complete transcript renderer, and it does not replace the terminal
as the source of truth. It is a projection whose value is that it is *shorter*
than the transcript while still resolving to it.

It is also **not the Attention Inbox**. Agent Lens works on one session at a
time. The cross-session inbox — explicit states like `needs_input`, `approval`,
`failed`, `ready_for_review` across every workstream, with a "since you last
looked" capsule — is described in the vision and is not built yet.

Agent Lens adds no public plugin path, no core intent, no audience and no
control-plane operation. It is host-internal, which is why a plugin cannot
reach into it.
