# Design — spatial pane slots

**Status:** landed; interaction boundary reconciled · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Goal

A workspace contains tabs; each tab contains freely arranged rectangular slots. A slot has
stable identity, spatial geometry, and typed content. Moving, resizing, switching tabs, or
moving a slot to another tab preserves its live terminal/editor/plugin resource by keeping
the slot UUID stable.

## Model

```swift
public struct WorkspaceSlot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var rect: GridRect
    public var content: SlotContent
}

public struct Tab: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var slots: [WorkspaceSlot]
    public var activeSlotID: UUID?
}

public struct Workspace: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var path: URL
    public var tabs: [Tab]
    public var activeTabID: UUID
}
```

`SlotContent` currently represents terminal, changes, docs, file, diff, plugin view, and
empty content. Native resources are not stored in the enum.

Identity joins three concerns:

```text
WorkspaceSlot.id
  ├── geometry/value state in WorkspaceCatalog
  ├── typed SlotContent value
  └── live native resource in SurfacePool/editor/web/plugin instance stores
```

That separation is load-bearing. Geometry mutations move only values; the resource follows
the unchanged UUID and is not restarted.

## Spatial layout

`SpatialLayout` owns all geometry rules:

- fixed logical grid: 12 columns × 12 rows;
- minimum slot size: 3 × 3;
- rectangles stay inside the grid;
- slot IDs are unique;
- rectangles do not overlap.

`GridRect` uses integer coordinates, making proposals deterministic and easy to test.
Rendering scales logical cells to current canvas pixels.

Geometry operations produce immutable transactions:

- split;
- close with deterministic neighbor absorption;
- best empty rectangle;
- move;
- swap;
- attached/detached resize;
- fill width — the slot grows sideways to the panes sharing its rows, or to the canvas
  edge where none do. Neighbours are stops, never shrunk, so nothing else moves. A slot
  already spanning its band yields an invalid (no-op) transaction.

A transaction contains baseline, proposal, affected IDs, kind, and validity. The workspace
applies it only when:

- kind matches the requested mutation;
- proposal is valid;
- baseline matches the active tab;
- claimed affected IDs equal actual changed IDs.

This prevents stale drag/resize proposals from overwriting newer state.

## Workspace mutations

Typed operations include:

- add/select/remove workspace;
- new/select/next/previous/close tab;
- add/split/close/focus/next/previous slot;
- set slot content;
- move slot to new/existing tab;
- fill slot width;
- apply spatial move/swap/resize transaction.

Every mutation returns `[WorkspaceEvent]`. Empty means no state change. Events describe
committed facts such as `slotOpened`, `slotSplit`, `slotsMoved`, `slotsResized`,
`slotContentChanged`, and `slotMovedToTab`.

Validation and mutation are atomic. A placement failure leaves the catalog untouched.

## Interaction classification

| Interaction | Mechanism |
|---|---|
| built-in SwiftUI gesture/menu changes workspace | DIRECT typed workspace call |
| plugin/CLI/agent reads or changes workspace | INTENT |
| committed workspace mutation facts | EVENT |
| plugin declares pane content/tree | CONTRIBUTION |
| terminal/web/editor instance lifetime | RESOURCE + DIRECT host pool/store |
| spatial layout math/transaction validation | DIRECT pure core logic |

Built-in UI and public principal adapters reach the same typed workspace implementation:

```text
SwiftUI gesture ─────────────────────► WorkspaceStore / typed use case
plugin / CLI / agent ─► intent provider ─► same typed use case
```

No generic app intent principal is needed.

## Canonical workspace intents

The current public inventory is:

- `workspace.state.v1`;
- `workspace.pane.owner.v1`;
- `workspace.tab.create.v1`;
- `workspace.tab.focus.v1`;
- `workspace.pane.split.v1`;
- `workspace.pane.focus.v1`;
- `workspace.pane.close.v1`;
- `workspace.pane.content.set.v1`;
- `workspace.content.open.v1`;
- `workspace.tab.next.v1`;
- `workspace.tab.previous.v1`;
- `workspace.pane.focus-next.v1`;
- `workspace.select.v1`.

Workspace, tab, and pane targeting uses caller-selectable
`options.scope.workspaceID/tabID/paneID`; policy authorizes the designation. The input
schema contains operation data only (for example split axis or content descriptor).

`workspace.content.open.v1` is the one intent that does not ask the caller to choose a
pane: placement is host policy. A pane scope selects that pane's tab; a tab scope selects
that exact tab; otherwise the active tab in the scoped workspace is used. The selected
tab's pane that already shows this kind of content takes it — a file pane takes the next
file, a diff pane the next diff, a plugin view yields only to that same view, a blank pane
takes anything — and with no such pane the selected tab's active pane splits horizontally.
It never opens a tab. `WorkspaceStore.openContent` is the single typed implementation; the
built-in Changes panel calls it DIRECT and this intent is its public adapter.

Future move/swap/resize intents require a concrete public use case and explicit bounded
schema. They MUST adapt to the existing typed transactions rather than creating a second
geometry implementation.

## Plugin view contribution

```js
tenon.views.register("tree", { title: "Files", instanced: false });
tenon.views.set("tree", { items: rows });
tenon.views.onSelect("tree", handler);
```

The plugin contributes declarative state. A generic
`SlotContent.pluginView(pluginID:viewID:)` identifies it; the host resolves/render the
current active generation's contribution. The plugin never receives `WorkspaceSlot`,
terminal, editor, or WebKit objects.

For instanced views, the slot UUID is the instance ID. Workspace-catalog reconciliation,
not SwiftUI visibility, owns open/close lifecycle. See `design-plugin-view-instances.md`.

## Resource lifecycle

When a slot opens/closes or changes content, committed workspace facts drive resource
reconciliation:

- terminal content → `SurfacePool`;
- plugin web content → `PluginWebSurfacePool`;
- editor/file state → slot-scoped host store;
- plugin view instance → `PluginHost` instance reconciliation.

Tab switching and slot moves retain resources. Slot close/content replacement releases the
superseded resource exactly once. Stale generation callbacks cannot publish into the new
owner.

## Rendering

`SpatialCanvasView` renders the authoritative grid rectangles and translates drag/resize
gestures into `SpatialLayout` proposals. It does not own layout rules. Click count is part
of the gesture, not the geometry: a pane header answers a second click with fill width, the
way a window title bar answers one with zoom, while every other region keeps its drag.

Preview is ephemeral. Only a validated committed transaction mutates `WorkspaceCatalog`.
Keyboard focus and accessibility IDs follow the active slot UUID.

## Fitness functions

- every catalog has unique workspace/tab/slot IDs and valid active selections;
- every tab layout stays within the 12×12 grid, minimum size, and non-overlap rules;
- every spatial operation is deterministic and leaves invalid input unchanged;
- stale/mismatched transactions are rejected;
- moving a slot preserves UUID, content, and live resource;
- close/content replacement releases only the affected resource;
- built-in UI uses typed DIRECT workspace calls;
- plugin/CLI/agent workspace calls use declared canonical intents;
- workspace events are facts and contain bounded structural values;
- plugin views remain contributions and native resources never cross the plugin boundary;
- Swift 6 build, geometry/workspace tests, and real canvas interaction tests pass.

Falsification: if geometry behavior exists in SwiftUI rather than `SpatialLayout`, the
functional-core boundary is broken. If a public caller needs a workspace operation absent
from the catalog, add a canonical intent provider over the typed mutation. If moving a slot
restarts its resource, identity has leaked into presentation or lifecycle code.
