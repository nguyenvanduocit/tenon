# T-056: Drag-and-drop capability for plugin view trees
> True pointer drag-drop for the kanban board (and any plugin view): a card dragged between columns fires the same action route a button press takes. Needs boundary design first — there is no drag vocabulary in `PluginViewNode` today.
- **priority**: medium
- **effort**: L

## Owner / files (agent lock)

**RELEASED 14:4x, session `c94bdd73`. Every file below is FREE.**

New: `Sources/TenonCore/PluginViewDrag.swift`,
`Tests/TenonCoreTests/PluginViewDragTests.swift`.

Edited: `Sources/TenonCore/PluginViewNode.swift`,
`Sources/TenonCore/PluginRuntimeValueParsing.swift`,
`Sources/TenonApp/BuiltInSlotViews.swift`, `Sources/TenonApp/PluginModalOverlay.swift`,
`Sources/TenonApp/PluginWebSurfacePool.swift` (one `switch` gained the two new cases —
unavoidable, or the tree stops compiling for everyone), `plugins/kanban/main.js`,
`Tests/TenonCoreTests/PluginViewsTests.swift`, `Tests/TenonCoreTests/KanbanPluginTests.swift`,
`docs/architecture-interaction-boundaries.md` (CONTRIBUTION inventory + fitness list only,
shared with T-089 and split by section as claimed), `docs/design-plugin-views.md`,
`docs/domains.md`.

## What shipped

The law selects the mechanism and the law already had one: a plugin publishes *which*
subtree may be picked up and *which* accepts a drop as declarative state inside the tree it
already owns (rung 1, CONTRIBUTION), and the drop comes back on the *same* owner-scoped
`views.onSelect(action, value)` a button press already uses (rung 2, EVENT). So the feature
adds **no `tenon` member, no callback, no intent** — `testRuntimeExportsOnlyTheClassifiedPublicSurface`
and the closed-global test are byte-identical, and that is the receipt.

`PluginViewNode.dragSource(payload:children:)` / `.dropTarget(action:children:)`. Named
`payload` rather than the card's `id:` sketch — the node tree already has a `stateIdentity`,
and two things called "id" on one node is the kind of collision that costs an hour later.

**The rule the host owns is refusal, and it is pure.** `PluginViewDrag` (68 lines,
`TenonCore`, no window) encodes the payload with its scope and admits a drop only when the
drag started in the same plugin, the same view, and the same instance. Four fail-closed
clauses, each proved load-bearing:

| # | Mutation | Went red |
|---|---|---|
| M1 | `decode` stops checking the scope | 5 tests, incl. the shipped-JS cross-pane one |
| M2 | `decode` stops checking the marker | `testAnEnvelopeCarryingAnotherMarkerIsRefused` |
| M3 | `decode` trusts the payload it was handed | `testAForgedEnvelopePastTheBoundIsRefusedOnArrival` |
| M4 | an over-long payload drops the whole subtree | `testAMalformedDragWrapperKeepsItsSubtreeAndLosesOnlyTheGesture` |
| M5 | a drop steps one column instead of landing where dropped | `testDroppingACardOnAColumnMovesItThere` |
| M6 | a drop on its own column rewrites the board anyway | `testACardDroppedOnItsOwnColumnWritesNothing` |

All six restored `cmp`-verified. **M6 found a real defect in this task's own test**: it
asserted "nothing was written" after waiting for the *first* filesystem request, which is
the read — so the write it was looking for could not yet have happened and the test was
vacuously green. It now waits for the second read, which is the one that marks the whole
move path finished. That is the failure this repo's mutation habit exists to catch, found
in the work of the session that wrote it.

Degradation is toward *keeping the content*: an over-long or empty payload, or a
`dropTarget` with no action, leaves the subtree rendering and drops only the gesture. Unlike
`button`, which IS its content, these wrap content the plugin still meant to show — a card
that vanishes because its id was long is a worse answer than a card you move with the
buttons.

