---
title: workspace.pane.owner.v1
description: "Returns the workspace and tab that own the named pane."
---

# `workspace.pane.owner.v1`

**Resolve the workspace that owns a pane**

Returns the workspace and tab that own the named pane.

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
| `paneID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `tabID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `workspaceID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `workspacePath` | yes | `string` | length 1–16384 |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.workspace-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.pane.owner.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.pane.owner.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.pane.owner.v1`.
