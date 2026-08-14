---
layout: home

hero:
  name: Tenon
  text: Supervise agents you did not have to orchestrate
  tagline: >
    A native macOS terminal workspace for running several CLI coding agents at
    once. They keep their own harness and their own PTY. You keep the judgment.
  image:
    src: /hero.svg
    alt: The Tenon mark — a peg through a mortise
  actions:
    - theme: brand
      text: Install Tenon
      link: /guide/install
    - theme: alt
      text: What Tenon is
      link: /guide/what-is-tenon
    - theme: alt
      text: Write a plugin
      link: /plugins/quickstart

features:
  - title: A real terminal, first
    details: >
      Every pane is a libghostty surface with native keyboard, mouse, clipboard,
      focus and resize. Agents run in real PTYs under their own CLI. Nothing is
      re-implemented, proxied, or replayed.
    link: /concepts/spatial-canvas
    linkText: The spatial canvas

  - title: Five questions, one window
    details: >
      What changed since I last looked, what needs me now, what evidence backs
      that claim, what is blocked or drifting, and what can safely wait.
    link: /concepts/supervision
    linkText: Supervision, not orchestration

  - title: Panes that stay put
    details: >
      A 12 × 12 grid per tab. Split, drag to swap, resize any shared edge, press
      Escape to undo the whole gesture. A pane keeps its process through every
      move, tab switch and relaunch.
    link: /guide/workspaces-tabs-panes
    linkText: Workspaces, tabs, panes

  - title: Agents can ask instead of stalling
    details: >
      An agent in a pane can put a real question with typed choices in front of
      you, and read back what you picked — without writing into anyone's
      terminal.
    link: /guide/running-agents
    linkText: Running agents

  - title: One governed way in
    details: >
      51 canonical contracts. Every finite request from a plugin, the CLI or an
      agent is checked against audience, declared uses, capability and scope
      before it runs. Naming an intent never grants authority.
    link: /reference/intents/
    linkText: All intents

  - title: Extensible without a private door
    details: >
      Plugins are a directory with a manifest and a main.js, hot-reloaded on
      save. They see exactly one global. Bundled plugins get the same surface
      third-party ones do.
    link: /plugins/
    linkText: Writing a plugin
---

## Why this exists

You can already run five coding agents at once. The limit was never how many
processes your machine will start — it is how many workstreams one person can
follow, and then accurately re-enter after looking away.

Tenon is built for that limit. It does not plan work, spawn agents, schedule
them, or drive their keyboards; those belong to the harness you already chose.
It gives their operator one window where parallel work stays legible, and every
condensed claim keeps a direct path back to the transcript, diff, command
result, or test receipt it came from.

```sh
# Tenon opens and behaves like a terminal. Start there.
⌘T          new tab — one full-size terminal
⌘D  ⇧⌘D     split the active pane left/right, top/bottom
⌘K          the command palette
```

Each terminal Tenon opens knows which pane it is, so the agent inside it can
label its own tab, ask you a question, or open a file beside itself:

```sh
tenon-cli rename "Fixing the token refresh race"
tenon-cli intent send agent.ask.v1 --input '{"question":"Ship it?"}'
```

::: warning Pre-alpha
Tenon is pre-alpha and its interfaces still change between builds. Releases are
marked pre-release for that reason. The terminal workspace, spatial canvas,
plugin and intent runtime, CLI, command palette, automations and Agent Lens are
implemented; the cross-session Attention Inbox and evidence-linked context
capsules described in the vision are not yet built.
:::
