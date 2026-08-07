# Plugin view-tree — a native, composable UI vocabulary

**Status:** landed; boundary reconciliation accepted · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Problem

A plugin's slot view could describe only a flat list of rows (`PluginRowItem`:
`{id, label, depth?, icon?, expanded?}`). A plugin that wanted a card, a form,
a stat panel — anything that is not a tree of rows — had no way to express it and
had to wait for the host to grow a bespoke feature. That breaks the founding
"AI-writable / replaceable everything" promise: the plugin is blocked on us.

### Current relevance — 2026-07-30

The landed view-tree also lets agent adapters and supervision experiments express native
attention, context, and evidence surfaces through the governed public boundary without
waiting for bespoke host UI.

## Decision

`tenon.views.set(id, spec)` accepts a **view-tree** under `body`: a JSON tree of
typed nodes that the host renders recursively as native SwiftUI, themed from
`TenonTheme` (so it looks native and tracks light/dark for free). The tree has
**two tiers**:

- **Tier 1 — layout primitives** (a plugin is never blocked): `vstack`, `hstack`,
  `grid`, `box`, `scroll`, `text`, `image`, `spacer`, `divider`. A "card" the host
  has not shipped is just a `box` with a background + corner radius. Composition,
  not a feature request.
- **Tier 2 — opinionated components** (pretty + consistent by default, composed
  from tier 1): `card`, `badge`, `button`, plus the status/dashboard set `stat`,
  `keyValue`, `progress`, and `field`.
  Added as real needs appear, never faster than that.

Field/token reference for the current set:

| node | fields |
| --- | --- |
| `box` | `padding?`, `background?`, `cornerRadius?`, `width?` (clamped 60…1200; omitted means fill), `children[]` |
| `scroll` | `axis` ∈ `{horizontal,vertical,both}` (unknown → `vertical`), `children[]` |
| `grid` | `columns` (≥1), `spacing`, `children[]` |
| `stat` | `label`, `value` |
| `keyValue` | `label`, `value`, `tint?` |
| `progress` | `value` (clamped 0…1), `tint?` |
| `field` | `label`, `children[]` |

Style is expressed with **enum tokens, not free CSS**, so every plugin stays
visually consistent and an LLM needs no taste: `color`/`tint` ∈
`{default,text,muted,amber,green,red}`, `style` ∈ `{title,body,caption,code}`,
`weight` ∈ `{regular,medium,semibold}`, button `style` ∈ `{primary,plain}`,
plus numeric `spacing`/`padding`/`cornerRadius`.

Why native declarative UI remains the default: a `WKWebView` panel has substantial
memory/process cost and loses native consistency. The browser plugin is the concrete
permission-gated exception: it contributes native chrome and references a host-owned web
resource; finite navigation uses browser intents. WebKit is not a general free-form plugin
UI escape hatch.

## Shape

```js
tenon.views.set("ci", {
  title: "CI",
  body: { type: "vstack", spacing: 8, children: [
    { type: "card", children: [
      { type: "hstack", children: [
        { type: "text", value: "Build passing", weight: "semibold" },
        { type: "spacer" },
        { type: "badge", value: "main", tint: "green" },
      ]},
      { type: "text", value: "1,204 tests · 2.1s", style: "caption", color: "muted" },
      { type: "button", label: "Rerun", action: "rerun", style: "primary" },
    ]},
  ]}
})
tenon.views.onSelect("ci", (id) => { if (id === "rerun") runCI() })
```

A view may also publish a **modal** beside its `body` — the same node vocabulary,
presented by the host as a sheet over the whole shell:

```js
tenon.views.set("board", {
  body: boardTree,
  modal: { title: "T-101 · First thing", dismissAction: "close-detail", body: detailTree },
})
```

The plugin owns whether a modal exists: setting `modal` opens it, the next `views.set`
without it closes it. The host owns presentation and dismissal — Escape, a click on the
backdrop, and the close control all deliver `dismissAction` (default `modal.dismiss`) to
the view's `onSelect`, exactly like a `button`. At most one modal is presented at a time;
with several published, the first in publish order wins.

