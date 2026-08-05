# T-066: Kanban columns hold a fixed width, the board scrolls sideways, and More opens a modal that tracks the run
> User-directed: kanban columns must never resize with the pane, the whole board scrolls
> horizontally, and "More" opens a window-level modal that shows the task and follows the
> agent started for it.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
Released — session e5bab0f8 finished 21:2x. No file is claimed by this task.

The accepted `PluginHost.swift` overlap with T-062 landed clean: this task's hunks are
`PluginViewSection`'s new `modal` field plus its one construction inside `publish()`,
both far from T-062's consent/discovery territory, verified by reading the combined diff.

Previously claimed:
- poc/Sources/TenonCore/PluginViewNode.swift
- poc/Sources/TenonCore/PluginRuntimeValueParsing.swift
- poc/Sources/TenonCore/PluginRuntimeModels.swift
- poc/Sources/TenonCore/PluginRuntime.swift (`setViewBody` + `ViewBody` only)
- poc/Sources/TenonCore/PluginHost.swift (`PluginViewSection` + its one construction in
  `publish()` only — **accepted overlap with T-062**, whose hunks are consent/discovery)
- poc/Sources/TenonApp/BuiltInSlotViews.swift
- poc/Sources/TenonApp/PluginModalOverlay.swift (NEW)
- poc/Sources/TenonApp/ContentView.swift (one `.overlay` line)
- poc/Sources/TenonApp/PluginWebSurfacePool.swift (one `case .box` pattern)
- poc/plugins/kanban/main.js, poc/plugins/kanban/manifest.json
- poc/Tests/TenonCoreTests/PluginViewsTests.swift
- poc/Tests/TenonCoreTests/KanbanPluginTests.swift
- poc/Tests/TenonAppStateTests/PluginModalPresentationTests.swift (NEW)
- docs/design-plugin-views.md

## Decision
Three host capabilities, all inside the existing CONTRIBUTION boundary — the public
vocabulary on `tenon` does not grow, so invariant 1 and the surface-pinning test are
untouched.

1. **`box` gains `width`.** A column is a `box`; a fixed column is that box with a
   declared width. `nil` keeps today's fill behaviour, so every other plugin is
   unaffected. Bounded 60…1200 pt at the parsing boundary, like `progress`'s clamp.
2. **A `scroll` node.** `{ type: "scroll", axis: "horizontal" | "vertical" | "both" }`.
   Fixed-width columns overflow the pane by construction, and the pane's own wrapper
   only scrolls vertically, so the sideways scroll has to be something the plugin can
   declare rather than something the host guesses from the tree.
3. **A `modal` on the view specification.** `tenon.views.set(id, { body, modal })` where
   `modal` is `{ title, body, dismissAction? }`. The host renders it as a window-level
   sheet over the whole shell (the user chose window-level over an in-pane overlay),
   alongside `PaletteOverlay` and `PluginUIOverlay` in `ContentView`. Exactly one modal
   shows at a time: the first section in publish order that carries one. Dismissing —
   Escape, the backdrop, or the close control — routes the fixed action id back through
   `invokeViewSelect`, so the plugin owns the state and the host owns only presentation,
   the same split `browserBar` already uses.

Kanban then: columns are 260-pt boxes inside a horizontal `scroll`; **More** opens the
modal instead of expanding the card inline (the inline expansion is removed, not kept
beside it); **Start** opens the agent pane and the modal follows that pane with
`terminal.viewport.read.v1` on a 1.2 s timer, showing status (`running` until `exited`)
and the last 15 non-empty rows, plus **Focus pane** via `workspace.pane.focus.v1`.

## Criteria
- [x] `box` renders at a declared fixed width, clamped, and unchanged when omitted
- [x] A `scroll` node with `axis: "horizontal"` parses and renders as a horizontal
      `ScrollView`; unknown axes fall back to vertical rather than dropping the node
- [x] A view specification's `modal` reaches `PluginViewSection`, and exactly one modal
      is selected for presentation with more than one on offer
- [x] Dismiss delivers the modal's action id to the owning view's `onSelect`
- [x] Kanban: every column is a fixed-width box under a horizontal `scroll`
- [x] Kanban: More opens the modal carrying the task's detail; no inline expansion remains
- [x] Kanban: Start records the pane and the modal shows live status + output tail
- [x] Full `swift test` green

## Evidence
- `swift build` clean; full suite **999 / 0** in 59.6 s.
- 8 new tests: 4 in `PluginViewsTests` (width clamp, scroll axis fallback, modal publish
  + default dismiss id, modal cleared by the next `views.set`), 4 in
  `PluginModalPresentationTests` (none/one/first-wins/title bound), plus 3 rewritten
  kanban tests (fixed columns under a horizontal scroll, More → modal with the card
  unchanged, dismiss closes) and 1 new one (Start tracks the pane it opened).
- **6 mutation proofs**, each caught by a named test and each reverted through a
  `cmp`-checked backup (never `git checkout` — peers were mid-edit): column `width`
  dropped; scroll axis flipped to vertical; `specification.modal` never assigned;
  the viewport read's pane scope removed; the parsing clamp removed; modal selection
  reversed to last-wins.
- **Rendered offscreen** (`NSHostingView` + `cacheDisplay`, the T-055 technique — the
  suite cannot see layout): 260-pt columns hold their width, the fifth column runs past
  the pane edge into the horizontal scroller instead of squeezing the rest, and the sheet
  body reads as description → criteria → `running` badge + pane id → output tail →
  Focus pane / Start again. The probe was deleted afterwards.
- Not asserted: the AppKit seam itself — the sheet's backdrop, Escape, and the shadow are
  smoke-launch territory per `docs/tdd.md`; the rule they delegate to (which modal, which
  action id) is pinned headless.
- `xcodegen generate` re-run so the new files are in the Xcode target.
