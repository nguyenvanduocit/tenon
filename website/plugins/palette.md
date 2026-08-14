# Palette contributions

The palette (`⌘K`) is a **projection of intent contracts**, not a second command
system. There are two ways to appear in it.

## Static rows

The simplest case needs no code at all. Put `palette` metadata on a contract you
provide, and the host projects the row before your JavaScript runs:

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

| Field | Effect |
|---|---|
| `category` | groups the row |
| `icon` | an SF Symbol name |
| `keywords` | additional match terms |
| `launcher` | `true` exposes it in ordinary launchers |
| `fillsPane` | `true` marks an intent that can fill a pane given in invocation scope |

Add `fillsPane` only when it is actually true. It is a promise about what
happens when a pane is handed to the contract.

## Dynamic providers

When the rows depend on what was typed — a file, a branch, a session — register
a provider and answer queries:

```js
tenon.palette.registerProvider("files", { title: "Files" })

tenon.palette.onQuery("files", async (query) => {
  const hits = await search(query.text)
  tenon.palette.setResults("files", query.revision, hits.map(toResult))
})
```

### The revision is the whole design

Results are published **for the exact query revision that asked for them**.

Without that, a slow provider answering keystroke 3 would overwrite the rows for
keystroke 5, and the palette would flicker backwards under the user's hands.
With it, a stale answer is simply dropped.

Never cache a revision and reuse it. Publish for the one you were handed, or not
at all.

### Classification

Registration and each result snapshot are **CONTRIBUTIONS** — state the host
renders and indexes. `onQuery` subscribes to owner-scoped palette query
**EVENTS**. Nothing here is a second execution API: each result invokes an
intent your plugin provides.

## Keybindings

A plugin can register a host-wide keybinding for an intent it owns. It is
discoverable and rebindable, and it sits alongside the built-in shortcuts.

The test for whether something belongs here: is it **host-wide, discoverable, or
rebindable outside the view that owns it**? A keyboard control that only works
inside one focused view is that view's own local business and stays there.

## Why not a command registry

Tenon had one and deleted it.

A separate command object means a second identifier space, a second permission
story, and two things to keep in sync — and inevitably a path where a command
does something its contract does not describe. Projecting the contract itself
means the palette row and a programmatic `intents.send` are the same operation
through the same checks, and there is no second thing to get wrong.

See [`plugin-migration-v0.2.md`](https://github.com/nguyenvanduocit/tenon/blob/main/docs/plugin-migration-v0.2.md)
if you are porting from that era.
