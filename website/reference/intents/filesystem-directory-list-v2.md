---
title: filesystem.directory.list.v2
description: "Returns one bounded, cursor-addressable page of directory entries."
---

# `filesystem.directory.list.v2`

**List directory**

Returns one bounded, cursor-addressable page of directory entries. `path` is the listed directory's resolved absolute path. Every entry carries `name` and `isDirectory`. `includeMetadata` defaults to false; setting it true adds `sizeBytes` and `modifiedAt` to every entry, each null when that entry's metadata could not be read. `sizeBytes` is the entry's own size as the filesystem reports it — for a directory that is the directory file itself, not its recursive content — and `modifiedAt` is an ISO-8601 UTC timestamp. Metadata costs one stat per entry, so a caller rendering names alone should leave it off.

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
| `cursor` | no | `string` | length 0–512 |
| `includeMetadata` | no | `boolean` | — |
| `limit` | no | `integer` | range 1–256 |
| `path` | yes | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `entries` | yes | `{isDirectory, modifiedAt?, name, sizeBytes?}[]` | items 0–256 |
| `nextCursor` | yes | `string \| null` | — |
| `path` | yes | `string` | length 1–16384 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.filesystem-failed`
- `dev.tenon.core.path-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("filesystem.directory.list.v2", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send filesystem.directory.list.v2 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe filesystem.directory.list.v2`.
