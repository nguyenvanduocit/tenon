# Migrating plugins from API v0.2

**Status:** current migration guide · **Reviewed:** 2026-08-06

The v0.2 handwritten capability helpers, command registry, sidebar surface, and imperative
workspace namespace were deleted. There is no compatibility shim. Migrate the manifest and
JavaScript together so the plugin either loads completely or fails loudly during staging.

## Mapping

| Removed v0.2 shape | Current shape |
|---|---|
| finite filesystem helpers | declare and send `filesystem.*.v1` intents |
| collected process callback | declare and send `process.exec.v1` |
| terminal write helper | declare and send `terminal.write.v1` with pane scope |
| workspace getter/mutations | declare and send `workspace.*.v1` intents |
| runtime command registration | declare a plugin-owned intent contract and bind it with `tenon.intents.handle` |
| sidebar publication/selection | pane-hosted `tenon.views.register/set/onSelect` |
| long process or filesystem callback | `tenon.process.stream` or `tenon.fs.watch` resource |
| host/plugin notifications | declared `tenon.events.emit/on` channels |

The removed names are intentionally absent from the runtime. Do not polyfill them: that
would recreate an ungoverned public path and fail the architecture fitness suite.

## Example: finite host operation

Before, JavaScript called a capability-specific helper and supplied a callback. Now the
manifest declares both the intent and its authority:

```json
{
  "permissions": ["filesystem.read"],
  "intents": { "uses": ["filesystem.directory.list.v2"] }
}
```

```js
const result = await tenon.intents.send("filesystem.directory.list.v2", {
  path: root,
  includeMetadata: true
});
if (!result.ok) throw new Error(result.error.code);
// `path` is the directory the host resolved and opened, so child paths built
// from it are absolute even when `root` was spelled with a "~".
for (const entry of result.value.entries) {
  render({
    path: result.value.path + "/" + entry.name,
    isDirectory: entry.isDirectory,
    // Both are null when that entry's metadata could not be read, and absent
    // entirely unless `includeMetadata` was set.
    size: entry.sizeBytes,
    modified: entry.modifiedAt
  });
}
```

## Example: command to plugin-owned intent

Move title, schema, audiences, effects, palette metadata, and optional keybinding into one
manifest provision. Bind its implementation during plugin startup:

```js
function refresh() {
  // ordinary local JavaScript: do not self-send this function
}

tenon.intents.handle("dev.example.plugin.refresh.v1", async () => {
  await refresh();
  return {};
});
```

Palette, registered product keybindings, other plugins, CLI, and agents invoke the same
contract when their declared audience and policy allow it. Focused-view keyboard handling
inside one plugin view remains local JavaScript/UI control.

## Example: sidebar to pane-hosted view

Register one view, publish its immutable specification, and consume structured selection
facts:

```js
tenon.views.register("tree", { title: "Files", instanced: true });
tenon.views.set("tree", {
  body: {
    type: "list",
    items: [{ id: "readme", title: "README.md" }]
  }
});
tenon.views.onSelect("tree", (action, value, instanceID) => {
  openSelected(action, value, instanceID);
});
```

Opening or focusing the pane itself is a finite workspace intent. View publication never
imperatively changes workspace state.

## Checklist

1. Add a stable reverse-DNS `id` and a complete `intents` envelope.
2. Put every sent name in `intents.uses` and every handled name in
   `intents.provides`.
3. Add only the capabilities and network hosts required by those operations.
4. Replace finite callbacks with awaited intent results; keep callbacks only for events,
   resources, and view/palette facts.
5. Replace command registrations with plugin-owned intent metadata.
6. Replace sidebar state with a pane-hosted view contribution.
7. Run the removed-surface sweep from [`operations.md`](operations.md#verification-receipt).
8. Launch from an untrusted development inventory and explicitly enable the plugin; verify
   denied, prompted, successful, reload, and disable paths.

See [`plugin-author-guide.md`](plugin-author-guide.md) for complete current examples and
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md) for the
normative classification and public inventory.
