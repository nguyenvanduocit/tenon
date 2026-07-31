# T-056: Drag-and-drop capability for plugin view trees
> True pointer drag-drop for the kanban board (and any plugin view): a card dragged between columns fires the same action route a button press takes. Needs boundary design first — there is no drag vocabulary in `PluginViewNode` today.
- **priority**: medium
- **effort**: L

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
- [ ] Boundary doc updated with the classification decision before implementation
- [ ] A drop delivers exactly one bounded action event to the owning plugin generation
- [ ] Kanban cards drag between columns end-to-end through the shipped JS in tests
- [ ] Full `swift test` green
