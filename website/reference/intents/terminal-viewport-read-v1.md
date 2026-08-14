---
title: terminal.viewport.read.v1
description: "Returns one bounded observation of the visible terminal identified by invocation scope."
---

# `terminal.viewport.read.v1`

**Read terminal viewport**

Returns one bounded observation of the visible terminal identified by invocation scope.

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
| `columns` | yes | `integer \| null` | — |
| `exited` | yes | `boolean` | — |
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `rows` | yes | `integer \| null` | — |
| `text` | yes | `string` | length 0–49152 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.viewport.read.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.viewport.read.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.viewport.read.v1`.
