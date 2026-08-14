# Keyboard and pointer

Every control Tenon adds, on one page. Everything not listed here belongs to the
program running inside the pane — Tenon does not intercept it.

## Keyboard

| Action | Shortcut |
|---|---|
| New tab | `⌘T` |
| Split active pane left / right | `⌘D` |
| Split active pane top / bottom | `⇧⌘D` |
| Close active pane | `⌘W` |
| Next pane | `⌘]` |
| Next / previous tab | `⇧⌘]` / `⇧⌘[` |
| Command palette | `⌘K` |
| Cancel a pointer transaction | `Esc` |

Plugins can register host-wide keybindings for the intents they own. Those are
discoverable and rebindable, and they appear alongside the built-in ones rather
than shadowing them. A keyboard control that only works inside one focused view
is that view's own business and is not registered globally.

## Pointer

| Action | Gesture |
|---|---|
| Move a pane | drag its header, drop on empty grid |
| Swap two panes | drag one header, drop on the other pane |
| Resize | drag any pane edge or corner |
| Resize coupled neighbours | drag a shared edge |
| Reorder tabs | drag a tab chip along the strip |
| Resize the sidebar | drag its trailing edge |

Every edge and corner is a resize target even though nothing draws a handle
there — aim at the boundary, not at a widget.

## Escape is a real undo

`Esc` during a drag or resize restores the exact layout captured when the
pointer went down.

This is stronger than it sounds. A pointer transaction is validated as a whole
against the tab it started from: if the baseline no longer matches, the proposal
is invalid, or the panes it claims to affect are not the panes it would actually
change, the whole thing is refused. There is no partially-applied layout to
recover from, so `Esc` is always safe to reach for.

## What Tenon does not take

The pane is a real libghostty surface. Keyboard, mouse, clipboard, focus,
scaling and resize integrate natively, and your program's own keybindings reach
it unmodified — Tenon adds the shortcuts in the table above and does not filter
anything else on its way to the PTY.

## Terminal environment

Every terminal Tenon opens identifies itself to the process inside it:

| Variable | What it is |
|---|---|
| `TENON_PANE_ID` | this pane's stable UUID — the scope every `tenon-cli` verb defaults to |
| `TENON_SOCKET_PATH` | the running instance's control socket |
| `TENON_TAB_ID`, `TENON_WORKSPACE_ID` | the tab and workspace that owned the pane **when the shell started** |

`TENON_PANE_ID` follows the pane wherever it is moved. The other two are a
snapshot taken at shell start: move the pane to another tab and they go stale,
so ask for the live answer instead of trusting them:

```sh
tenon-cli intent send workspace.pane.owner.v1 \
  --input '{"paneID":"'"$TENON_PANE_ID"'"}'
```

An agent pane also carries hook and surface tokens used by
[Agent Lens](/guide/agent-lens). The complete list, including the development
overrides, is in [Environment variables](/reference/environment).
