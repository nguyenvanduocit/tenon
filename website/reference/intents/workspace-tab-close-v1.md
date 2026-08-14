---
title: workspace.tab.close.v1
description: "Closes the tab identified by invocation scope, with every pane under it."
---

# `workspace.tab.close.v1`

**Close tab**

Closes the tab identified by invocation scope, with every pane under it. A workspace always keeps one tab, so closing its only tab is refused rather than emptied.

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
- `dev.tenon.core.tab-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.tab.close.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.tab.close.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.tab.close.v1`.
