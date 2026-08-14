---
title: filesystem.file.read.v1
description: "Returns one bounded inline UTF-8 page of the file, split only on character boundaries."
---

# `filesystem.file.read.v1`

**Read file**

Returns one bounded inline UTF-8 page of the file, split only on character boundaries. Omit the cursor to start at the first byte; pass the cursor from the previous page to continue. A null cursor in the result means the page reached the end of the file. The cursor addresses bytes by offset and carries the file identity it was issued against, so a file whose size or modification time changed between pages, or while the page itself was being read, returns invalidated instead of bytes that may have shifted.

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
| `cursor` | no | `string` | length 0–96 |
| `path` | yes | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `content` | yes | `{byteCount, kind, text}` | — |
| `cursor` | yes | `string \| null` | — |
| `invalidated` | yes | `boolean` | — |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.content-not-text`
- `dev.tenon.core.filesystem-failed`
- `dev.tenon.core.path-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("filesystem.file.read.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send filesystem.file.read.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe filesystem.file.read.v1`.
