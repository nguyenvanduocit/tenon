# The spatial canvas

Each tab owns a **fixed 12 × 12 logical grid**. Panes are whole rectangles on
it, addressed with integer coordinates.

That single choice decides most of how the workspace feels.

## Why a fixed grid

Panes always tile. No overlap, no gaps, no floating windows, no z-order, and no
pane hiding behind another one.

For a supervision surface this is not an aesthetic preference. **A window you
cannot see is a workstream you are not supervising.** Free-floating panes make
"is anything hidden?" a question you have to keep asking; a tiling grid answers
it structurally, forever.

Integer coordinates also make layout *repeatable*. A layout you build is a
layout that comes back, byte for byte, rather than drifting a few points every
restore.

## Layout is pure values

The layout rules live in `TenonCore` as pure values. AppKit paints them and
routes pointer events; it does not own them.

Three consequences, in increasing order of how much you will notice:

1. **Layout rules are testable without a window.** The project's own fitness
   test for any design is "can this rule be asserted headlessly?" — if not, the
   rule is in the wrong layer.
2. **Layout iteration stays local.** Changing how splitting works does not
   require touching view hosting.
3. **Dragging is cheap.** Slot content, geometry, and live terminal resources
   are separate concerns, so high-frequency pointer movement does no process,
   filesystem, or view-host reconstruction work. Dragging a pane around does not
   restart anything inside it.

## Transactions, and why Escape always works

A pointer gesture is not a stream of mutations. It is one **transaction**
carrying:

- its operation kind,
- the exact baseline it started from,
- the complete proposed layout,
- the ordered set of pane IDs it claims to affect.

The catalog accepts it only if the baseline still equals the active tab, the
proposal is valid, **and the claimed affected IDs equal the changes it would
actually make**. Anything else is refused whole.

That last condition is the interesting one. A transaction that would touch a
pane it did not declare is rejected, not applied — so a layout bug cannot
quietly move something you were not dragging.

Because a gesture is all-or-nothing, `Escape` restoring the exact layout from
pointer-down is not a best-effort undo. There is no partially-applied state for
it to clean up.

## Identity outlives geometry

A pane's UUID owns its terminal surface. Moving, resizing, swapping, switching
tabs and switching workspaces all preserve that identity and its live process.

A surface is released only when its pane leaves the **complete workspace
catalog** — not when it scrolls out of view, and not when you look at another
workspace.

Across an app restart, the catalog restores the workspace, tabs, pane
rectangles, content kinds, titles, selection and working-directory placeholders.
A restored terminal is then materialized **lazily as a fresh shell**.

Tenon does not serialize a process and resurrect it. It could show you something
that looked like your session and was not, and for a tool whose entire value is
that its claims are checkable, that is the worst available failure.

## Real terminals, not a re-implementation

Every terminal pane is a real libghostty surface with native keyboard, mouse,
clipboard, focus, scale and resize integration. Tenon consumes a pinned,
prebuilt `GhosttyKit.xcframework`; the app build never compiles Ghostty with
Zig.

The reason to embed a real terminal rather than write one is the same reason
Tenon does not orchestrate: an agent TUI depends on terminal behavior in ways
that are expensive to approximate and catastrophic to approximate *slightly
wrong*. A supervision tool that renders agent output almost correctly is not a
supervision tool.

## A pane is not only a terminal

A pane can hold a terminal, a file, the working-tree changes, a local web
preview, or a plugin view. All of them go through one coherent content picker.

The scope here is narrow on purpose. These are the surfaces you would otherwise
leave the window for during a coding session — reading a file the agent named,
checking the diff behind a claim, glancing at a preview. Tenon is not becoming
an editor-centric IDE; the terminal stays at the center and these keep you next
to it.
