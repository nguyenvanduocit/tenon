# Manifest schema

`manifest.json` is decoded and validated **before** your JavaScript is
evaluated. Unknown fields inside the structured blocks are rejected rather than
ignored, so a typo is a load failure and not a silently missing feature.

## Top level

| Field | Required | Type | Notes |
|---|---|---|---|
| `id` | yes | string | stable reverse-DNS; the principal every check is made against |
| `name` | yes | string | short directory-style name |
| `version` | yes | string | your own version string |
| `permissions` | yes | string[] | see [Permissions](/reference/permissions) |
| `intents` | yes | object | required even when both arrays are empty |
| `runtime` | no | `"javascript"` \| `"bundled-swift"` | defaults to `javascript` |
| `displayName` | no | string | what a person sees |
| `icon` | no | string | SF Symbol name |
| `settings` | no | array | declarative settings UI |
| `network` | no | object | `{ "allow": [host…] }` |
| `automation` | no | object | `{ "schedules": [...] }` |
| `events` | no | object | `{ "publishes": [], "observes": [] }` |

::: warning `runtime: bundled-swift` is refused in a user inventory
It is reserved for implementations compiled into Tenon's own sealed app
inventory. It is not a native plugin SDK. Omitting `runtime` deliberately
defaults to `javascript`.
:::

## `intents`

```json
{
  "intents": {
    "uses": ["process.exec.v1"],
    "provides": [ /* provisions */ ]
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `uses` | string[] | every intent you send; sending an undeclared one fails |
| `provides` | array | contracts you serve |

### A provision

| Field | Required | Type |
|---|---|---|
| `name` | yes | string — prefix with your plugin id, versioned `.v1` |
| `title` | no | string |
| `description` | no | string |
| `audiences` | no | string[] — `user` makes it palette-invocable |
| `effects` | no | object — see below |
| `inputSchema` | no | JSON Schema |
| `outputSchema` | no | JSON Schema |
| `errors` | no | string[] — your own domain error codes |
| `palette` | no | object — see below |

### `effects`

| Field | Values |
|---|---|
| `kind` | `read`, `write`, `destructive` |
| `idempotency` | whether repeating it is safe |
| `confirmation` | `never`, `policy`, `always` |
| `external` | boolean — does it leave the machine |

### `palette`

| Field | Type | Notes |
|---|---|---|
| `category` | string | groups the row |
| `icon` | string | SF Symbol name |
| `keywords` | string[] | extra match terms |
| `key` | string | a keybinding |
| `when` | string | a condition for showing it |
| `launcher` | boolean | default `false` |
| `fillsPane` | boolean | default `false` |

`launcher` marks a **creation verb** — something that opens a terminal, a view,
an agent. The tab strip's `+` offers exactly these; the palette still offers
everything. It defaults to `false` so a destructive or navigational command
never volunteers itself under a plus sign.

`fillsPane` declares that the command can occupy a pane supplied by its
invocation scope. Empty-grid launchers project only these, because the click
already chose a destination — tab and split structure commands cannot satisfy
that action.

## `settings`

```json
{
  "settings": [
    { "key": "repoPath", "label": "Repository path", "type": "string", "default": "~" },
    {
      "key": "mode",
      "label": "Mode",
      "type": "select",
      "default": "compact",
      "options": [
        { "value": "compact", "label": "Compact" },
        { "value": "full",    "label": "Full" }
      ],
      "group": "Display"
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `key` | yes | what `tenon.settings.get` reads |
| `label` | yes | shown in Settings — **not** `title` |
| `type` | yes | `string`, `boolean`, `number`, `select` |
| `default` | no | the initial value |
| `options` | for `select` | `{ value, label }[]` — the stored value is the `value` string |
| `group` | no | section heading; omitted groups it into an unnamed leading section |

A `select` that omits `options` is a plugin bug that the UI handles by degrading,
not a manifest decode failure.

## `network`

```json
{
  "permissions": ["network"],
  "network": { "allow": ["api.github.com", "*.example.com"] }
}
```

An exact host, or a wildcard covering subdomains. **`*.example.com` does not
match `example.com`.** Matching is case-insensitive, and an empty or missing
allowlist grants nothing.

## `automation`

```json
{
  "automation": {
    "schedules": [
      { "id": "tick", "every": "1m" },
      { "id": "morning", "daily": "09:00", "grace": "2h" }
    ]
  }
}
```

| Field | Rule |
|---|---|
| `id` | unique per plugin, 1…64 bytes |
| `every` \| `daily` | **exactly one** per schedule |
| `every` | `"<positive integer><s\|m\|h\|d>"`, min `1m`, max `7d` |
| `daily` | zero-padded 24-hour `"HH:mm"`, machine-local |
| `grace` | optional `1m`…`7d`; defaults to one interval for `every`, `6h` for `daily` |

At most 8 schedules per plugin. Validation is fail-closed at decode with strict
unknown-field rejection. → [Automations](/plugins/automations)

## `events`

```json
{
  "events": {
    "publishes": ["index.changed"],
    "observes": ["dev.example.other/cache.changed"]
  }
}
```

`publishes` uses your **local** channel name — the host qualifies it as
`<your-id>/<name>` on the way out, so a plugin can only publish under its own
id. `observes` uses the **fully qualified** name.

→ [Events](/plugins/events)

## Complete example

```json
{
  "id": "dev.example.notes",
  "name": "notes",
  "displayName": "Notes",
  "version": "0.2.0",
  "icon": "note.text",
  "permissions": ["filesystem.read", "filesystem.write"],
  "settings": [
    { "key": "root", "label": "Notes folder", "type": "string", "default": "~/notes" }
  ],
  "events": { "publishes": ["index.changed"], "observes": [] },
  "automation": { "schedules": [{ "id": "reindex", "every": "15m" }] },
  "intents": {
    "uses": ["filesystem.directory.list.v2", "filesystem.file.read.v1"],
    "provides": [
      {
        "name": "dev.example.notes.new.v1",
        "title": "New note",
        "description": "Creates a note and opens it.",
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
          "properties": { "title": { "type": "string" } },
          "required": ["title"],
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "palette": {
          "category": "Notes",
          "icon": "square.and.pencil",
          "keywords": ["note", "capture"],
          "launcher": true
        }
      }
    ]
  }
}
```
