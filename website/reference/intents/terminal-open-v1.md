---
title: terminal.open.v1
description: "Opens a new terminal tab in the scoped workspace and returns the id of the pane it created."
---

# `terminal.open.v1`

**Open a terminal in a new tab**

Opens a new terminal tab in the scoped workspace and returns the id of the pane it created. Unlike terminal.run.v1, which reuses a terminal already in scope, this always creates one — for work that needs a pane of its own, such as running an agent against a prompt. An omitted command opens an empty shell. The pane belongs to the workspace once created; the id identifies it for later intents and confers no ownership.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `write` — Changes state. |
| Confirmation | `policy` — May require a live confirmation, decided by policy and the caller’s audience. |
| Idempotency | `none` |
| Leaves the machine | yes |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `command` | no | `string` | length 0–49152 |
| `workingDirectory` | no | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.open.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.open.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.open.v1`.
