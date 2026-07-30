# Plugin view instances

**Status:** landed; boundary reconciliation accepted · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Problem

A plugin view type may appear in several panes. Singleton state keyed only by
`(PluginID, viewID)` makes every browser pane share one body, address, title, and WebKit
surface. The workspace already has the correct independent identity: each pane's stable
UUID.

## Decision

Separate **view type** from **view instance**:

- type identity: `(PluginID, viewID)`;
- instance identity: workspace pane UUID;
- singleton view: no instance ID;
- instanced view: one live state/resource set per pane UUID.

The pane content remains a generic plugin-view reference. Instance identity comes from the
owning pane, so moving the pane preserves its live state.

## Boundary classification

| Interaction | Mechanism |
|---|---|
| register/set view state | CONTRIBUTION |
| user select/submit and host open/close facts | owner-scoped contribution callbacks |
| enumerate desired instances from workspace catalog | DIRECT pure/typed call |
| reconcile desired/open instance sets | DIRECT host call |
| retain/remove WebKit or terminal surface | RESOURCE lifecycle through injected pool |
| navigate an existing browser surface | INTENT |
| browser URL/title/loading changed | targeted EVENT |

Opening/closing a view instance is host reconciliation, not a plugin-requested lifecycle
intent. A plugin receives the fact and may contribute initial state or send finite intents.

## Public contribution contract

```js
tenon.views.register("browser", { title: "Browser", instanced: true });

tenon.views.onOpen("browser", instanceID => {
  tenon.views.set("browser", initialBody(instanceID), instanceID);
});

tenon.views.onClose("browser", instanceID => {
  delete pluginState[instanceID];
});

tenon.views.onSelect("browser", (action, value, instanceID) => {
  // owner-scoped user fact
});

tenon.views.onSubmit("browser", (action, text, instanceID) => {
  // owner-scoped submitted-text fact
});
```

Singleton behavior:

- omit `instanced` or set it to false;
- publish one body without `instanceID`;
- select/submit callbacks receive no instance ID;
- open/close lifecycle callbacks are unnecessary.

Instanced behavior:

- host assigns `instanceID = pane.id.uuidString`;
- plugin keeps any JS state in a map keyed by that ID;
- contributions for one instance include that ID;
- native resources use the validated `(PluginID, instanceID)` ownership key.

## Workspace-owned instance state

An instanced view whose content depends on a workspace — a file tree's root, a git panel's
repository, a sessions list's project — binds that content to the workspace that OWNS its
pane, never to the globally selected workspace. The owner is resolved through the public
`workspace.state.v1` snapshot (pane → tab → workspace); events that carry `workspaceId`
(`workspace.slot-focused`) are filtered per instance against that owner. Switching the
selection therefore mutates no inactive workspace's view, and returning to a workspace
restores exactly the state it had (`WorkspaceScopedViewStateTests`).

Every shipped workspace-dependent view — `browser`, `file-explorer/tree`, `git/git`,
`claude-sessions/sessions` — is instanced. `view-gallery` stays singleton deliberately:
its demo content depends on no workspace, and one shared body across panes is the point.
Global surfaces remain selection-scoped by design: the git status bar summarises the
selected workspace and the focused pane, because "one global surface" and "one view
instance" are different owners.

## Host reconciliation

The workspace catalog is authoritative; SwiftUI appearance callbacks are not.

```text
desired = instanced plugin-view panes in WorkspaceCatalog
opened  = desired - active
closed  = active - desired

publish active = desired before callbacks
emit close facts
release closed resources
emit open facts
retain/create resources when the contributed view requires them
```

Publishing `active = desired` before callbacks makes reconciliation reentrancy-safe:
`onOpen` may immediately publish a view, causing another host publication/reconcile pass,
without opening the same instance twice.

Reconciliation triggers when:

- workspace changes add/remove/move plugin-view panes;
- a plugin generation registers its view types after panes already exist;
- a plugin is disabled, reloaded, enabled, or retired.

It is idempotent. Tab switching does not close an instance; deleting its pane does.

## Host and shell projection

An immutable projected section carries:

- `PluginID`;
- `viewID`;
- optional `instanceID`;
- title and declarative body/items;
- instanced/singleton metadata.

`PluginSlotView` selects the exact section for its pane UUID. The shell never searches by
display name and never falls back to another plugin's section.

For a web node, the renderer asks the injected `PluginWebSurfacePool` for the resource owned
by the exact key. Pool creation/removal is a typed DIRECT call. Finite navigation remains
`browser.surface.*.v1` intents.

## Lifecycle and failure

- runtime staging publishes no active instance state until atomic activation;
- retiring a generation removes its handlers/contributions and cancels pending work;
- workspace desired state survives reload, so the replacement generation receives open
  facts for still-live instances;
- a failed replacement leaves the last good generation and its resources active;
- closing one instance releases only that instance's native resource;
- stale callbacks/events carry generation identity and cannot mutate the replacement.

## Fitness functions

- catalog enumeration covers all workspaces/tabs/panes;
- two instanced panes receive distinct IDs, bodies, titles, state, and web resources;
- singleton views remain one section with no instance lifecycle;
- reconcile is idempotent and reentrancy-safe;
- move/tab switch preserves an instance; close releases it exactly once;
- plugin reload targets the active generation and leaks no old callback/resource;
- plugins never receive WebKit/terminal native objects;
- no lifecycle request is modeled as an intent;
- browser navigation is available only through declared intents;
- Swift 6 build and full tests pass.

Falsification: if SwiftUI visibility controls lifetime, a hidden tab will destroy live state
and the source of truth is wrong. If two plugins can collide on a surface ID, the ownership
key is incomplete. If view open/close needs provider resolution or a caller result, the
current contribution lifecycle contract must be revised explicitly.
