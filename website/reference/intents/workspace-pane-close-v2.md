---
title: workspace.pane.close.v2
description: "Closes the pane identified by invocation scope."
---

# `workspace.pane.close.v2`

**Close pane**

Closes the pane identified by invocation scope. If that was a tab's final pane, the empty tab closes when another tab survives; a workspace's required final tab remains as an empty placeholder.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `destructive` —  |
| Confirmation | `policy` — May require a live confirmation, decided by policy and the caller’s audience. |
| Idempotency | `none` |
| Leaves the machine | no |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

Takes no properties — send `{}`.


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.close-refused`
- `dev.tenon.core.pane-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.pane.close.v2", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.pane.close.v2 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.pane.close.v2`.
