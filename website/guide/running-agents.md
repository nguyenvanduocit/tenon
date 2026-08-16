# Running agents in panes

Once an agent CLI is installed and authenticated, start it in a pane the same way
you would in any terminal:

```sh
claude
codex
```

Tenon does not wrap, proxy, replay or intercept them. What it adds is a way for
the agent inside a pane to *talk back to the workspace it is sitting in*, and
for you to see several of them at once without reading all of them.

## The pane knows what it is

Every Tenon terminal exports `TENON_PANE_ID` and `TENON_SOCKET_PATH`, so
`tenon-cli` inside a pane targets that pane by default with no arguments. This
is what makes the rest possible.

## Let agents label their own tab

You have more panes than attention. The tab strip is where you choose what to
look at, and a strip of tabs all called `fish` tells you nothing.

Ask your agents to name their work:

```sh
tenon-cli rename "Fixing the token refresh race"
tenon-cli rename          # clear it, back to the content-derived title
```

Keep it to a few words describing the *work*, not the current step, and clear it
on finish. This is worth putting in your agent's system prompt or project
instructions — an agent that renames its tab once per task costs one command and
saves you a transcript read every time you scan the window.

## Let agents ask instead of stalling

An agent that reaches a decision it should not make alone otherwise has two bad
options: stop silently and wait to be noticed, or guess and tell you afterwards.

`agent.ask.v1` is the third. It records a question against the pane, offers
typed choices, and returns the value chosen:

```sh
tenon-cli intent send agent.ask.v1 --input '{
  "question": "Two callers depend on the old signature. Break them or adapt?",
  "choices": [
    {"id": "break",  "label": "Break and fix callers", "value": "break"},
    {"id": "adapt",  "label": "Keep a compatible shim", "value": "adapt"}
  ],
  "evidence": [
    {"label": "caller A", "url": "file:///Users/me/app/src/auth.ts"},
    {"label": "caller B", "url": "file:///Users/me/app/src/session.ts"}
  ],
  "recipient": {"kind": "human"},
  "timeoutMs": 55000
}'
```

The operation has three important properties:

- **It writes nothing into anyone's terminal.** It schedules nothing and types
  nothing. The question is a record, not an injected keystroke.
- **The record belongs to the pane, not the asking process.** It survives the
  agent's context being compacted, and it is still there when you come back.
- **Evidence is required, minimum one entry.** You cannot ask for a judgment
  without attaching what the judgment should be made from.

`timeoutMs` is capped at 55 000 and fails closed when it expires. An unanswered
question does not quietly become a yes.

## Tenon will not drive an agent for you

This is a deliberate boundary, not a missing feature.

No intent lets one principal type into another agent's pane, start work on its
behalf, or answer for it. `terminal.write.v1` and `terminal.run.v1` exist and
are scoped to a pane, but the product does not orchestrate: it will not start
work for you, and there is no fan-out primitive to build a supervisor out of.

If you want agents coordinating agents, that belongs in the harness you already
chose. Tenon assumes you have one, and that the scarce resource is you.

## Starting an agent from a plugin

If you are automating "open a pane running agent X", **never build the command
line yourself**. Ask what exists, then ask for the line — quoting and each
provider's own spelling are the host's problem, and an agent this machine does
not have is never offered:

```js
const found = await tenon.intents.send("agent.inventory.v1", {})
const composed = await tenon.intents.send("agent.command.v1", {
  agent: "claude",
  prompt: "Do task T-104, described in .kanban/tasks/T-104-….md",
})
await tenon.intents.send("terminal.open.v1", {
  command: composed.value.commandLine,
  workingDirectory: workspacePath,
})
```

Full detail in [Starting agents](/plugins/starting-agents).

## Reading what an agent did

For supported providers, [Agent Lens](/guide/agent-lens) reads the agent's own
session record and renders one chronological timeline, with the raw evidence one
click away. When it cannot bind a session with authority it says so and hands
you the terminal, which is the exact evidence path anyway.
