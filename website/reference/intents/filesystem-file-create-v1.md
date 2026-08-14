---
title: filesystem.file.create.v1
description: "Creates a new empty file and fails if the destination exists."
---

# `filesystem.file.create.v1`

**Create file**

Creates a new empty file and fails if the destination exists.

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
| `path` | yes | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `path` | yes | `string` | length 1–16384 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.filesystem-failed`
- `dev.tenon.core.path-already-exists`
- `dev.tenon.core.path-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("filesystem.file.create.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send filesystem.file.create.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe filesystem.file.create.v1`.
