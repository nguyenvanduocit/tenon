# Concepts

These pages explain *why* Tenon is shaped the way it is. You do not need them to
use it — [the guide](/guide/what-is-tenon) is enough for that. Read them when a
design decision looks arbitrary and you want to know whether it is.

## The short version

Tenon is built around one claim: **the bottleneck in parallel agent work is
human judgment, not execution.** Agents scale execution already. Nothing scales
the person deciding whether their output is right.

Everything else follows from taking that seriously.

- Because judgment is the scarce resource, Tenon **supervises rather than
  orchestrates** — it will not plan, spawn, schedule or drive agents, since
  doing that adds execution capacity to a system that is not execution-bound.
  → [Supervision, not orchestration](/concepts/supervision)

- Because you cannot supervise what you cannot see at once, panes are a **fixed
  tiling grid** with stable identity, not floating windows or a re-implemented
  terminal. → [The spatial canvas](/concepts/spatial-canvas)

- Because a summary you cannot check is a rumour, every condensed claim keeps
  **a path back to its evidence**, and reported facts are distinguished from
  observed ones. → [Evidence and claims](/concepts/evidence)

- Because agent tooling changes faster than a host can, the product is
  **extensible through one public boundary** that bundled and third-party
  plugins share, with no private door.
  → [The plugin boundary](/concepts/plugin-boundary)

- Because an extension surface without a policy is a liability, every finite
  cross-owner request goes through **one governed contract path** with
  fail-closed checks. → [The intent bus](/concepts/intent-bus)

## The two constraints underneath

Two engineering commitments keep the product changeable rather than merely
correct today.

**AI-writable APIs.** A language model should be able to read the docs and write
a working plugin on the first try. One async shape on every surface; load-time
errors that suggest what you meant instead of returning `undefined` silently.
This is not decoration — the people extending an agent-supervision tool are
frequently agents.

**Replaceable plugins.** Any plugin can be disabled, reloaded or replaced
without corrupting host state, and the terminal workspace stays useful with none
installed. A plugin system whose failure mode is a broken host is a plugin
system nobody edits.

## What is built and what is not

The site documents what exists. Two things in the vision are not shipped, and
saying so is part of the documentation being trustworthy:

| | Status |
|---|---|
| Terminal workspace, spatial canvas, catalog persistence, libghostty | implemented |
| Plugin runtime, intent bus, CLI, palette, automations | implemented |
| Agent Lens (one session, supported providers) | implemented; degrades explicitly |
| Cross-session Attention Inbox | **not built** — a product target |
| Evidence-linked context capsules | **not built** — a product target |
| Hard isolation boundary for untrusted plugin JavaScript | **open** |

That last row is the one to weigh before enabling a plugin you did not write.
See [Managing plugins](/guide/managing-plugins).
