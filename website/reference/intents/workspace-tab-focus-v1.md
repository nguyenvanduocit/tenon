---
title: workspace.tab.focus.v1
description: "Focuses the tab identified by invocation scope."
---

# `workspace.tab.focus.v1`

**Focus tab**

Focuses the tab identified by invocation scope.

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

Takes no properties — send `{}`.


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.tab-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.tab.focus.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.tab.focus.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.tab.focus.v1`.
