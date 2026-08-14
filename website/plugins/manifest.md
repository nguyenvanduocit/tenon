# The manifest

`manifest.json` is everything the host must know **before** it evaluates a line
of your JavaScript. That ordering is the whole point: permissions, intent
declarations, settings, schedules and presentation are validated, authorized and
projected before your code can run.

A declaration here is not documentation. It is the grant.

## Minimum viable manifest

```json
{
  "id": "dev.example.my-plugin",
  "name": "my-plugin",
  "displayName": "My Plugin",
  "version": "0.1.0",
  "permissions": [],
  "intents": { "uses": [], "provides": [] }
}
```

The `intents` envelope is required even when both arrays are empty.

## Identity

| Field | Notes |
|---|---|
| `id` | Stable reverse-DNS, unique across inventories. It is the principal every check is made against |
| `name` | Short directory-style name |
| `displayName` | What a person sees |
| `version` | Your own version string |
| `runtime` | `javascript` (default) or `bundled-swift` |

::: warning `runtime: bundled-swift` is not for you
It is reserved for implementations compiled into Tenon's own sealed app
inventory. It is **not** a native plugin SDK, and a user-inventory manifest
naming it is refused before activation. Omitting `runtime` deliberately defaults
to `javascript`.
:::

Changing an ID's inventory class — bundled-equivalent to untrusted, or back —
rotates its installation identity. A downgrade starts disabled and cannot
inherit the former principal's settings, storage, secrets or standing consent.

## Permissions

Ten exist. They cover only sensitive capabilities; nothing else needs one.

| Permission | Grants |
|---|---|
| `terminal.read` | reading terminal state, and `terminal.*` event topics |
| `terminal.write` | writing into a terminal |
| `filesystem.read` | reading the filesystem |
| `filesystem.write` | writing the filesystem |
| `process.exec` | spawning processes |
| `workspace.control` | driving the workspace |
| `web.view` | a web surface |
| `shell.open` | handing a path to the OS — Finder reveal, or open in the owning app |
| `network` | HTTP requests — **not sufficient alone**, see below |
| `secrets` | this plugin's own Keychain items |

Two are worth reading twice.

**`shell.open` is a real escalation.** The host performs it, because AppKit
lives in the shell — but launching another application is a genuine privilege,
which is why it is a permission rather than a free operation.

**`network` grants nothing on its own.** Unlike every other permission, it must
be paired with an explicit host allowlist:

```json
{
  "permissions": ["network"],
  "network": { "allow": ["api.github.com", "*.example.com"] }
}
```

An entry is an exact host or a wildcard covering subdomains. `*.github.com`
does **not** match `github.com` itself. Declaring `network` with no allowlist
grants access to nothing — "can reach the network" is deliberately never the
same grant as "can reach anywhere".

A permission you do not need is a permission you should not declare. The
manifest is what a person reads before enabling your plugin, and enabling one is
[a decision to run its code in-process](/guide/managing-plugins#two-inventories-two-levels-of-trust).

## Intents

```json
{
  "intents": {
    "uses": ["process.exec.v1", "ui.toast.v1"],
    "provides": [ /* full contracts — see below */ ]
  }
}
```

`uses` lists every intent you send. Sending an undeclared one fails.

`provides` declares contracts you serve, in full, so the host can validate,
authorize and project them before your JavaScript runs. See
[Providing intents](/plugins/providing-intents) for the complete shape.

## Events

Publishing and observing are two independent declarations:

```json
{
  "events": {
    "publishes": ["index.changed"],
    "observes": ["dev.example.other/cache.changed"]
  }
}
```

A publisher declares only its **local** name. The host qualifies it on the way
out, so `index.changed` reaches observers as
`dev.example.my-plugin/index.changed` — a plugin can only publish under its own
id, and cannot forge another's.

An observer declares the **fully qualified** channel.

## Settings

Declared settings become real UI in Tenon's Settings, and `tenon.settings.get`
reads them:

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

See [Settings and storage](/plugins/settings-and-storage).

## Automation schedules

Wall-clock cadences, fired back as the owner-scoped `automation.fired` event:

```json
{
  "automation": {
    "schedules": [
      { "id": "tick", "every": "1m" }
    ]
  }
}
```

This is the exact shape the bundled `clock` plugin uses. See
[Automations](/plugins/automations).

## A worked example

The bundled `hello-palette` plugin, complete — two provisions projected into the
palette, no permissions beyond terminal reads:

```json
{
  "id": "dev.tenon.hello-palette",
  "name": "hello-palette",
  "version": "0.1.0",
  "permissions": ["terminal.read"],
  "intents": {
    "uses": [],
    "provides": [
      {
        "name": "dev.tenon.hello-palette.greet.v1",
        "title": "Say Hello",
        "description": "Writes the next greeting to the plugin log.",
        "audiences": ["plugin", "user"],
        "effects": {
          "kind": "write",
          "idempotency": "none",
          "confirmation": "never",
          "external": false
        },
        "inputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "palette": {
          "category": "Hello",
          "icon": "hand.wave",
          "keywords": ["hello", "greet"]
        }
      }
    ]
  }
}
```

Its entire `main.js` is fourteen lines. That ratio is normal and intended: the
manifest carries the contract, the code carries the behaviour.

## Full field reference

[Manifest schema](/reference/manifest-schema).
