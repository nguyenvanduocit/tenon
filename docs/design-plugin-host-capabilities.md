# Host capabilities for plugins

**Status:** reconciled with the interaction boundary law · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Goal

A plugin can ask Tenon to perform sensitive filesystem, OS, clipboard, process, network,
terminal, workspace, browser, UI, and secret operations without receiving native AppKit,
Ghostty, WebKit, Foundation I/O, or host-model objects.

Every finite plugin→host capability is a canonical intent. Declarative pixels remain
contributions. Long-lived output/watch lifetimes remain resources.

## One semantic implementation

```text
plugin
  │ tenon.intents.send
  ▼
IntentDispatcher
  │ contract + principal + capability + scope + admission
  ▼
typed provider adapter
  │
  ▼
typed application service / AppKit adapter / resource owner
```

The intent provider validates boundary values and adapts them to typed services. It MUST
NOT duplicate filesystem, workspace, or surface behavior that an internal Swift caller uses
DIRECT.

AppKit remains in `TenonApp`. The contract and typed application port remain free of AppKit
and SwiftUI.

## Capability bindings

Declaring an intent in `manifest.intents.uses` designates the operation. It does not grant
authority. Policy separately checks:

- calling `PluginID` and active generation;
- exact contract audience;
- required permission;
- filesystem path/network URL extracted from canonical JSON pointers;
- invocation workspace/pane scope;
- confirmation/consent;
- provider eligibility and readiness.

The principal never gains authority by choosing an intent name or provider.

Current sensitive bindings:

| Capability | Intents/resources |
|---|---|
| `filesystem.read` | directory list, file read, path exists, filesystem watch |
| `filesystem.write` | file write/create, directory create, path move/trash |
| `shell.open` | file reveal/open |
| `clipboard.write` | `clipboard.write.v1` |
| `process.exec` | collected process intent and streaming process resource |
| `terminal.write` | terminal write/run |
| `terminal.read` | terminal facts, viewport read, terminal wait as policy requires |
| `workspace.control` | workspace mutation intents |
| `web.view` | browser surface navigation intents |
| `network` + manifest host allowlist | network fetch |
| `secrets` | secret get/set/delete |

Clipboard write is a plugin-only contract with a `clipboard.write` capability grant. The
grant is installation/enablement-scoped standing authority, so trusted bundled plugins do
not prompt on every copy, while a plugin that has not declared the permission cannot replace
the system clipboard. The intent remains bounded and has no per-call confirmation because the
grant is the policy boundary; in-app UI intents remain user-mediated and need no capability.
Clipboard read does not exist.

## Filesystem semantics

Canonical operations:

- `filesystem.directory.list.v2`;
- `filesystem.file.read.v1`;
- `filesystem.path.exists.v1`;
- `filesystem.file.write.v1`;
- `filesystem.directory.create.v1`;
- `filesystem.file.create.v1`;
- `filesystem.path.move.v1`;
- `filesystem.path.trash.v1`.

Rules:

- all paths are absolute, canonical boundary values;
- a create operation fails rather than silently replacing an existing item;
- path move names source and destination explicitly and policy inspects both;
- deletion uses recoverable system Trash;
- inline contents are bounded; larger bodies use resource handles;
- filesystem work runs off `MainActor`;
- errors use the declared domain vocabulary and never silently no-op.

`filesystem.directory.list.v2` replies with `path` — the resolved absolute directory the
host opened, which is what a caller joins child names onto — and `entries` of `{name,
isDirectory}`. That is the whole entry by default. Sending `includeMetadata: true` adds
`sizeBytes` and `modifiedAt` (ISO-8601 UTC) to every entry, each `null` when that entry's
metadata could not be read; leave the flag off and the two keys are simply absent. The flag
costs one `stat` per entry, so a caller rendering names alone should not set it.

Path string manipulation is `tenon.path.*` pure DIRECT code. It provides no filesystem
authority.

## OS and clipboard semantics

