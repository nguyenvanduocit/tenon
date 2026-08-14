# The command palette

`⌘K` opens the palette. It is where plugin-owned actions surface, and it is
deliberately **not** a second command system.

## It projects intents

Every row in the palette is a projection of an intent contract that some plugin
provides. There is no separate "command" object with its own registry, its own
identifiers and its own permission story.

That matters more than it sounds. A palette row and a `tenon-cli intent send`
of the same name invoke the same contract, through the same policy checks, with
the same schema. There is no path where clicking a row does something the
contract does not describe.

A plugin exposes a row by putting presentation metadata on the provision itself:

```json
{
  "name": "dev.example.notes.new.v1",
  "title": "New note",
  "audiences": ["plugin", "user"],
  "palette": {
    "category": "Notes",
    "icon": "square.and.pencil",
    "keywords": ["note", "capture"]
  }
}
```

`palette.launcher: true` puts a provision in ordinary launchers.
`palette.fillsPane: true` marks an intent that can fill a pane handed to it in
invocation scope — add it only when that is actually true.

## Dynamic results

A static row is a fixed action. When the rows depend on what you typed — open a
file, jump to a branch, pick a session — a plugin registers a **provider**
instead, observes revisioned queries, and publishes results for that exact
revision:

```js
tenon.palette.registerProvider("files", { title: "Files" })

tenon.palette.onQuery("files", async (query) => {
  const hits = await search(query.text)
  tenon.palette.setResults("files", query.revision, hits.map(toResult))
})
```

The revision is the point. Results are published *for the query they answer*, so
a slow provider answering an old keystroke cannot overwrite the rows for the
current one. Each result invokes an intent the plugin provides — again, not a
second execution API.

## Keybindings

A plugin can register a host-wide keybinding for an intent it owns. Those are
discoverable and rebindable, and they sit alongside the built-in shortcuts.

A keyboard control that only works inside one focused view is that view's own
business and is not registered as a product keybinding — the test is whether it
is host-wide, discoverable, or rebindable outside the view that owns it.

## See also

- [Palette contributions](/plugins/palette) — building rows and providers.
- [Providing intents](/plugins/providing-intents) — the contract behind a row.
- [All intents](/reference/intents/) — everything the host itself provides.
