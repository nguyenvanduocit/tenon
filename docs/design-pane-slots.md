# Design — Pane slots: typed, stackable, freely arranged

Status: **core + plugin API landed and verified (`swift test`: 112/112); shell written and
type-checked, pending a GUI smoke run** (needs GhosttyKit + a windowed session). North
star: VISION.md. Method: docs/tdd.md.

## The idea, in one sentence

Every visible surface in the app is a **pane** — a content-agnostic slot — and a tab is a
**layout tree** of those slots that the user splits, stacks, resizes, and drags freely.
A pane can hold a terminal *or* a plugin view; the kernel never knows which kind it is,
only *that* kind. This is the standard docking / tiling model (VS Code editor groups,
dockview, tmux), grounded in what the kernel already owns: "the pane/tab/window tree"
(VISION §1).

## What was already true (the seam we build on)

- `SplitNode` is a tested binary split tree; a pane is just a `UUID` (`Workspace.swift`).
- `SurfacePool` maps pane `UUID → TerminalSurface` in the shell; the core never touches a
  terminal type (Invariant #2, tdd.md rule 3).
- `tenon.sidebar` already renders a plugin view natively in a fixed slot — the view
  mechanism exists, it was just nailed to the 220px left rail.

So this feature is: **generalize the leaf to a stack, give the leaf typed content, give
splits identity, and add the move/resize mutations + a `tenon.views` surface.** The tree
geometry machinery is reused, not reinvented.

## The model (TenonCore, pure values — no AppKit)

```swift
public indirect enum SplitNode: Equatable {
    case leaf(panes: [UUID], selected: Int)                 // a stack; single pane = stack of one
    case split(id: UUID, SplitOrientation,                  // id addresses the split for resize
               first: SplitNode, second: SplitNode, ratio: Double)   // ratio is authoritative
    static func pane(_ id: UUID) -> SplitNode               // sugar for .leaf([id], 0)
}
```

- **Every leaf is a stack.** One leaf shape, one code path. A single-pane leaf renders with
  no visible mini tab-bar; a multi-pane leaf renders its panes as tabs sharing the slot.
- **`Split.id` is excluded from `==`** (custom `Equatable`) so tests compare tree *shape +
  ratio + panes*, not random ids. `ratio` is compared exactly.
- **Content is a side-table on `Workspace`**, keyed by pane `UUID`, not stored in the leaf:
  ```swift
  public enum PaneContent: Equatable { case terminal; case pluginView(plugin: String, viewID: String); case empty }
  public private(set) var paneContents: [UUID: PaneContent]   // default .terminal per new pane
  ```
  Geometry (SplitNode), content (`paneContents`), and surface instances (`SurfacePool`) are
  three tables joined by the pane `UUID`. A **move is pure geometry** — content and the live
  surface ride along by key, so dragging a running terminal to another tab does not restart
  it. This is the reason content is a side-table, not a leaf field.

## Mutations (each returns `[WorkspaceEvent]`; `[]` == nothing changed)

Existing (generalized to stacks): `newTab`, `splitFocusedPane`, `closePane`, `closeTab`,
`focusPane` (now also sets the containing leaf's `selected`), `focusNextPane`, tab selection.

New:

| Mutation | Meaning |
|---|---|
| `setPaneContent(_ pane, _ content)` | change a pane's content type (A) |
| `movePane(_ id, beside target, _ o, _ side)` | 4-edge drop: remove + insert as leaf-of-one beside target's leaf |
| `movePane(_ id, intoStackOf target)` | center drop: remove + append to target's stack, select it |
| `movePane(_ id, toTab, beside, _ o, _ side)` | cross-tab drop (may empty+close the source tab) |
| `reorderInStack(_ id, to index)` | drag a tab within a stack |
| `setSplitRatio(_ splitID, _ ratio)` | resize; clamps 0.1…0.9; **must emit an event** so the store commits (see below) |

**Move = remove + insert, atomic, addressed by UUID.** `removingPane` collapses a stack of 1
(promote sibling, the old behavior) but only drops a tab from a stack of >1 (tree unchanged).
Insert finds the target leaf by UUID in the already-collapsed tree, so same-tab reorders are
safe. Cross-tab keeps the pane's UUID stable → no false close/open.

## Events (added)

```swift
case paneMoved(pane: UUID, fromTab: UUID, toTab: UUID)   // from==to ⇒ same-tab reorder
case splitResized(split: UUID, ratio: Double, tab: UUID)
case paneContentChanged(pane: UUID, content: PaneContent)
```

Selecting a stack tab reuses `paneFocused` (select == focus + make visible). All three map
to free-tier `workspace.*` bus topics (structural, not sensitive — VISION §5). The shell
should call `setSplitRatio` on divider drag-*end* (or throttled) to avoid bus spam.

## Resize + splits: native, not hand-rolled

Splits render as the native `HSplitView`/`VSplitView` (AppKit `NSSplitView` under the hood):
real draggable dividers, native feel, zero divider math in our code. **The shell does not
reinvent the split view** — an earlier hand-rolled `GeometryReader` divider was a mistake
(fighting the framework) and was removed.

The model still keeps `Split.id` + an authoritative `ratio` and a tested `setSplitRatio`
mutation, but they are **not wired to the live divider** today. They exist for the follow-up
that serializes/restores layout (where `NSSplitView`'s `autosaveName`, or a plugin behind
`workspace.control`, drives divider positions). `WorkspaceStore.apply` drops empty-event
mutations, so `setSplitRatio` emits `splitResized` when it changes.

There are **no fixed sidebars.** The whole window is the pane workspace; anything a plugin
shows (a file tree, a git graph) lives *in a pane* via `PaneContent.pluginView`, chosen from
each pane's content picker. That is the product — every visible thing is a pane.

## Plugin surface (mảnh B): `tenon.views`

Mirrors `tenon.sidebar`, **free tier** (UI contribution needs no permission — VISION §5):

```js
tenon.views.register(viewID, { title });      // declare a view this plugin provides
tenon.views.set(viewID, { items: [...] });    // set content (same declarative row shape as sidebar)
tenon.views.onSelect(viewID, fn);             // selection handler
```

A plugin may provide several views (keyed by `viewID`), unlike the one-section sidebar.
`PluginHost` aggregates them; the shell renders a `.pluginView(plugin, viewID)` pane by
looking the section up and reusing the sidebar row renderer. Opening a view into a pane is
a shell affordance that calls `setPaneContent(pane, .pluginView(...))` — no new permission.

## Invariants preserved

Stacks/typed panes touch no security boundary. Content stays keyed by pane UUID; plugins
declare a **value** (`pluginView(plugin, viewID)`), never touch a terminal or webview
(Inv #2/#3). `tenon.views` is free tier — no new gate (Inv #5). `PaneContent.empty` +
disabled-plugin panes render a placeholder, keeping the empty shell valid (VISION §6).
No private API: terminal-in-pane and view-in-pane share the one `PaneContent` mechanism
(Inv #6).

## Build order (each a red core test first)

1. ✅ Rewrite `SplitNode` → leaf/split; existing `WorkspaceTests` ported to leaf-of-one.
2. ✅ A: `PaneContent` + `setPaneContent` + side-table; content rides along every op.
3. ✅ C-move: `movePane` 4-edge + cross-tab (empties+closes the source tab).
4. ✅ C-stack: `intoStackOf` + `reorderInStack`; focus==selected in a stack.
5. ✅ C-resize: `setSplitRatio` + `Split.id`; clamp 0.1…0.9, commit-via-event.
6. ✅ B: `tenon.views` (PluginRuntime + PluginHost); `file-explorer` dogfoods it.
7. ✅ Shell (type-checked, not yet run): native `HSplitView`/`VSplitView` splits; `LeafView`
   content dispatch; per-leaf header/tab-bar + content picker; 5-zone `PaneDropDelegate`.
   No fixed sidebars — plugin views live in panes. Wired in `ContentView.swift`.

Steps 1–6 are verified by `swift test` (headless, 112 tests). Step 7 compiles under
`swift test`'s type-check but needs `./scripts/setup-ghosttykit.sh` + `swift run tenon-poc`
in a GUI session to smoke-test the pixels (per tdd.md, SwiftUI views carry no rules to
unit-test).

## Not in this pass (natural follow-ups)

- Plugin-driven rearrangement: expose `movePane`/`setSplitRatio`/`setPaneContent` through
  `tenon.workspace.*` behind the existing `workspace.control` gate (the permission already
  exists — Inv #5). Today these are user-gesture-driven only.
- Serialize the layout (make `Workspace` `Codable`) → session restore + saved layout presets.
  The model is already a pure value with authoritative ratios and stable ids, so this is
  additive.
