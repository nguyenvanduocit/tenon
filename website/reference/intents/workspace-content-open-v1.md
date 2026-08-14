---
title: workspace.content.open.v1
description: "Opens content in the tab identified by invocation scope, reusing the pane that already shows this kind of content and otherwise splitting a pane."
---

# `workspace.content.open.v1`

**Open content**

Opens content in the tab identified by invocation scope, reusing the pane that already shows this kind of content and otherwise splitting a pane. Placement is host policy and never opens a tab.

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
| `content` | yes | `{kind} \| {kind} \| {kind} \| {kind} \| {kind, provider, sessionID, title?, transcriptPath} \| {kind, path} \| {kind, pluginID, viewID} \| {kind, originalPath?, path, repositoryPath, source, staged, title?, untracked} \| {fileName, kind, newText, oldText, source, title?}` | — |


## Output

Takes no properties — send `{}`.


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.content-unavailable`
- `dev.tenon.core.layout-unavailable`
- `dev.tenon.core.pane-not-found`
- `dev.tenon.core.tab-not-found`
- `dev.tenon.core.workspace-not-found`
- `dev.tenon.core.workspace-unavailable`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.content.open.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.content.open.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.content.open.v1`.
