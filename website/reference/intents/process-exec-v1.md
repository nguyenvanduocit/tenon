---
title: process.exec.v1
description: "Runs an unsandboxed local process with the current user's filesystem and network authority."
---

# `process.exec.v1`

**Execute process**

Runs an unsandboxed local process with the current user's filesystem and network authority. Requires the caller's standing consent; output is bounded.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Effect | `write` — Changes state. |
| Confirmation | `policy` — May require a live confirmation, decided by policy and the caller’s audience. |
| Idempotency | `none` |
| Leaves the machine | yes |
| Provided by | `dev.tenon.core` |
| Contract class | `sealed` |

## Input

| Property | Required | Type | Constraints |
|---|---|---|---|
| `arguments` | yes | `string[]` | items 0–1024 |
| `command` | yes | `string` | length 1–16384 |
| `environment` | no | `{name, value}[]` | items 0–256 |
| `standardInput` | no | `{kind, text}` | — |
| `timeoutMs` | no | `integer` | range 1–60000 |
| `workingDirectory` | yes | `string` | length 1–16384 |


## Output

| Property | Required | Type | Constraints |
|---|---|---|---|
| `exitCode` | yes | `integer` | range -2147483648–2147483647 |
| `standardError` | yes | `{byteCount, kind, text}` | — |
| `standardOutput` | yes | `{byteCount, kind, text}` | — |
| `termination` | yes | `"exited" \| "signalled"` | — |


## Errors it can return

These are this contract’s own failures, on top of the lifecycle errors every
intent can settle with. See [Errors](/reference/errors).

- `dev.tenon.core.process-launch-failed`
- `dev.tenon.core.process-output-unavailable`
- `dev.tenon.core.process-timed-out`

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("process.exec.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send process.exec.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe process.exec.v1`.
