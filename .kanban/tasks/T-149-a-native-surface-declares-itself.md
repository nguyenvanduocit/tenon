# T-149: A native surface declares itself instead of being spelled into an enum

> The seven host-native pane kinds move from a closed `SlotContent` enum plus five exhaustive
> switches to one host-internal registry each kind registers with. No behaviour is added and
> the DIRECT inventory does not grow — this changes how existing DIRECT surfaces are declared,
> not what the host privately does.

- **priority**: medium
- **effort**: L
- **PRDs**: `TENON-PRD-003` (pane hosting and content kinds), `TENON-PRD-001` (catalog
  persistence and fail-soft restore), `TENON-PRD-011` (no DIRECT inventory growth)
- **Unclaimed. Independent.** It no longer blocks T-150 after the operator chose to keep
  Kanban plugin-managed and compile its implementation as bundled Swift.

## Why

Adding one host-native pane kind today is a cascading edit. `SlotContent`
(`Sources/TenonCore/Workspace.swift:5-21`) is a closed enum with seven kinds; **16 files**
reference it and **5** switch exhaustively over its cases — `BuiltInSlotViews.swift`,
`EmptyStateCard.swift`, `PaneRenameBrief.swift`, `Workspace.swift`,
`WorkspaceCatalogStore.swift`. A new kind is not one edit, it is sixteen, and the compiler
only finds the exhaustive five.

The asymmetry is sharper against plugins, which register their surfaces and never touch a
core enum. The status strip shows the same shape from the other side:
`Sources/TenonApp/WorkspaceStatusBar.swift:6` states the shell contributes nothing of its own,
so host-native code has no route into a surface plugins reach with one call.

VISION.md:138 already asks for the end state in the near-term quality bar — *"expose built-in
and plugin slot types through one coherent content picker"* — and a closed enum on one side
with a registry on the other is what stands between the tree and that sentence.

**This does not enlarge the host's private surface.** `docs/architecture-interaction-boundaries.md:474`
warns that the DIRECT inventory grew 1.55× in entries and 3.21× in characters ambiently. This
task adds no entry and enlarges none: the same seven behaviours stay DIRECT, declared
differently. `DirectInventoryGateTests` must stay green **without** its pinned count or any
entry length moving — that is the acceptance signal that this refactor kept its promise.

## Criteria

- [ ] A host-internal registry declares a native pane kind's stable id, title rule, glyph,
      pane-yield rule, and view factory in one place, replacing the closed `SlotContent` enum.
- [ ] `SlotContent.yieldsPane(to:)` (`Workspace.swift:28`) becomes a property of the registered
      kind; behaviour for all seven current kinds is unchanged, asserted case by case.
- [ ] Persisted workspaces naming an unregistered kind still degrade fail-soft, matching the
      existing retired-kind rule audited in `docs/prds/README.md` for T-103.
- [ ] The five exhaustive switches are gone; a new native kind is one registration and no edit
      to `Workspace.swift`.
- [ ] `DirectInventoryGateTests` green with pinned entry count and every entry length
      unchanged — proof no private surface was added under cover of a refactor.
- [ ] Full suite green; every touched file keeps its `@domain:` tag and long files their
      MARK-section tags.

## Risk this task carries

`Workspace.swift` is central and other sessions edit it — T-146/T-147 worked at
`Workspace.swift:1053` (`renameSlot`) recently. Claim it in `Doing` only when no other Doing
card holds `Workspace.swift`, `BuiltInSlotViews.swift`, or `WorkspaceCatalogStore.swift`, and
re-read those cards immediately before the first edit.

## Owner / files (agent lock)

Unclaimed. Files this will hold when claimed:

- `Sources/TenonCore/Workspace.swift`
- `Sources/TenonCore/WorkspaceCatalogStore.swift`
- `Sources/TenonApp/BuiltInSlotViews.swift`
- `Sources/TenonApp/EmptyStateCard.swift`
- `Sources/TenonApp/PaneRenameBrief.swift`
- the new registry source under `Sources/TenonCore/`
- `Tests/TenonCoreTests/` additions
- `docs/prds/spatial-panes.prd.md` / `.feature`
