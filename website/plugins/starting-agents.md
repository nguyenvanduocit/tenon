# Starting agents

## Never build the command line

This is the rule. Ask which agents exist, then ask for the line:

```json
{
  "permissions": ["terminal.write"],
  "intents": {
    "uses": ["agent.inventory.v1", "agent.command.v1", "terminal.open.v1"]
  }
}
```

```js
const found = await tenon.intents.send("agent.inventory.v1", {})
// → { agents: [{ id: "claude", label: "Claude Code",
//               arguments: ["--model", "opus"], habit: "Model opus" }] }

const composed = await tenon.intents.send("agent.command.v1", {
  agent: "claude",
  prompt: "Do task T-104, described in .kanban/tasks/T-104-….md",
})

await tenon.intents.send("terminal.open.v1", {
  command: composed.value.commandLine,
  workingDirectory: workspacePath,
})
```

Three things you get for free by not doing this yourself:

- **An agent this machine does not have is never listed.** The inventory is what
  a menu should offer, so your UI cannot present something that will fail.
- **`arguments` are the options this person actually runs that agent with.**
  Your plugin's Start behaves like their own Start, including their model
  choice, without you knowing anything about it.
- **Composition owns the quoting and each provider's spelling.** Nothing you
  pass can become shell syntax. A prompt containing `; rm -rf /` is a prompt.

## Continuing a session

Name it, and the host works out who can resume it:

```js
await tenon.intents.send("agent.command.v1", {
  agent: "codex",
  session: {
    agent: "claude",                 // who recorded it
    sessionID: id,
    transcriptPath: path,            // required when the agents differ
  },
})
```

The agent that recorded a session resumes it its own way. **Any other agent is
handed a prompt naming the transcript**, so it reads the content itself rather
than pretending to inherit state it never had. The result's `handoff` field says
which happened.

Two failures worth handling explicitly:

| Situation | Error |
|---|---|
| Cross-agent request with no `transcriptPath` | `dev.tenon.core.agent-handoff-unresolved` |
| Naming an agent this machine lacks | `dev.tenon.core.agent-unavailable` |

The first is the interesting one: rather than starting an agent with no context
and letting it flail, the contract refuses. Pass `includeUserOptions: false` if
you want the plain agent without this person's own options.

## `tenon.agents.run`

`tenon.agents.run(request, sender = tenon.intents)` is a finite JavaScript
composition helper for the supervised run-to-result loop — open, wait, read.

It is **composition over your own declared intents**, not a new capability.
Declare all four before calling it:

```json
{
  "intents": {
    "uses": [
      "terminal.open.v1",
      "terminal.wait.v1",
      "terminal.write.v1",
      "terminal.scrollback.read.v1"
    ]
  }
}
```

It follows the same sender rule as anything else that sends. Pass the invoking
`call` and the whole run is scoped to that invocation's pane, capped at that
intent's deadline, and cancelled with it.

::: tip Omit the sender for a long run
A supervised run started from a short-deadline palette command should **omit**
the sender so it keeps its own budget. Inheriting a 5-second deadline would kill
it partway through.
:::

## What you cannot do

There is no intent for typing into another agent's pane on its behalf, answering
for it, or coordinating a fleet. `terminal.write.v1` exists and is pane-scoped,
but nothing composes it into orchestration for you.

That is [the product's boundary](/concepts/supervision), not a gap. Tenon
assumes the harness you already chose owns planning and spawning, and that the
scarce resource is the person watching.
