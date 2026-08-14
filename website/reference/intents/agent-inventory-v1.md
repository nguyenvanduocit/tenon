---
title: agent.inventory.v1
description: "Returns the coding agents installed on this machine, each with the options this person habitually passes it, so a caller offers the same choices the Launcher does instead of inventing its own."
---

# `agent.inventory.v1`

**List the agents this person runs**

Returns the coding agents installed on this machine, each with the options this person habitually passes it, so a caller offers the same choices the Launcher does instead of inventing its own. It carries no executable path and no shell history — only the agent, how to name it to a person, and the options.

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

Takes no properties — send `{}`.


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `agents` | yes | `{arguments, habit, id, label}[]` | items 0–16 |


## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("agent.inventory.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send agent.inventory.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe agent.inventory.v1`.
