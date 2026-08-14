# Workspaces, tabs, panes

Three nested things, and no fourth. The whole spatial model is:

```text
Workspace  (a directory, in the left sidebar)
  Tab      (a 12 × 12 canvas)
    Pane   (a rectangle on that canvas, holding one thing)
```

## Workspace

A workspace **is a directory**. It appears in the left sidebar, and it is the
working directory every terminal in it starts from.

Switching workspaces switches the whole set of tabs. Live terminals in the
workspace you left keep running — a pane is released only when it leaves the
workspace catalog entirely, not when you look away from it.

The sidebar can be resized, and it can be hidden. It is not a pane and does not
live on the grid.

## Tab

A tab owns one canvas. A new tab (`⌘T`) opens as a single terminal filling it.

`⇧⌘]` and `⇧⌘[` move between tabs. Closing the active tab selects its previous
neighbour. Tabs can be reordered by dragging a chip in the tab strip; the tab
travels under the pointer as you drag, and releasing outside the strip returns
it to where it started.

## Pane

A pane is a rectangle on the canvas holding exactly one thing: a terminal, a
file, the working-tree changes, a web preview, or a view a plugin contributed.

### Splitting

| | |
|---|---|
| `⌘D` | split the active pane left / right |
| `⇧⌘D` | split the active pane top / bottom |
| `⌘W` | close the active pane |
| `⌘]` | move to the next pane |

Closing the last pane keeps the tab alive and offers **Add terminal**, so you
never end up with a tab you cannot use.

### Moving and swapping

Drag a pane by its header.

- Drop it **on another pane** and the two swap their complete rectangles.
- Drop it **on empty grid** and it moves there.
- Press `Escape` mid-drag and the layout returns to exactly what it was when the
  pointer went down.

That last one is worth trusting. Pointer transactions carry their baseline, the
complete proposal, and the exact set of pane IDs they claim to affect; the
catalog accepts one only if the baseline still matches the live tab, the
proposal is valid, and the claimed IDs equal the real changes. An invalid or
stale gesture is refused whole. There is no state where half a drag landed.

### Resizing

Every edge and every corner is an invisible resize target. Dragging a shared
edge resizes both neighbours where the layout permits it, rather than leaving a
gap.

The canvas is a **fixed 12 × 12 logical grid** with integer coordinates, so
panes always tile: no overlap, no gaps, no floating windows. It is a constraint
you feel as predictability — a layout you build is a layout that comes back.

## What survives what

This table is the part people get wrong, so it is worth reading once.

| Action | Layout | Pane identity | Live process |
|---|---|---|---|
| Move, swap, resize | changes | kept | kept |
| Switch tab | kept | kept | kept |
| Switch workspace | kept | kept | kept |
| Close the pane | — | gone | ended |
| Quit and relaunch | restored | restored | **fresh shell** |

A pane's UUID owns its terminal surface, so a pane keeps its live process
through every layout operation and every switch. What it does *not* keep is a
process across an app restart.

Restore brings back the workspace, its tabs, each pane's rectangle, its content
kind, its title and the selection — and then materializes a restored terminal
lazily as a **new shell** in the recorded working directory. Tenon never
serializes a process and pretends to resurrect it. A pane that looked restored
but held a dead process would be worse than an honest empty one.

Restore is also fail-soft: a workspace directory that no longer exists is
dropped, an invalid tab is dropped, and pane content that is unknown or
unavailable becomes an empty pane. It degrades rather than refusing to open.

## Opening things beside the terminal

**Add pane**, the [command palette](/guide/command-palette), and a plugin's own
actions all reach the same content picker: terminal, files, changes,
automations, a local web preview, and any plugin view.

The reason this exists is narrow and worth stating: these are the surfaces you
would otherwise leave the window for during a coding session. Tenon is not
trying to become an editor-centric IDE — the terminal stays at the centre, and
these keep you next to it.
