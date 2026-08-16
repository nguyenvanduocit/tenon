# Errors

A failure arrives as `{ ok: false, error }` from `tenon.intents.send`, or as a
structured envelope from the CLI. There are three error layers; identify the
layer before choosing how to handle the failure.

```json
{
  "source": "control",
  "code": "intent_not_found",
  "message": "intent 'ui.toast.v1' is not callable by the CLI principal"
}
```

`source` is `control` or `intent`. Control failures are a **closed** set;
intent failures keep the kernel's own structured diagnostics rather than being
flattened into a handful of CLI-only cases.

An intent failure can also carry `details`, `retryable`, `retryAfterMs`, `outcome`,
`requestID` and `providerID`.

## Control-plane codes

The complete set. If your `source` is `control`, it is one of these:

| Code | Means |
|---|---|
| `unsupported_version` | wire version mismatch — your client is older or newer than the app |
| `malformed_json` | the request did not decode |
| `payload_too_large` | over the bound |
| `unknown_action` | not one of the five actions |
| `invalid_params` | the action's own parameters were wrong |
| `intent_not_found` | see below — this one is not what it looks like |
| `not_ready` | the app is not serving yet |
| `busy` | at capacity; refused rather than queued |
| `internal_error` | a defect — report it |

### `intent_not_found` is deliberately ambiguous

It means **either** "no such intent" **or** "you may not call it". You cannot
tell which, and that is the design:

```sh
$ tenon-cli intent describe ui.toast.v1
{"code":"intent_not_found","message":"intent 'ui.toast.v1' is not callable by the CLI principal"}

$ tenon-cli intent describe totally.made.up.v1
{"code":"intent_not_found","message":"intent 'totally.made.up.v1' is not callable by the CLI principal"}
```

A caller that may not use a contract does not get to learn whether it exists.
Check with `tenon-cli intent list` — if it is not in your projection, you cannot
call it, whatever the reason.

### `busy` is a cap doing its job

The app holds a fixed capacity of in-flight requests and refuses past it. The
alternative to an immediate answer is an unbounded queue of work waiting behind
whatever is slow, which is not a better outcome — it is the same failure,
delayed and harder to attribute.

Back off and retry; `retryAfterMs` tells you how long.

## Domain errors

Each contract declares its own, and each intent reference page lists them under
**Errors it can return**. Every core domain error is namespaced
`dev.tenon.core.*`:

| Code | Typically means |
|---|---|
| `agent-handoff-unresolved` | a cross-agent resume with no `transcriptPath` |
| `agent-unavailable` | that agent is not installed on this machine |
| `agent-question-capacity` | too many questions already pending |
| `agent-question-pane-closed` | the pane went away before it was answered |
| `agent-question-pending` | one is already waiting on that pane |
| `close-refused` | the target refused to close |
| `content-not-text` | asked for text from something that is not |
| `content-unavailable` | the content could not be produced |
| `cursor-invalidated` | a paged read's cursor is stale — restart the walk |
| `external-open-failed` | the OS declined to open it |
| `filesystem-failed` | the underlying filesystem operation failed |
| `invalid-url` | malformed URL |
| `layout-unavailable` | the layout operation could not be applied |
| `pane-not-found` · `tab-not-found` · `workspace-not-found` | the scoped target is gone |
| `path-already-exists` · `path-not-found` | filesystem preconditions |
| `process-launch-failed` | the command could not start |
| `process-output-unavailable` | output could not be collected |
| `process-timed-out` | the command exceeded its own timeout |
| `terminal-unavailable` | no terminal to act on |
| `user-cancelled` | a person said no — an answer, not a fault |
| `workspace-unavailable` | the workspace is not usable right now |

::: tip `user-cancelled` is a result
Treat it as a branch, not an exception. Someone was asked and declined; retrying
or logging an error is the wrong response to a decision.
:::

## Lifecycle failures

On top of domain errors, any intent can fail at the boundary before its provider
ever runs — an undeclared use, a missing capability, an unauthorized scope, an
unconfirmed policy operation, an ineligible provider, an admission refusal, or a
deadline.

Two of those look like bugs and are not:

**A policy-confirmed operation expiring.** CLI and agent callers receive no
standing consent. An unattended `confirmation: policy` operation **expires**
rather than silently escalating. That is the fail-closed rule working — do not
route around it by raising the timeout.

**A deadline exceeded.** The deadline covers admission, confirmation, provider
execution *and* settlement. Raising it can diagnose slow work; it is not a way
to hold a request open. Multiple values over time is a
[resource](/plugins/resources).

## A timeout is not always an error

`terminal.wait.v1` settles **normally** with `met: false` when its condition is
not reached in time:

```json
{"paneID":"UUID","condition":"command-finished","met":false}
```

"It did not finish in 30 seconds" and "something went wrong" are different
facts. Check `met`, not just `ok`.

## Handling failure

```js
const result = await call.send(name, input)
if (!result.ok) {
  switch (result.error.code) {
    case "dev.tenon.core.user-cancelled":
      return                                  // a decision, not a fault
    case "dev.tenon.core.terminal-unavailable":
      return fallback()
    case "busy":
      return retryAfter(result.error.retryAfterMs)
    default:
      tenon.log("unexpected", result.error.code, result.error.message)
  }
}
```

`send` does **not** throw for a failed intent. If you are not checking `ok`, you
are not handling failure.
