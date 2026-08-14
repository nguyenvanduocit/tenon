---
title: filesystem.file.write.v1
description: "Atomically replaces the file with bounded inline UTF-8 content."
---

# `filesystem.file.write.v1`

**Write file**

Atomically replaces the file with bounded inline UTF-8 content. One call with no cursor publishes in a single atomic step. A body larger than one page is staged: pass commit false to open a host-owned staging beside the target and receive a cursor, send each following page with the previous cursor, and let the final page commit (the default) to atomically publish the staged bytes over the target. The target never holds intermediate content; only the committing rename is observable. Staged bytes, concurrent stagings, and staging lifetime are bounded; an abandoned staging is reclaimed and its cursor — like any forged or out-of-sequence cursor — fails closed as invalid input.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `write` — Changes state. |
| Confirmation | `policy` — May require a live confirmation, decided by policy and the caller’s audience. |
| Idempotency | `none` |
| Leaves the machine | no |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `commit` | no | `boolean` | — |
| `content` | yes | `{kind, text}` | — |
| `cursor` | no | `string` | length 0–96 |
| `path` | yes | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `cursor` | no | `string` | length 0–96 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.filesystem-failed`
- `dev.tenon.core.path-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("filesystem.file.write.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send filesystem.file.write.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe filesystem.file.write.v1`.
