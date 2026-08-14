---
title: terminal.wait.v1
description: "Waits for one bounded terminal condition and returns exactly one result."
---

# `terminal.wait.v1`

**Wait for terminal condition**

Waits for one bounded terminal condition and returns exactly one result. Continuous output is a separate future resource stream.

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
| `condition` | yes | `"exit" \| "tui-idle" \| "command-finished"` | — |
| `timeoutMs` | no | `integer` | range 1–55000 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `condition` | yes | `"exit" \| "tui-idle" \| "command-finished"` | — |
| `met` | yes | `boolean` | — |
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.wait.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.wait.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.wait.v1`.
