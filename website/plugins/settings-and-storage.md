# Settings and storage

Three facilities, and the list is **closed**: `tenon.settings`, `tenon.storage`,
`tenon.log`. Every other finite plugin→host operation is an
[intent](/plugins/sending-intents).

## Settings

Declare them in the manifest; the host builds real Settings UI from the
declaration.

```json
{
  "settings": [
    {
      "key": "repoPath",
      "label": "Repository path",
      "type": "string",
      "default": "~"
    }
  ]
}
```

```js
const root = (tenon.settings.get("repoPath") || "").trim()
```

Settings are **read-only from JavaScript**. A person changes them in Settings;
your plugin observes the result. There is no `settings.set`, deliberately — a
plugin quietly rewriting the preferences a person set is not a feature.

## Storage

Plugin-private, non-secret JSON state:

```js
const seen = tenon.storage.get("seenIDs") ?? []
seen.push(id)
tenon.storage.set("seenIDs", seen)
```

It is scoped to your installation identity. Another plugin cannot read it, and
it does not survive an identity rotation — uninstall/reinstall, or moving the
plugin between trusted and untrusted inventories, starts you empty.

::: danger Storage is a JSON file, not a vault
`tenon.storage` is a JSON file sitting next to the plugins. It is the right
place for a cursor, a cache key, or a list of dismissed items.

It is the **wrong** place for a token. Secrets go in the Keychain, through
`secrets.get.v1` / `secrets.set.v1` / `secrets.delete.v1` with the `secrets`
permission — a separate namespace per caller, and a separate decision by whoever
enables your plugin.
:::

## Log

```js
tenon.log("index rebuilt", count, "entries")
```

Logs are attributed per plugin. This is why the bootstrap **deletes `console`**: a plugin
logging through `console` would reach the system log unattributed, going around
that attribution.

When a plugin misbehaves, attributed logs are how the person running Tenon finds
out which one. Do not try to route around it.

## Path helpers

```js
tenon.path.join(root, "src", "main.js")
tenon.path.normalize(messy)
tenon.path.basename(p)
tenon.path.dirname(p)
tenon.path.extname(p)
```

Pure string functions. They perform **no filesystem I/O** — `path.join` does not
check that anything exists, and cannot. Reading the filesystem is
`filesystem.file.read.v1` with the `filesystem.read` permission.

They need no permission precisely because they touch nothing.

## Why this list is closed

Settings, private storage and logging are a plugin talking about **itself** —
its own configuration, its own state, its own diagnostics. Nothing crosses an
ownership boundary, so nothing needs a contract, an audience or a capability
check.

The moment an operation touches something the plugin does not own — a file, a
process, a terminal, the clipboard, the network, another plugin — it crosses a
boundary, and boundaries are what intents are for. Adding a fourth facility
would mean finding an operation that is finite, cross-owner, and somehow exempt
from policy. There is not one.
