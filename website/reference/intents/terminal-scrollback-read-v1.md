---
title: terminal.scrollback.read.v1
description: "Returns one bounded page of the pane's retained scrollback, oldest row first."
---

# `terminal.scrollback.read.v1`

**Read terminal scrollback**

Returns one bounded page of the pane's retained scrollback, oldest row first. Omit the cursor to start at the oldest retained row; pass the cursor from the previous page to continue. A null cursor in the result means the page reached the newest row. The cursor addresses rows by position, and the emulator exposes no stable row identity, so a page whose scrollback has changed size since the cursor was issued returns invalidated instead of rows that may have shifted.

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
| `cursor` | no | `string` | length 0–64 |
| `maxLines` | no | `integer` | range 1–2000 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `cursor` | yes | `string \| null` | — |
| `invalidated` | yes | `boolean` | — |
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `text` | yes | `string` | length 0–49152 |
| `totalRows` | yes | `integer` | range 0–100000 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.terminal-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("terminal.scrollback.read.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send terminal.scrollback.read.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe terminal.scrollback.read.v1`.
