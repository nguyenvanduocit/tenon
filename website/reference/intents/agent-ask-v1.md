---
title: agent.ask.v1
description: "Records one evidence-backed question against the pane in scope and waits until its exact human or agent recipient chooses an offered typed value, or until the caller-declared deadline expires."
---

# `agent.ask.v1`

**Ask a bounded agent question**

Records one evidence-backed question against the pane in scope and waits until its exact human or agent recipient chooses an offered typed value, or until the caller-declared deadline expires. The record belongs to the pane rather than the asking process; this intent schedules and types nothing into a terminal.

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
| `choices` | yes | `{id, label, value}[]` | items 1–16 |
| `evidence` | yes | `{label, url}[]` | items 1–16 |
| `question` | yes | `string` | length 1–8192 |
| `recipient` | yes | `{kind} \| {kind, principalID, sessionRevision}` | — |
| `timeoutMs` | yes | `integer` | range 1–55000 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `questionID` | yes | `string` | format `uuid`, length 36–36, pattern-checked |
| `status` | yes | `"answered" \| "expired"` | — |
| `value` | yes | `boolean \| integer \| number \| string \| null` | — |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.agent-question-capacity`
- `dev.tenon.core.agent-question-pane-closed`
- `dev.tenon.core.agent-question-pending`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("agent.ask.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send agent.ask.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe agent.ask.v1`.