## Contracts

- **This surface is CONTRIBUTION.** `views.register/set` publishes plugin-owned
  declarative state. The host validates, snapshots, diffs, and renders it. Workspace,
  filesystem, browser, terminal, and OS mutations triggered by a user action use canonical
  intents from the callback.
- **One shape everywhere.** `views.set` takes either `body` (a node tree) or
  `items` (rows). `body` wins when present. Rows are not the poor cousin: a row
  carries `menu`, `editing`/`placeholder`, `selected` and `path` — enough for the
  Files pane to be a full file manager without a single node (T-014, see
  `design-plugin-host-capabilities.md`).
- **A row's list is the host's ONE list.** `items` are decoded into `TreeRowItem`, which is
  also what host-native panes build in Swift — the Changes pane and the Files pane are drawn
  by the same `TreeRowsView`. The type is named for its shape rather than its publisher
  because both mint it; what keeps the boundary intact is that a plugin's rows arrive only
  through this decoder, never as a native type reaching JavaScript (invariants 2 and 6).
  Three fields serve the denser lists (T-085):

  | Field | Meaning |
  |---|---|
  | `kind` | `"row"` (default) or `"sectionHeader"` — a heading over the rows beneath it, drawn small, tracked and muted, with no chevron, hover, menu or selection. A member of the row vocabulary so headings and rows can interleave in one scroll. |
  | `detail` | Muted secondary text after the label — a containing directory, a timestamp. Gives up its width before the label does. |
  | `accessory` | `{ text, tint }` at the trailing edge: a git status letter, a count. At most four characters, so the right-hand column stays a column a human can scan down. |

  Both new fields are additive and fail-soft, like every other token field here: an
  unrecognised `kind` or `tint` degrades to its default, and an empty or over-long
  `accessory` costs the accessory alone. A malformed decoration never drops the row — a
  row that vanishes is a file missing from a list someone is using to decide what to read.
- **A view's chrome is `header`, and the pane draws it.** What a view has to say about
  itself — its state, its path, its controls — goes in the ONE chrome header its pane
  already draws, published as `header: { leading: [], trailing: [] }` beside `items` or
  `body`. It reaches a rows pane and a body pane alike. A flat, non-recursive vocabulary
  of ten items (`dot`, `label`, `badge`, `image`, `spinner`, `iconButton`, `toggle`,
  `segmented`, `menu`, `textfield`) keeps the states a 34-point strip cannot express
  unrepresentable rather than silently dropped, and it is why no plugin needs a chrome
  bar of its own: three `iconButton`s and a flexible `textfield` are a browser toolbar.
  A missing required field costs that one item its place and names it in the plugin's
  log; an unknown token degrades to its default; `accessibilityID` is host-only and is
  never read from plugin JSON. Omitting `header` clears the previous one, the way
  omitting `modal` closes a sheet.
- **Actions reuse the select handler.** A `button`'s structured `action` value is delivered
  to the view's existing `onSelect` handler, as is a row's action/id. No new API
  surface — a button click, a row click, a row's context-menu pick (the menu id
  arrives in the value slot) and a header action are all the same event.
  `onSubmit` is the single exception: committed inline-edit text needs its own
  callback, or a file renamed to "trash" would be indistinguishable from the
  Move-to-Trash menu entry.
- **Malformed nodes never escape into the host.** An unknown `type`, a `text` without `value`, a
  container without `children` → the node is skipped and a load-time log names the
  fix. One bad node cannot blank the whole view or kill the plugin.
- **Contribution authority.** View contribution needs no sensitive capability because it
  is declarative plugin-owned data validated and rendered by the host. Any finite
  filesystem, workspace, browser, terminal, or OS action triggered by it still crosses
  the intent policy path.
- **Plugin parity.** Every plugin, bundled or third-party, receives the same public
  contribution surface and plugin principal rules.
- **Core owns the rules.** `PluginViewNode` is a pure value tree in `TenonCore`,
  asserted in `PluginViewsTests` without a window. `TenonApp` only paints it.
