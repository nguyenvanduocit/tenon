---
title: workspace.pane.title.set.v1
description: "Pins a display name to the pane identified by invocation scope, so an agent working there can say on its own tab what it is working on."
---

# `workspace.pane.title.set.v1`

**Set pane title**

Pins a display name to the pane identified by invocation scope, so an agent working there can say on its own tab what it is working on. An empty or whitespace-only title clears the pin and returns the pane to the title its content derives. Titles are collapsed to single spaces and truncated; a caller never chooses how wide a tab is.

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
| `title` | yes | `string` | length 0–4096 |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.pane-not-found`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.pane.title.set.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.pane.title.set.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.pane.title.set.v1`.
