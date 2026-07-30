# T-004: Plugin view-tree component vocabulary
> Plugins describe rich native UI (card/stack/text/button/badge) as a JSON view-tree via `tenon.views.set(id, {body})`, rendered by SwiftUI; when a component is missing they compose it from layout primitives.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 8f863f56 — released (done)

## Criteria
- [x] `PluginViewNode` pure value tree in TenonCore (no SwiftUI import), Equatable
- [x] Tier-1 primitives: vstack, hstack, box, text, image, spacer, divider
- [x] Tier-2 components: card, badge, button
- [x] `views.set(id, {body})` parses the tree; malformed/unknown node no-ops with a helpful log, host survives
- [x] Backward compat: existing `items` rows still parse and render; git + file-explorer plugins unaffected
- [x] Button `action` routes through the existing view onSelect handler (one API shape, no new surface)
- [x] Recursive SwiftUI renderer maps tokens to TenonTheme (auto light/dark)
- [x] swift build green; swift test green (199 tests, 0 failures — incl. new core tests + shipped view-gallery e2e)
