# Design — CLI support

**Status:** accepted target; wire-v2 migration in progress · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)
**Intent kernel:** [`design-intent-bus.md`](design-intent-bus.md)

## Goal

Tenon exposes one local Unix-domain socket and a `tenon-cli` binary. A human process or
coding agent can discover authorized operations, invoke them, inspect workspace state,
write to a terminal, read its viewport, and wait for a terminal condition.

The CLI is a public adapter over the same canonical intent contracts used by plugins and
agents. It is not a second domain API.

## Boundary classification

The CLI protocol contains exactly two direct control operations and three intent adapter
operations:

| Wire action | Classification | Purpose |
|---|---|---|
| `ping` | reserved control plane | protocol/server liveness and backend metadata |
| `app.focus` | reserved control plane | single-instance activation/focus handshake |
| `intent.list` | reserved intent discovery control plane | policy-filtered descriptors |
| `intent.describe` | reserved intent discovery control plane | one canonical descriptor/schema |
| `intent.send` | INTENT adapter | dispatch one canonical intent |

Workspace state and mutation, terminal send/read/wait/focus, file operations, process
execution, network access, and plugin-owned actions MUST use `intent.send`. No
domain-specific operation may be added to `CLIAction`.

Friendly shell subcommands MAY exist, but they are client-side aliases that construct an
`intent.send` request. They do not add wire actions or server handlers.

Examples:

```sh
tenon-cli intent list
tenon-cli intent describe workspace.state.v1
tenon-cli intent send workspace.state.v1 '{}'
tenon-cli intent send terminal.write.v1 \
  '{"text":"git status\r"}' --pane "$TENON_PANE_ID"
tenon-cli intent send terminal.viewport.read.v1 '{}' --pane "$TENON_PANE_ID"
tenon-cli intent send terminal.wait.v1 \
  '{"condition":"command-finished","timeoutMs":30000}' --pane "$TENON_PANE_ID"
```

## Architecture

```text
human / local agent
       │
       ▼
  tenon-cli
       │ newline-delimited JSON over 0600 Unix socket
       ▼
 CLI socket adapter
       ├── ping / app.focus ─────────────► direct control-plane handler
       ├── intent.list / describe ───────► policy-filtered catalog projection
       └── intent.send ──────────────────► IntentDispatcher
                                              │
                                              ▼
                                      typed provider adapter
                                              │
                                              ▼
                                      typed application service
```

Built-in SwiftUI calls the typed application service DIRECT. The CLI crosses a public
principal boundary, so it enters through the intent adapter. Both reach one semantic
implementation.

The CLI principal is host-minted per accepted request/session. Its audience is `cli`.
Discovery and invocation use the same policy revision; knowing an intent name never grants
authority.

## Transport and single instance

- One well-known socket per user: `/tmp/tenon-<uid>/tenon.sock`.
- Parent directory mode is `0700`; socket mode is `0600`.
- Listening and accepted descriptors use `FD_CLOEXEC` so spawned terminal processes cannot
  inherit the control channel.
- A secondary app launch connects to the socket, sends `app.focus`, and exits before
  constructing a second UI.
- A stale socket is removed only after a failed live-instance probe.
- One connection carries one request and one response.
- Framing is newline-delimited JSON with an incrementally enforced payload bound.
- Local trust is explicit: a process running as the same macOS user can drive Tenon.

`ping` and `app.focus` are reserved because they establish and operate the transport/app
instance itself. They MUST NOT grow product payloads.

## Wire v2

All domain values use `IntentValue`, Tenon's bounded, owned, Sendable JSON value. The
socket does not define a second JSON model.

Request:

| Field | Type | Required | Contract |
|---|---|---|---|
| `v` | integer | yes | exact protocol version (`2`) |
| `id` | string | yes | client correlation ID, max 128 bytes |
| `action` | string | yes | one of the five actions above |
| `params` | object | no | defaults to `{}`; unknown fields fail |

Success:

```json
{"v":2,"id":"c1","ok":true,"result":{}}
```

Failure:

```json
{
  "v": 2,
  "id": "c1",
  "ok": false,
  "error": {
    "source": "control",
    "code": "invalid_params",
    "message": "missing field 'name'"
  }
}
```

Intent failures preserve the kernel's open structured error instead of flattening it:

```json
{
  "source": "intent",
  "code": "tenon.denied",
  "message": "intent failed with tenon.denied",
  "details": {},
  "retryable": false,
  "outcome": "notStarted",
  "requestID": "…",
  "providerID": "…"
}
```

Control errors have a closed vocabulary for framing, version, action, and parameter
failures. Intent/domain errors remain canonical intent error codes.

## Action contracts

### `ping`

Parameters: `{}`.
Result: `{protocolVersion, pid, backend}`.

This proves only control-socket liveness. It does not prove that every provider is ready.

### `app.focus`

Parameters: `{}`.
Result: `{activated:true}`.

This is used by the single-instance handshake. It activates the existing process and brings
its primary window forward.

### `intent.list`

Parameters:

```json
{"cursor":"optional opaque cursor","limit":100,"query":"optional text"}
```

Result is the immutable, policy-filtered `cli` projection with an opaque next cursor.
Pagination binds to catalog, provider-registry, policy, and principal/session revisions.
A changed revision invalidates the cursor.

### `intent.describe`

Parameters: `{"name":"workspace.state.v1"}`.

