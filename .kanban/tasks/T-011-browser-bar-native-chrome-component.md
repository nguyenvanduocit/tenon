# T-011: `browserBar` native chrome component
> Add a Tier-2 view-tree component `browserBar` — a host-rendered native browser
> toolbar (SF Symbol back/forward/reload + Safari-style address field, proper
> padding + bottom divider) — and refactor the browser plugin to use it instead of
> hand-assembling `hstack` + raw-glyph `button`s + `textfield`. Presentation only:
> the plugin keeps all navigation logic (resolve/search-engine/state) and drives
> `tenon.web`; the bar just emits fixed action ids `back`/`forward`/`reload`/`go`
> to `onSelect`, exactly like `button`/`textfield` do.

- **priority**: high
- **effort**: S

## Design decision (user, 2026-07-24)
Chose "browserBar (presentation-only)" over a full trọn-gói `browser` node: host owns
LOOK, plugin owns LOGIC. Keeps every invariant (2/5/6), search-engine setting stays a
plugin setting, plugin stays replaceable. Reason the current UI is ugly: chrome is built
from raw primitives (`‹ › ⟳` glyph buttons + bare textfield, no toolbar container).

## Owner / files (agent lock)
session 4564041c — RELEASED (done, 297/297 green). Files below are free.
- poc/Sources/TenonCore/PluginViewNode.swift (add `case browserBar`)
- poc/Sources/TenonCore/PluginRuntime.swift — **parseNode switch + default log line only
  (~873-887)**; DISTINCT from T-006's parseContentSpec (~745). Not touching that region.
- poc/Sources/TenonApp/BuiltInSlotViews.swift — **PluginNodeView switch (~811) + new
  BrowserBarView struct only**; not touching DiffSlotView (T-010) or the row renderer.
- poc/plugins/browser/main.js (use browserBar)
- poc/Tests/TenonCoreTests/PluginViewsTests.swift (add browserBar parse test)
- poc/Tests/TenonCoreTests/ShippedPluginsTests.swift (browser chrome assert: hstack→browserBar)

## Criteria
- [x] `PluginViewNode.browserBar(url:placeholder:)` added; pure value in TenonCore (invariant 3)
- [x] `parseNode` parses `{type:"browserBar", url?, placeholder?}` with defaults (never blocked); default-log known-types list updated
- [x] Host renders a native toolbar: SF Symbol chevron.left/right + arrow.clockwise, Safari-style address field, padding + bottom divider; emits `back`/`forward`/`reload`/`go(text)` via onSelect
- [x] browser plugin main.js uses `browserBar`; navigation logic + search-engine resolution stay in the plugin (invariant 2/6 intact — no new capability, free tier)
- [x] `ShippedPluginsTests` updated to assert the browser chrome is a `browserBar`
- [x] swift build + swift test green (297); app builds/links; browser plugin loads via JSContext end-to-end in ShippedPluginsTests
- GUI note: the actual toolbar look is only verifiable by a human running the app (not smoked here — repo convention).
