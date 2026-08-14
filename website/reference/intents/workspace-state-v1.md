---
title: workspace.state.v1
description: "Returns a bounded structural snapshot of workspaces, tabs, and panes."
---

# `workspace.state.v1`

**Read workspace state**

Returns a bounded structural snapshot of workspaces, tabs, and panes.

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
| `limit` | no | `integer` | range 1–256 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `activePaneID` | yes | `string \| null` | — |
| `activeWorkspaceID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `nextCursor` | yes | `string \| null` | — |
| `nodes` | yes | `{activeTabID, id, kind, name, path, selected} \| {activePaneID, id, kind, selected, workspaceID} \| {content, frame, id, kind, tabID}[]` | items 0–256 |
| `snapshotID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.cursor-invalidated`
- `dev.tenon.core.workspace-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.state.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.state.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.state.v1`.
