# What Tenon is

Tenon is a native macOS terminal workspace for people running several CLI coding
agents at the same time — Claude Code, Codex, or anything else that lives in a
terminal.

It is a supervision layer, not an orchestrator. Agents keep running in their own
harness, in real PTYs, with their own planning and their own tools. Tenon owns
the part nobody else does: the operator's situation awareness, and the return
path from a summary back to the thing that actually happened.

## The problem it is shaped around

Starting five agents is easy. Following five agents is not.

The binding constraint on parallel agent work is not how many processes your
machine will run. It is how many workstreams one person can hold, and — more
expensively — how long it takes to *re-enter* one after looking away. Every
context switch costs re-reading a transcript to find out what changed, whether
the agent is stuck, whether its claim is true, and what it needs from you.

Tenon exists to make that cost smaller. It should let you answer five questions
without reopening every transcript:

1. What materially changed since I last looked?
2. What requires my judgment now?
3. What is the agent claiming, and what evidence supports it?
4. Which work is blocked, drifting, stale, or in conflict?
5. What can I safely ignore for now?

## What it deliberately does not do

This list is as much the product as the feature list is.

| Tenon does not | Because |
|---|---|
| Plan work or decompose tasks | Your agent's harness already does, better, with its own context |
| Spawn, schedule, or supervise agents for you | That is orchestration; it belongs to the harness |
| Drive another agent's keyboard | No intent exists for it, on purpose |
| Re-implement the terminal | Panes are real libghostty surfaces with real PTYs |
| Replace the transcript with a summary | A summary that cannot be checked is a rumour |
| Run in a browser or over a network | It is a local, native macOS app |

If you want a tool that starts agents and coordinates them, Tenon is not it, and
will not become it. It assumes you already have one and are drowning in the
output.

## What it is made of

A **workspace** is a directory, and it appears in the left sidebar. Each
workspace owns **tabs**. A new tab opens as one terminal filling the whole
canvas. That canvas is a 12 × 12 grid of **panes** you can split, drag, swap and
resize; a pane can hold a terminal, a file, a diff, a web preview, or a view
contributed by a plugin.

A pane keeps its identity — and its live process — through every move, resize,
tab switch and workspace switch. Close the app and the layout comes back; the
processes do not, because Tenon never pretends to resurrect a process it did
not keep alive.

Around that sit four things worth knowing about early:

- **[Agent Lens](/guide/agent-lens)** reads a supported agent's own session
  record and renders one chronological timeline of what it did, with the raw
  evidence one click away. When it cannot bind a session with authority, it says
  so and hands you the terminal instead of guessing.
- **[The command palette](/guide/command-palette)** (`⌘K`) is where plugin-owned
  actions surface. It projects intent contracts; it is not a second, parallel
  command system.
- **[`tenon-cli`](/guide/cli)** is in every terminal Tenon opens, so a shell — or
  an agent inside a pane — can inspect and drive the workspace it is sitting in.
- **[Plugins](/plugins/)** are a directory with a `manifest.json` and a
  `main.js`, hot-reloaded when you save. They extend the workspace through one
  public boundary that bundled and third-party plugins share.

## Who it is for

People who supervise agents rather than watch a single one. If you run one agent
in one terminal and read every line it prints, a terminal you already like is a
better tool than this. Tenon starts paying at three concurrent workstreams and
keeps paying as that number grows.

## Where to go next

- **[Install](/guide/install)** — download, verify, and run it.
- **[Your first workspace](/guide/first-workspace)** — a walkthrough from empty
  window to two agents working side by side.
- **[Concepts](/concepts/)** — why the architecture looks like this, if you want
  the reasoning before the buttons.
