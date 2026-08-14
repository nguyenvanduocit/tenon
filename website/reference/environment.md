# Environment variables

## What a Tenon terminal exports

Every pane Tenon opens identifies itself to the process running inside it. This
is measured from a live pane, not inferred:

| Variable | What it is |
|---|---|
| `TENON_PANE_ID` | this pane's stable UUID |
| `TENON_SOCKET_PATH` | the running instance's control socket |
| `TENON_TAB_ID` | the tab that owned this pane **when the shell started** |
| `TENON_WORKSPACE_ID` | the workspace that owned it when the shell started |
| `TENON_AGENT_HOOK_PORT` | Agent Lens hook endpoint |
| `TENON_AGENT_HOOK_SCRIPT` | path to the installed hook script |
| `TENON_AGENT_HOOK_TOKEN` | authenticates hook payloads from this pane |
| `TENON_AGENT_SURFACE_TOKEN` | this terminal-surface incarnation's token |

`TENON_PANE_ID` and `TENON_SOCKET_PATH` are the two you use directly — they are
what make `tenon-cli` work with no arguments inside a pane.

::: warning Tab and workspace IDs are a snapshot
`TENON_TAB_ID` and `TENON_WORKSPACE_ID` are captured when the shell starts. Move
the pane to another tab and they are stale — the environment of a running
process cannot be rewritten.

Ask for the live answer instead:

```sh
tenon-cli intent send workspace.pane.owner.v1 \
  --input '{"paneID":"'"$TENON_PANE_ID"'"}'
```
:::

The hook and surface tokens belong to [Agent Lens](/guide/agent-lens). They
authenticate a specific terminal-surface incarnation, which is why a **rotated**
token is rejected rather than accepted as "close enough" — that rotation is
exactly how Tenon tells a live session from a stale one.

## Detecting Tenon

```sh
if [ -n "$TENON_PANE_ID" ] && command -v tenon-cli >/dev/null; then
  # inside a Tenon pane, with a CLI to talk to it
fi
```

Both halves matter: `TENON_PANE_ID` says you are in a pane,
`command -v tenon-cli` says you can act on it.

## What Tenon reads at launch

| Variable | Effect |
|---|---|
| `TENON_WORKSPACE_PATH` | selects the initial workspace and its terminals' working directory |
| `TENON_PLUGINS_DIR` | points the host at a different plugin folder as the primary inventory |
| `TENON_TRUST_PLUGIN_INVENTORY` | **exactly `1`** — treat that folder as bundled-equivalent |
| `TENON_STUB_TERMINAL` | `1` replaces PTYs with deterministic content, for UI smoke runs |
| `TENON_SOCKET_PATH` | which instance a CLI client talks to |

Without `TENON_WORKSPACE_PATH`, Tenon picks a meaningful launch directory and
falls back to your home directory when LaunchServices starts it at `/`.

### `TENON_TRUST_PLUGIN_INVENTORY` is matched exactly

`TENON_TRUST_PLUGIN_INVENTORY=1` grants the `TENON_PLUGINS_DIR` folder
bundled-equivalent standing: new plugins there auto-enable and receive standing
consent.

**`true` leaves it untrusted.** That is deliberate, not a parsing oversight — a
flag that decides whether unreviewed code runs automatically should not be
satisfied by an approximate value.

It also applies **only** to the `TENON_PLUGINS_DIR` override. The separate user
plugin inventory never inherits it, and is always untrusted.

```sh
# Development fixture: auto-enable and reload on save.
TENON_PLUGINS_DIR=~/tenon-plugins \
TENON_TRUST_PLUGIN_INVENTORY=1 \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

## Snapshot writers

For rendering a view offscreen without a window or a screen-recording grant.
Useful when a change moves layout and a passing test only proves the view tree
has the right *shape*:

| Variable | Renders |
|---|---|
| `TENON_VIEW_SNAPSHOT=<plugin/view>:<path.png>` | any plugin view |
| `TENON_VIEW_SNAPSHOT_WORKSPACE` | the workspace it mounts over |
| `TENON_DIFF_SNAPSHOT` | the diff view |
| `TENON_CHANGES_SNAPSHOT` | the changes panel |
| `TENON_TIMELINE_SNAPSHOT` | Agent Lens' Timeline account |
| `TENON_SIDEBAR_SNAPSHOT` | the workspace sidebar and its footer |

```sh
TENON_PLUGINS_DIR=plugins TENON_TRUST_PLUGIN_INVENTORY=1 \
TENON_VIEW_SNAPSHOT='dev.tenon.kanban/board:/tmp/board.png' \
TENON_VIEW_SNAPSHOT_WORKSPACE="$PWD" swift run tenon
```

The Timeline form takes `TENON_TIMELINE_SNAPSHOT_STATE`
(`idle|running|ready|failed|insufficient`), `TENON_TIMELINE_SNAPSHOT_SIZE=WxH`
for the narrow-pane reflow, and `TENON_TIMELINE_SNAPSHOT_EVIDENCE=1` to open
every milestone's anchors. The sidebar form takes
`TENON_SIDEBAR_SNAPSHOT_SIZE=WxH`.

## Where durable state lives

Under your Application Support directory: the workspace catalog, plugin
installation identities and enablement, plugin-private storage, intent
idempotency and consent data, and authored plugins.

**Do not edit these while Tenon is running.** If the catalog is corrupt,
preserve a copy before moving it aside, and do not delete the whole tree —
installation IDs, enablement, private storage and consent records are
independent state.
