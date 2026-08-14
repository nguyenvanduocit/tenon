---
title: file.reveal.v1
description: "Reveals a path in the system file browser."
---

# `file.reveal.v1`

**Reveal file**

Reveals a path in the system file browser.

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
| `path` | yes | `string` | length 1–16384 |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.external-open-failed`
- `dev.tenon.core.path-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("file.reveal.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send file.reveal.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe file.reveal.v1`.
