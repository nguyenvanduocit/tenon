---
title: workspace.pane.split.v1
description: "Splits the pane identified by invocation scope."
---

# `workspace.pane.split.v1`

**Split pane**

Splits the pane identified by invocation scope.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `write` — Changes state. |
| Confirmation | `never` — Runs without asking. |
| Idempotency | `none` |
| Leaves the machine | no |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `axis` | yes | `"horizontal" \| "vertical"` | — |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.layout-unavailable`
- `dev.tenon.core.pane-not-found`
- `dev.tenon.core.workspace-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.pane.split.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.pane.split.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.pane.split.v1`.
