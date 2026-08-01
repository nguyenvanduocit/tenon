# T-063: A headless snapshot of a plugin view tree, so layout bugs stop shipping green
> `swift test` proves a view tree's shape and proves nothing about its geometry. T-055 shipped a board that passed 24 tests and rendered as scattered cards floating at different heights. An offscreen render — no window, no Screen Recording permission — catches that class in one look.
- **priority**: medium
- **effort**: S

## Why (measured, T-055)
The adversarial review panel read the diff and found nothing about layout; the tests
asserted hstack/vstack/card structure and passed. Rendering the real tree offscreen
showed three defects at once, none visible in code review:
- columns were vertically centred against each other (`hstack` → `HStack` defaults to
  `.center`), so a short column floated mid-pane beside a tall one;
- an empty column collapsed to the width of its own heading and disappeared;
- card titles wrapped into a column of single words, and button labels truncated to
  "Det…" — a card is a fifth of the pane wide, which no test could feel.
The mechanism already exists in-tree: `DiffSnapshot.write` (`NSHostingView` +
`layoutSubtreeIfNeeded` + `cacheDisplay` → PNG) renders SwiftUI with no window and no
screen-capture permission. `screencapture` is NOT an option — this process has no
Screen Recording grant and fails with "could not create image from window".

## Scope
- A `TENON_VIEW_SNAPSHOT=<plugin-id>/<view-id>:<path>` branch (naming per review) that
  boots the real host over the real inventory, opens the view, and writes the PNG the
  same way `DiffSnapshot` does — the recipe verified by hand in T-055.
- `PluginNodeView` must be reachable from wherever the snapshot lives; it is `private`
  in `BuiltInSlotViews.swift` today (T-055 opened it temporarily and reverted).
- Docs: the `## Verification` section of CLAUDE.md says the GUI cannot be screenshotted
  from a headless shell. Half of that is now false and should say so precisely: a
  *window* cannot, an offscreen *view* can.

## Criteria
- [ ] One documented command renders any plugin view to a PNG with no window
- [ ] The kanban board is the worked example in the docs
- [ ] Works under `swift test`-style headless runs (no Screen Recording permission)
