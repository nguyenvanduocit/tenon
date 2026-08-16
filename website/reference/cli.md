# `tenon-cli`

A Foundation/POSIX client for the running app's local control socket. It ships
inside the app bundle. Install the current copy from **Settings ▸ CLI ▸ Install**
in Tenon, then verify it with:

```sh
tenon-cli ping
```

## Usage

This block is lifted from the CLI's own source, so it cannot disagree with the
binary:

<<< @/.vitepress/generated/cli-usage.txt

## Five real actions

Everything else is an alias. The complete control surface is:

| Action | Kind |
|---|---|
| `ping` | control plane |
| `focus` (`app.focus`) | control plane |
| `intent list` | discovery |
| `intent describe` | discovery |
| `intent send` | everything else |

`ping`, single-instance activation and focus are the direct control-plane
operations. There is no CLI-only capability: every domain verb compiles to
`intent send` with an explicit input and scope object.

### `ping`

```sh
tenon-cli ping
```

```json
{
  "active" : false,
  "build" : "1",
  "pid" : 59949,
  "protocolVersion" : 3,
  "socketPath" : "/tmp/tenon-501/tenon.sock",
  "version" : "0.1.0"
}
```

Use it to confirm the socket, and to check whether your build is new enough for
a verb you are about to use.

### `intent list`

Returns the immutable, **policy-filtered `cli` projection** with an opaque next
cursor. Pagination binds to the catalog, provider-registry, policy and
principal/session revisions; a changed revision invalidates the cursor.

This is not the whole catalog. Contracts you may not call are not listed at all.

### `intent describe <intent-id>`

Returns the canonical descriptor visible to the CLI principal: name, version,
title, description, input and output schemas, effects, domain errors,
availability and limits.

**A hidden intent answers `intent_not_found`** — the same answer a name that does
not exist gets:

```sh
$ tenon-cli intent describe ui.toast.v1
{"code":"intent_not_found","message":"intent 'ui.toast.v1' is not callable by the CLI principal"}
```

A caller that may not use a contract does not get to learn whether it exists.

### `intent send <intent-id>`

```sh
tenon-cli intent send terminal.open.v1 \
  --input '{"command":"swift test"}' \
  --workspace <uuid> \
  --timeout 30000
```

The result is the successful canonical output, or a structured failure envelope.

## Aliases

Each compiles to exactly one `intent send`:

| Alias | Intent |
|---|---|
| `state` | `workspace.state.v1` |
| `send [--enter] <text…>` | `terminal.write.v1` |
| `read` | `terminal.viewport.read.v1` |
| `wait --for <condition>` | `terminal.wait.v1` |
| `pane-focus` | `workspace.pane.focus.v1` |
| `tab-focus` | `workspace.tab.focus.v1` |
| `rename [<text…>]` | `workspace.pane.title.set.v1` |

`rename` with no text clears the pinned title back to the pane's
content-derived one — which is what an agent does when it finishes a task.

::: tip `unknown command` means your build is older than the verb
Aliases are added over time. The general form always works:
`tenon-cli intent send workspace.pane.title.set.v1 --input '{"title":"…"}'`
:::

## Scope and options

| Flag | Meaning |
|---|---|
| `--workspace <uuid>` | target workspace |
| `--tab <uuid>` | target tab |
| `--pane <uuid>` | target pane |
| `--provider <provider-id>` | require an explicit provider |
| `--idempotency-key <key>` | make a retry safe |
| `--timeout <ms>` | deadline for the whole request |

Identity travels in scope, not inside every input schema.

`--pane` resolves in order: an explicit `--pane`, then `$TENON_PANE_ID`, then
omitted so the contract resolves the active pane where that is allowed.

The tab-chip and pane-header context menus copy their stable UUID as raw text
for exactly these flags.

**Scope designates a target but does not grant it.** Policy still authorizes the
resolved resource for the CLI principal. `userGestureID` is host-minted and is
never accepted from CLI input.

## Waiting

```sh
tenon-cli wait --for exit
tenon-cli wait --for command-finished --timeout 30000
tenon-cli wait --for tui-idle
```

| Condition | What it observes |
|---|---|
| `exit` | the process ending |
| `command-finished` | the next OSC 133 semantic prompt marker — needs shell integration |
| `tui-idle` | a bounded host heuristic over stable viewport samples |

A **timeout settles normally with `met: false`**, rather than erroring. "It did
not finish in 30 seconds" and "something went wrong" are different facts and
conflating them makes scripts wrong.

## Reading output

`read` returns the **visible viewport only** — a finite snapshot, not a stream:

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

History is `terminal.scrollback.read.v1`, which is separately bounded and
cursor-paged. A viewport read must never silently grow into an unbounded inline
result.

## Environment

| Variable | Effect |
|---|---|
| `TENON_SOCKET_PATH` | which instance to talk to; set in every Tenon pane |
| `TENON_PANE_ID` | the default `--pane`; set in every Tenon pane |

Outside a pane, the CLI falls back to the primary instance socket. A `--staging`
install has its own socket under its own identity.

## Transport

Wire v3 over a Unix domain socket, with per-channel single instance. The accept
and read loop runs on a dedicated blocking thread; framing and bounded JSON
decode happen off the main actor; UI effects hop to the main actor only for the
minimal native operation.

A slow intent provider may delay its own response. It cannot block the accept
loop, the built-in UI, or an unrelated provider.

## See also

- [All intents](/reference/intents/) — what you can send.
- [Driving Tenon from a terminal](/guide/cli) — the working introduction.
- [Errors](/reference/errors).
