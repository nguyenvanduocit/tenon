---
title: agent.command.v1
description: "Returns the command line that starts the named agent the way this person runs it, ready for terminal.open.v1."
---

# `agent.command.v1`

**Compose an agent command line**

Returns the command line that starts the named agent the way this person runs it, ready for terminal.open.v1. Give it a prompt to open the agent on that work, or a session to continue: the agent that recorded a session resumes it the provider's own way, and any other agent is handed a prompt naming the session's transcript so it reads the content itself. It starts nothing and writes nothing.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `read` — Reads state and changes nothing. |
| Confirmation | `never` — Runs without asking. |
| Idempotency | `none` |
| Leaves the machine | no |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `agent` | yes | `string` | length 1–64 |
| `includeUserOptions` | no | `boolean` | — |
| `prompt` | no | `string` | length 0–32768 |
| `session` | no | `{agent, sessionID, transcriptPath?}` | — |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `agent` | yes | `string` | length 1–64 |
| `arguments` | yes | `string[]` | items 0–64 |
| `commandLine` | yes | `string` | length 0–49152 |
| `handoff` | yes | `boolean` | — |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.agent-handoff-unresolved`
- `dev.tenon.core.agent-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("agent.command.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send agent.command.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe agent.command.v1`.