Result is the canonical descriptor visible to this CLI principal: name, version, title,
description, input/output schemas, effects, domain errors, availability, and limits.
Hidden intents answer as not found; privileged diagnostics are a separate inspector concern.

### `intent.send`

Parameters:

```json
{
  "name": "workspace.pane.focus.v1",
  "input": {},
  "options": {
    "timeoutMs": 10000,
    "idempotencyKey": "optional key",
    "target": {"providerID":"optional explicit provider"},
    "scope": {
      "workspaceID": "optional UUID",
      "paneID": "optional UUID"
    }
  }
}
```

Result is the successful canonical intent output. A failed intent uses the structured
intent failure envelope above.

The CLI binary resolves `--pane` in this order before sending:

1. explicit `--pane <uuid>`;
2. `$TENON_PANE_ID`;
3. omit it and let the contract/provider resolve the active pane where allowed.

Pane/workspace identity travels in caller-selectable `options.scope`; it is not duplicated
inside every input schema. Scope designates a target but does not grant it—policy still
authorizes the resolved resource for the CLI principal. `userGestureID` is host-minted and
is never accepted from CLI input.

## Canonical domain mappings

| User job | Intent |
|---|---|
| inspect workspace | `workspace.state.v1` |
| create/select/split/focus/close/change pane content | the matching `workspace.*.v1` intent |
| send terminal input | `terminal.write.v1` |
| run a command in a terminal | `terminal.run.v1` |
| read terminal viewport | `terminal.viewport.read.v1` |
| wait for terminal condition | `terminal.wait.v1` |
| invoke a palette-capable plugin action | its plugin-owned intent name |

Palette rows are presentation metadata on plugin-owned intent contracts. A CLI action does
not invoke a palette row by an unrelated command identifier; it invokes the same canonical
intent when that contract includes the `cli` audience.

### `terminal.viewport.read.v1`

This is a finite snapshot query, not a stream. Input is `{}` and the target pane is
`scope.paneID`. Output:

```json
{
  "paneID": "UUID",
  "text": "visible terminal text",
  "exited": false,
  "columns": 120,
  "rows": 40,
  "alternateScreen": false
}
```

The contract promises the visible viewport only. It MUST NOT claim full scrollback until a
Ghostty-backed implementation can prove it. Large future history is a bounded resource,
not a larger inline intent output.

### `terminal.wait.v1`

This is one finite wait request that settles once:

```json
{
  "condition": "exit | tui-idle | command-finished",
  "timeoutMs": 30000
}
```

Output:

```json
{"paneID":"UUID","condition":"command-finished","met":true}
```

`command-finished` observes the next OSC 133 semantic prompt marker.
`tui-idle` is a bounded host heuristic over stable viewport samples. Timeout settles
normally with `met:false`; caller cancellation and dispatcher deadline use canonical intent
lifecycle errors.

Elapsed wait duration does not make this a resource: the caller receives one terminal
result and no handle survives settlement. The provider's observer is an internal
implementation resource owned and cancelled with the request.

The provider MUST use deferred/asynchronous observation. It MUST NOT block the socket accept
thread, main actor, or the intent mailbox while waiting.

## Threading and responsiveness

- The socket accept/read loop runs on a dedicated blocking thread.
- Framing and bounded JSON decode happen off the main actor.
- Valid requests enter async adapters; UI effects hop to `MainActor` only for the minimal
  native operation.
- Intent dispatch never synchronously executes a plugin handler across runtimes.
- A terminal wait owns a cancellable observer and settles the request later.
- Accepted connections, pending requests, output, and timeouts are bounded.

A slow intent provider may delay its own response. It MUST NOT block the accept loop,
built-in UI, or an unrelated provider.

## Terminal environment

Every Tenon terminal receives:

- `TENON_SOCKET_PATH` — the primary instance socket;
- `TENON_PANE_ID` — that pane's stable UUID.

They are injected through Ghostty surface configuration and inherit the same owned-buffer
lifetime as the terminal working directory/command configuration.

## Verification and fitness

The CLI boundary is accepted only when all of these pass:

- wire-v2 round-trip, payload/depth/count bounds, unknown-field rejection, version mismatch;
- the action parser accepts exactly the five actions and rejects domain-specific additions;
- `intent.list` and `intent.describe` expose only the `cli` projection;
- `intent.send` uses the production dispatcher and canonical `IntentValue`/failure envelope;
- exhaustive source search finds no CLI workspace/terminal/file/process implementation
  bypassing the dispatcher;
- `workspace.state.v1`, `terminal.write.v1`, `workspace.pane.focus.v1`,
  `terminal.viewport.read.v1`, and `terminal.wait.v1` pass end-to-end through the socket;
- a wait can be cancelled and releases its observer exactly once;
- a second app launch focuses the primary and exits;
- socket permissions and `FD_CLOEXEC` are asserted;
- the full Swift 6 build and test suite pass.

Falsification: if a proposed CLI operation needs a new domain-specific wire action, its
intent contract or adapter is incomplete. If viewport read requires unbounded history, it
must return a resource handle. If a wait blocks `MainActor` or a provider mailbox, its
lifecycle implementation is wrong.

## Sources

Reference implementations remain under `refrerences/supacode`, `refrerences/muxy`, and
`refrerences/orca`; the teardown is in `research-reference-terminals.md`.
