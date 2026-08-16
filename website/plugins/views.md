# Views

A view is a **declarative snapshot**. You publish a JSON tree; the host renders
it recursively as native SwiftUI, themed from Tenon's own theme, so it looks
native and tracks light and dark for free.

You do not get a DOM, a canvas, or a diffing API. You publish the current state
and the host draws it.

```js
tenon.views.register("ci", { title: "CI", instanced: false })

tenon.views.set("ci", {
  body: {
    type: "vstack",
    spacing: 8,
    children: [
      {
        type: "card",
        children: [
          {
            type: "hstack",
            children: [
              { type: "text", value: "Build passing", weight: "semibold" },
              { type: "spacer" },
              { type: "badge", value: "main", tint: "green" },
            ],
          },
          { type: "text", value: "1,204 tests · 2.1s", style: "caption", color: "muted" },
          { type: "button", label: "Rerun", action: "rerun", style: "primary" },
        ],
      },
    ],
  },
})

tenon.views.onSelect("ci", (action) => {
  if (action === "rerun") runCI()
})
```

## The node vocabulary

Two tiers, and the split is deliberate.

**Tier 1 — layout primitives.** A plugin is never blocked waiting for a
component to exist:

| Node | Fields |
|---|---|
| `vstack`, `hstack` | `spacing`, `children[]` |
| `box` | `padding?`, `background?`, `cornerRadius?`, `width?` (60…1200; omitted fills), `children[]` |
| `scroll` | `axis` ∈ `horizontal \| vertical \| both` (unknown → `vertical`), `children[]` |
| `grid` | `columns` (≥1), `spacing`, `children[]` |
| `text` | `value`, `style`, `weight`, `color` |
| `image`, `spacer`, `divider` | — |

**Tier 2 — opinionated components**, composed from tier 1 so they are pretty and
consistent by default:

| Node | Fields |
|---|---|
| `card` | `children[]` |
| `badge` | `value`, `tint` |
| `button` | `label`, `action`, `style` |
| `stat` | `label`, `value` |
| `keyValue` | `label`, `value`, `tint?` |
| `progress` | `value` (clamped 0…1), `tint?` |
| `field` | `label`, `children[]` |

A "card" the host has not shipped is a `box` with a background and a corner
radius. Composition, not a feature request. Tier 2 grows as real needs appear
and never faster.

## Style is tokens, not CSS

| Token | Values |
|---|---|
| `color` / `tint` | `default`, `text`, `muted`, `amber`, `green`, `red` |
| `style` | `title`, `body`, `caption`, `code` |
| `weight` | `regular`, `medium`, `semibold` |
| button `style` | `primary`, `plain` |
| numeric | `spacing`, `padding`, `cornerRadius` |

There is no free-form CSS on purpose. Every plugin stays visually consistent
with the host and with each other — and a language model writing a plugin needs
no taste to produce something that looks right.

## The pane header

Your view's own state and controls go in the **one chrome header its pane
already draws**, not in a second bar you build:

```js
tenon.views.set("ci", {
  header: {
    trailing: [
      { type: "iconButton", id: "refresh", systemName: "arrow.clockwise", tooltip: "Refresh" },
    ],
  },
  body: tree,
})
```

`leading` and `trailing` are runs of a flat ten-item vocabulary — `label`,
`iconButton`, `toggle`, `segmented`, `menu`, `textfield`, and display items.
Three `iconButton`s and a flexible `textfield` make a browser toolbar; a
`segmented` control and a badge make up a diff viewer's toolbar.

Header clicks arrive at the **same `onSelect`** a body button does. A header
`textfield` commits through `onSubmit`. Omitting the `header` key clears the
previous one.

Two details that bite:

- `toggle`'s `isOn` is the item's **current** state, not the next one. You flip
  it.
- Display text truncates; identifiers do not. A label, badge, tooltip or field
  value is read by a person and may be clamped. A `value` an action resolves on
  is never silently truncated, because a truncated identifier routes to the
  wrong thing.

## Modals

A view may publish a `modal` beside its `body`, using the same node vocabulary:

```js
tenon.views.set("board", {
  body: boardTree,
  modal: {
    title: "T-101 · First thing",
    dismissAction: "close-detail",
    body: detailTree,
  },
})
```

**The plugin owns whether a modal exists; the host owns presentation.** Setting
`modal` opens it; the next `views.set` without it closes it. Escape, a backdrop
click and the close control all deliver `dismissAction` (default
`modal.dismiss`) to `onSelect`, exactly like a button. At most one is presented;
with several published, the first in publish order wins.

## Drag and drop

Two transparent wrappers, and nothing added to the `tenon` global:

```js
{ type: "dropTarget", action: "drop-into:2", children: [columnTree] }
{ type: "dragSource", payload: "T-101", children: [cardTree] }

tenon.views.onSelect("board", (action, value) => {
  if (action.startsWith("drop-into:")) {
    moveTaskToColumn(value, Number(action.slice(10)))
  }
})
```

A drop is the **target's `action` carrying the source's `payload` in the value
slot** — the same `onSelect(action, value)` a button press and a field submit
already use. Both wrappers lay their children out exactly as the subtree lays
itself out; they add a gesture and nothing else.

## Instanced views

A view registered with `instanced: true` gets one live instance per pane, each
with its own `instanceID`:

```js
tenon.views.register("file", { title: "File", instanced: true })

tenon.views.onOpen("file", (instanceID) => {
  tenon.timers.every(1000, () => refresh(instanceID), { ownedBy: instanceID })
})

tenon.views.onClose("file", (instanceID) => {
  // Optional. The host retires `ownedBy` resources after this runs anyway.
})
```

See [Resources and lifetime](/plugins/resources) for why `ownedBy` matters.

## Why not a web view

A `WKWebView` panel carries substantial memory and process cost, and loses
native consistency.

The bundled browser plugin is the deliberate, permission-gated exception: it
contributes **native** chrome and references a host-owned web resource, with
finite navigation through browser intents. WebKit is not a general free-form
plugin UI escape hatch.
