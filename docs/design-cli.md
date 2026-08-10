# Design — CLI support

**Status:** accepted and implemented · **Reviewed:** 2026-08-06
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)
**Intent kernel:** [`design-intent-bus.md`](design-intent-bus.md)

## Goal

Each installed Tenon channel exposes one local Unix-domain socket, and Tenon ships a
`tenon-cli` binary. A human process or coding agent can discover authorized operations,
invoke them, inspect workspace state, write to a terminal, read its viewport, and wait for
a terminal condition.

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
tenon-cli tab-focus --tab '<copied-tab-uuid>'
tenon-cli pane-focus --pane '<copied-pane-uuid>'
tenon-cli send --tab '<copied-tab-uuid>' --enter 'git status'
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

## Transport and per-channel single instance

- The closed install channels are `production` and `staging`. Each is a singleton within
  itself, and both may run concurrently.
- Production retains the compatibility socket `/tmp/tenon-<uid>/tenon.sock`. Staging uses
  `/tmp/tenon-staging-<uid>/tenon.sock`. Each directory owns its own `tenon.lock`.
- A CLI launched from a neutral external shell defaults to production. Every Tenon pane
  receives `TENON_SOCKET_PATH`, so pane-local CLI and agent calls target the instance that
  owns that pane without adding channel data to the wire protocol. The intended channel
  path is still injected when that instance's socket is degraded, so the request fails in
  its own channel instead of falling back to production.
- Global Codex and Claude hook configuration reads `TENON_AGENT_HOOK_SCRIPT` from the
  launching terminal. Each pane supplies its owning channel's runtime script path, so the
  shared hook configuration is channel-neutral and either app may be installed first.
- The user-global `~/.local/bin/tenon-cli` installer is production-only. Staging uses the
  CLI embedded in its own panes and cannot replace production's neutral-shell command.
- Before bind, the parent path is verified as a real directory owned by the current user,
  not a symlink, with mode `0700`; an unsafe pre-existing path fails closed. Socket mode is
  `0600`.
- `tenon.lock` is a regular, single-link file owned by the current user with mode `0600`;
  it is opened without following symlinks, locked non-blocking, marked `FD_CLOEXEC`, and held
  until the primary has closed and removed its socket. A contender that cannot take the lock
  is secondary even while the winner is between `bind` and `listen`.
- A process that cannot safely open or verify its channel claim is unavailable and stops
  startup before workspace state is assembled. Live-instance probes and activation require
  the pathname itself to be a socket node; they never follow a socket-path symlink.
- The lock file keeps one stable inode and is not deleted. Process exit releases its advisory
  lock, so a stale crash recovers without creating a second lock generation.
- Listening and accepted descriptors use `FD_CLOEXEC` so spawned terminal processes cannot
  inherit the control channel.
- A secondary launch in the same channel sends `app.focus` and exits from concurrent
  startup preparation before hook installation or durable runtime/store construction.
  SwiftUI may briefly show the bootstrap progress window that started that preparation;
  it never assembles a second workspace UI. A launch in the other channel owns a different
  claim and continues normally.
- A stale socket is removed only by the claim owner after a failed live-instance probe, and
  only when `lstat` proves the path is a socket; regular files and symlinks are preserved.
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
      "tabID": "optional UUID",
      "paneID": "optional UUID"
    }
  }
}
```

Result is the successful canonical intent output. A failed intent uses the structured
intent failure envelope above.

The CLI binary accepts `--workspace`, `--tab`, and `--pane` as the corresponding scope
designators. It resolves `--pane` in this order when no explicit tab scope is present:

1. explicit `--pane <uuid>`;
2. `$TENON_PANE_ID`;
3. omit it and let the contract/provider resolve the active pane where allowed.

Workspace/tab/pane identity travels in caller-selectable `options.scope`; it is not
duplicated inside every input schema. The tab-chip and pane-header context menus copy their
stable UUID as raw text for these flags. Scope designates a target but does not grant it—
policy still authorizes the resolved resource for the CLI principal. `userGestureID` is
host-minted and is never accepted from CLI input.

## Canonical domain mappings

| User job | Intent |
|---|---|
| inspect workspace | `workspace.state.v1` |
| focus an exact copied tab ID | `workspace.tab.focus.v1` with `scope.tabID` |
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

This is a finite snapshot query, not a stream. Input is `{}` and the target is either the
exact `scope.paneID` or the active terminal inside exact `scope.tabID`. Output:

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

The contract promises the visible viewport only. Full history uses the separately bounded,
cursor-paged `terminal.scrollback.read.v1` contract; viewport read MUST NOT silently grow
into an unbounded inline result.

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
- production and staging can both become primary, while a second launch in either channel
  focuses only that channel's primary and exits;
- production and staging use distinct Application Support roots, including workspace,
  plugin, runtime/idempotency, user-plugin, and palette-frecency state;
- degraded staging panes retain the staging socket target, and shared agent-hook config
  resolves the channel-local hook script from the pane environment;
- socket permissions and `FD_CLOEXEC` are asserted;
- the full Swift 6 build and test suite pass.

Falsification: if a proposed CLI operation needs a new domain-specific wire action, its
intent contract or adapter is incomplete. If viewport read requires unbounded history, it
must return a resource handle. If a wait blocks `MainActor` or a provider mailbox, its
lifecycle implementation is wrong.

## Sources

Reference implementations remain under `references/supacode`, `references/muxy`, and
`references/orca`; the teardown is in `research-reference-terminals.md`.