- `file.reveal.v1` reveals a validated path in the system file browser;
- `file.open.v1` opens a validated path with the trusted/default or explicitly selected
  eligible provider;
- `clipboard.write.v1` writes bounded text.

The AppKit adapter performs the final `NSWorkspace` or pasteboard operation on the required
actor. Path validation and authorization happen immediately before use so a prior check
cannot become a time-of-check/time-of-use promise.

## Declarative UI affordances

Rows and view trees are CONTRIBUTIONS:

```js
tenon.views.set("tree", {
  title: "Files",
  header: {
    leading: [
      { type: "label", id: "root", text: repo, color: "muted", truncation: "head" }
    ],
    trailing: [
      { type: "iconButton", id: "refresh", systemName: "arrow.clockwise",
        tooltip: "Refresh" }
    ]
  },
  items: [{
    id: "opaque-row-id",
    label: "README.md",
    path: "/abs/path/README.md",
    selected: true,
    menu: [
      { id: "open", label: "Open" },
      { id: "reveal", label: "Reveal in Finder" },
      { id: "trash", label: "Move to Trash", destructive: true }
    ]
  }]
});
```

The plugin contributes data; the host renders native controls. User selections are
owner-scoped contribution callbacks. The plugin then sends the appropriate canonical intent.

`id` is opaque plugin identity. `path` is explicit drag/file metadata; the host MUST NOT
guess that a row ID is a path.

`header` is what the view says about itself — its state, its path, its controls — placed
in the ONE chrome header its pane already draws, and is the reason a contributor needs no
chrome bar of its own. It reaches a rows pane and a `body` pane alike; the host owns
decoding, bounds, measurement, folding, drawing, and hit testing.
[`design-pane-header.md`](design-pane-header.md) owns the schema and the item vocabulary.

Inline edit commits use `onSubmit`; selection/menu/header actions use `onSelect`. Keeping
the two fact shapes separate prevents typed text from being confused with an action ID.

## Resource capabilities

Collected process execution uses `process.exec.v1`. Live output uses
`tenon.process.stream`, whose bounded resource protocol defines stdout/stderr chunks,
overflow, exit, cancellation, and generation teardown. Its current Foundation `Process`
backend is leader-scoped, so process-tree containment is not yet a guaranteed property.

Filesystem change observation uses `tenon.fs.watch`, whose bounded resource protocol
defines event delivery, overflow, cancellation, and generation teardown.

No plugin receives `Process`, `FileHandle`, FSEvent stream, `NSWorkspace`, pasteboard,
terminal, or WebKit objects.

## Network and secrets

`network.fetch.v1` requires both the `network` capability and a manifest host allowlist.
An exact/wildcard host match grants only that destination; it is not a global internet
grant. Redirect targets are re-authorized.

`secrets.get.v1`, `secrets.set.v1`, and `secrets.delete.v1` use the Keychain under a
plugin-isolated namespace. Secret values never enter plugin JSON storage, logs, telemetry,
or broad discovery.

## Fitness functions

- every finite host capability appears in `CoreIntentName` and the canonical catalog;
- every provider binding uses the declared capability/path/URL pointers;
- plugins can invoke only manifest-declared uses;
- AppKit/WebKit/Ghostty objects never cross into `TenonCore` or JavaScript;
- filesystem destructive tests prove recoverable Trash and no silent replacement;
- network redirect and wildcard tests enforce the allowlist;
- secret tests prove no value reaches plugin storage/logs;
- resource teardown tests prove no callback survives runtime retirement;
- contribution parsing performs no host mutation;
- Swift 6 warnings-as-errors build and full tests pass.

Falsification: if a finite capability needs a handwritten bridge outside the dispatcher,
the catalog/provider is incomplete. If the caller receives multiple values or a lifetime
handle that remains usable after the initial reply, it requires a resource protocol. If
the host only renders plugin-owned data, it is a contribution and needs no imperative
capability path.
