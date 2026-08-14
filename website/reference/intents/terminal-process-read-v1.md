---
title: terminal.process.read.v1
description: "Names the PTY device and the foreground process of the terminal identified by invocation scope."
---

# `terminal.process.read.v1`

**Read terminal process identity**

Names the PTY device and the foreground process of the terminal identified by invocation scope. Both are null for a pane whose surface has not materialised and for one whose shell has exited, so an absent answer is stated rather than implied. This is process identity, not resource telemetry: no CPU, memory, or footprint figure crosses this contract.

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
| `foregroundPID` | yes | `integer \| null` | — |
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `ttyName` | yes | `string \| null` | — |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.process.read.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.process.read.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.process.read.v1`.