Kanban keeps its ◀ ▶ buttons. A drag is unreachable by keyboard and by VoiceOver, so it is
an addition to the route, never the route.

## Evidence

- Full `swift test` **1583 / 0**. (Earlier runs carried 16–24 rotating failures in
  `AgentLensPaneHeaderTests` and `AppPreferencesTests` — in-flight T-089/T-087 work, none
  naming a file this task touched; all cleared by the final run.)
- 159 / 0 across every suite touching this change, run as one filter.
- Rendered the real board offscreen through `TENON_VIEW_SNAPSHOT` before claiming anything
  about layout — the check T-055 shipped a bug for want of. Columns still full-height boxes,
  the empty `Todo` column still holds its place and its height, cards still pinned to the
  top, buttons unclipped: the wrappers are transparent in fact, not only by intention.

## Known limits, stated not sold past

- **The pasteboard is not a trust boundary and is not treated as one.** Scope travels in the
  dragged string and is checked on arrival. A local process that can synthesise a drag onto
  a focused pane can synthesise a click on the button beside it, so the scope check buys
  correctness against accident and cross-plugin leakage — not resistance to a hostile local
  app. Recorded in the boundary doc rather than left for a reader to discover.
- **The highlight is less honest than the refusal.** SwiftUI decides targeting from the
  dragged type alone, so text dragged in from another app lights a column up and is then
  refused. The drop returns `false` and no event reaches the generation; only the ring is
  premature.
- A card dragged out of Tenon into a text editor pastes the encoded envelope, which contains
  the pane's UUID. Nothing secret, but it is visible, and it is the cost of using plain text
  as the transport instead of a custom `UTType` the app would have to declare in its
  Info.plist to use reliably from `swift run`.

## Scope
- Classify per docs/architecture-interaction-boundaries.md: drag source/drop target as
  CONTRIBUTION metadata on the node tree; the drop event reaches the plugin through the
  existing `views.onSelect` action route (one event shape, invariant 6) — no new global.
- `PluginViewNode`: `dragSource(id:children:)` / `dropTarget(action:children:)` (naming
  per review); host SwiftUI `onDrag`/`onDrop` adapters in `PluginNodeView` routing to
  `invokeViewSelect`; payloads bounded values only (invariant 2).
- Kanban upgrades its move buttons to drag; buttons stay as the accessible fallback.
- Depends on T-055 (board UI + paged write land first).

## Scope
- Classify per docs/architecture-interaction-boundaries.md: drag source/drop target as
  CONTRIBUTION metadata on the node tree; the drop event reaches the plugin through the
  existing `views.onSelect` action route (one event shape, invariant 6) — no new global.
- `PluginViewNode`: `dragSource(id:children:)` / `dropTarget(action:children:)` (naming
  per review); host SwiftUI `onDrag`/`onDrop` adapters in `PluginNodeView` routing to
  `invokeViewSelect`; payloads bounded values only (invariant 2).
- Kanban upgrades its move buttons to drag; buttons stay as the accessible fallback.
- Depends on T-055 (board UI + paged write land first).

## Criteria
- [x] Boundary doc updated with the classification decision before implementation — the
      T-056 section of `architecture-interaction-boundaries.md` and its fitness line landed
      before the first line of `PluginViewDrag.swift`
- [x] A drop delivers exactly one bounded action event to the owning plugin generation —
      one `onSelect(action, payload)`, refused unless plugin+view+instance all match (M1),
      payload bounded at publication and re-bounded on arrival (M3, M4)
- [x] Kanban cards drag between columns end-to-end through the shipped JS in tests —
      `testDroppingACardOnAColumnMovesItThere` drives the real `plugins/kanban/main.js`
      through the host's real admission rule; M5 mutated that shipped file and turned the
      test red, which is what proves the test reaches it
- [x] Full `swift test` green — **1583 / 0**
