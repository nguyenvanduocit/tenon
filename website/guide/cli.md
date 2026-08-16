# Driving Tenon from a terminal

`tenon-cli` is a small client for the running app's local control socket. It
matters most because it is *already in every pane Tenon opens* — so an agent
working inside a pane can inspect and drive the workspace it is sitting in.

```sh
tenon-cli ping
```

The complete reference, including every flag, is in
[`tenon-cli`](/reference/cli). This page is the working introduction.

## It defaults to your own pane

Every Tenon terminal exports `TENON_PANE_ID` and `TENON_SOCKET_PATH`. When you
pass neither `--pane` nor `--tab`, the CLI uses `$TENON_PANE_ID`. That is why
most useful commands take no arguments at all:

```sh
tenon-cli read                       # this pane's visible terminal text
tenon-cli rename "Reviewing the auth diff"
tenon-cli state                      # the whole workspace tree
```

## Almost everything is `intent send`

`tenon-cli` has five real actions: `ping`, `focus`, `intent list`,
`intent describe` and `intent send`. Every other verb is a convenience alias
that compiles to `intent send` — `rename` is literally
`workspace.pane.title.set.v1`, and `read` is `terminal.viewport.read.v1`.

That is a design choice with a consequence you can rely on: there is no CLI-only
capability. Anything the CLI can do, the contract behind it can do, and you can
always drop to the general form.

```sh
tenon-cli intent send workspace.pane.split.v1 \
  --input '{"axis":"vertical"}'
```

## Discovery is the manual

Rather than trusting this page, ask your own build:

```sh
tenon-cli intent list                       # everything you may call
tenon-cli intent describe terminal.wait.v1  # schemas, effects, errors
```

`intent list` returns the **policy-filtered projection for the CLI principal** —
not the whole catalog. A contract you may not call is not merely refused, it is
not listed, and describing it answers `intent_not_found` with the same message a
name that does not exist gets. A caller that may not use a contract does not get
to learn whether it exists.

This is why [All intents](/reference/intents/) is generated from two sources and
says so: the CLI genuinely cannot see the plugin-only ones.

## Scope

Workspace, tab and pane identity travel in scope flags, not inside every input
object:

```sh
tenon-cli intent send terminal.write.v1 \
  --input '{"text":"git status\r"}' \
  --pane 5C2F…
```

`--pane` resolves in this order: an explicit `--pane`, then `$TENON_PANE_ID`,
then omitted so the contract resolves the active pane where that is allowed.
The tab-chip and pane-header context menus copy their stable UUID as raw text
for exactly these flags.

**Scope designates a target; it does not grant it.** Policy still authorizes the
resolved resource for the CLI principal.

## Waiting for something

```sh
tenon-cli wait --for command-finished --timeout 30000
tenon-cli wait --for exit
tenon-cli wait --for tui-idle
```

- `command-finished` observes the next OSC 133 semantic prompt marker, so it
  needs shell integration to be meaningful.
- `exit` is the process ending.
- `tui-idle` is a bounded host heuristic over stable viewport samples — useful,
  and honest about being a heuristic.

A timeout settles normally with `met: false` rather than erroring. That is the
difference between "it did not finish in 30 seconds" and "something went wrong",
and conflating them makes scripts wrong.

## Reading terminal output

`read` gives you the **visible viewport only** — it is a finite snapshot, not a
stream, and it will not silently grow into an unbounded dump:

```sh
tenon-cli read
```

For history, `terminal.scrollback.read.v1` is separately bounded and
cursor-paged. Reach for it when you actually need history, and page it.

## Things that will not work, by design

- **Policy-confirmed operations from a script.** Some contracts require a live
  interactive confirmation. CLI and agent callers get no standing consent, so an
  unattended one **expires** rather than silently escalating. A deadline
  exceeded there is the system working.
- **Raising the timeout to turn a wait into a stream.** The deadline covers
  admission, confirmation, provider execution and settlement. Raising it can
  diagnose slow work; it is not a way to hold a request open.
- **Driving another agent.** No verb and no intent lets one principal type into
  another agent's pane on its behalf.

## Common recipes

```sh
# What is in this workspace right now?
tenon-cli state

# Label this pane's tab, then clear it when done.
tenon-cli rename "Migrating the session store"
tenon-cli rename

# Which tab and workspace own me *now*? (the env vars are a start-time snapshot)
tenon-cli intent send workspace.pane.owner.v1 \
  --input '{"paneID":"'"$TENON_PANE_ID"'"}'

# Run a command in a fresh pane and wait for it.
tenon-cli intent send terminal.open.v1 --input '{"command":"swift test"}'
tenon-cli wait --for command-finished --timeout 55000

# Open a file beside me.
tenon-cli intent send file.open.v1 --input '{"path":"/abs/path/to/file.swift"}'
```
