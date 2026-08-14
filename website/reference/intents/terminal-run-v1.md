---
title: terminal.run.v1
description: "Runs a command in the preferred visible terminal for the invocation scope."
---

# `terminal.run.v1`

**Run in terminal**

Runs a command in the preferred visible terminal for the invocation scope.

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
| `command` | yes | `string` | length 1–49152 |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.run.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.run.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.run.v1`.
