---
title: url.open.v1
description: "Opens a web address with the trusted default or an explicitly approved provider."
---

# `url.open.v1`

**Open address**

Opens a web address with the trusted default or an explicitly approved provider. The trusted default hands it to the system; an approved provider may show it inside Tenon instead.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `write` — Changes state. |
| Confirmation | `policy` — May require a live confirmation, decided by policy and the caller’s audience. |
| Idempotency | `none` |
| Leaves the machine | yes |
| Provided by | `dev.tenon.core` |
| Contract class | `open` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `url` | yes | `string` | format `uri`, length 1–16384 |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.external-open-failed`
- `dev.tenon.core.invalid-url`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("url.open.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send url.open.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe url.open.v1`.
