# Your first workspace

This walks from an empty window to two agents working side by side, with you able
to see both. It assumes Tenon and your agent CLIs are [installed](/guide/install)
and authenticated.

## 1. Open a directory as a workspace

A **workspace is a directory**. Launch Tenon from the project you want to work
in, and that directory becomes the workspace and the working directory of every
terminal in it:

```sh
cd ~/projects/my-app
open -a Tenon .
```

The left sidebar lists your workspaces and is how you switch between them. The
window opens with one tab holding one terminal that fills the whole canvas.

::: tip Starting somewhere specific
`TENON_WORKSPACE_PATH=/path/to/project` selects the initial workspace
explicitly. Without it, Tenon picks a meaningful launch directory and falls
back to your home directory when LaunchServices starts it at `/`.
:::

## 2. Split the canvas

Press `⌘D`. The terminal becomes two panes side by side. Press `⇧⌘D` on one of
them to stack a third above or below it.

What you are splitting is a **12 × 12 logical grid** that belongs to the tab.
Panes occupy whole rectangles on it, so they always tile — there is no free
floating and no overlap.

Drag any edge or corner to resize; shared edges move coupled neighbours where
the layout allows. Grab a pane's header and drag it: drop it on another pane to
**swap** their two rectangles, or drop it on empty grid to **move** it there.
If a drag goes wrong, press `Escape` — the layout returns to exactly what it was
when you pressed the pointer down, with nothing half-applied.

## 3. Start an agent in each pane

No extra agent mode is needed. Each pane is a real PTY running your shell, so
start an installed and authenticated agent the way you always do:

```sh
claude          # in the left pane
codex           # in the right pane
```

Tenon does not wrap, proxy, or intercept them. Their keybindings, their colors
and their TUI behave exactly as they do in any terminal, because it is a real
libghostty surface underneath.

## 4. Let the agents label themselves

Here is the first thing Tenon adds. Every terminal it opens exports
`TENON_PANE_ID` and `TENON_SOCKET_PATH`, so the process inside a pane knows
which pane it is and can talk to the app hosting it.

Tell your agents to name their own tab when they start a task:

```sh
tenon-cli rename "Fixing the token refresh race"
tenon-cli rename          # clears it back to the content-derived title
```

Now the tab strip tells you what each workstream is *about*, instead of showing
you three tabs called `fish`. The title identifies the workstream without making
you reopen each terminal.

::: warning `rename` needs a current build
`rename` is in the source tree. If your installed Tenon predates it,
`tenon-cli rename` answers `unknown command` — send the intent it compiles to
instead: `tenon-cli intent send workspace.pane.title.set.v1 --input
'{"title":"…"}'`.
:::

## 5. Let an agent ask you something

An agent that hits a decision it should not make alone has two bad options: stop
and wait for you to notice, or guess. Tenon gives it a third:

The question appears against that pane with its choices, and the call returns
the value you picked. It writes nothing into anyone's terminal, and the record
belongs to the pane — so it survives the agent's own context being compacted.
For the complete command and payload, see [Running agents](/guide/running-agents#let-agents-ask-instead-of-stalling).

Notice that **`evidence` is required and must have at least one entry**. The
schema requires an artifact that the person can review before choosing.

`timeoutMs` is capped at 55 000. If nobody answers in time the call fails
closed rather than picking a default — an unanswered question must not become
a silent yes. See [`agent.ask.v1`](/reference/intents/agent-ask-v1) for the full
contract, or ask your own build with `tenon-cli intent describe agent.ask.v1`.

## 6. Open the things you keep switching away for

Press `⌘K` for the command palette, or use **Add pane**. A pane can hold a
terminal, a file, the working-tree changes, a local web preview, or a view a
plugin contributes. Putting the diff beside the agent that produced it is the
cheapest version of "check the claim before you believe it".

## 7. Close and reopen

Quit Tenon and start it again. Your workspaces, tabs, pane layout, pane content,
titles and selection all come back.

The **processes do not**, and that is deliberate. A restored terminal pane keeps
its identity, rectangle, title and working directory, then launches a fresh
shell when it is first shown. Tenon never serializes a process and pretends to
resurrect it, because a process that looks restored but is not is worse than an
empty pane.

## Where to go next

- **[Workspaces, tabs, panes](/guide/workspaces-tabs-panes)** — the model in full.
- **[Keyboard and pointer](/guide/keyboard)** — every control on one page.
- **[Agent Lens](/guide/agent-lens)** — read an agent's session as a timeline.
- **[Driving Tenon from a terminal](/guide/cli)** — everything `tenon-cli` can do.
