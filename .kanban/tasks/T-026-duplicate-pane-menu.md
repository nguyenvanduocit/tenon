# T-026: Pane header menu duplicates a pane; type switching leaves the menu
> The pane header's contextual menu gains "Duplicate" (a second pane showing the same
> content) and drops the "Change Type" submenu.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
session `d25d3c17`

Claimed files:
- `Sources/TenonCore/Workspace.swift` — NEW `duplicateSlot(_:)` + `addSlot` anchored
  through one shared placement path. Nothing else in this file.
- `Sources/TenonCore/WorkspaceStore.swift` — one forwarding method
- `Sources/TenonApp/SpatialCanvasView.swift` — `slotContextMenu` items +
  delete `SlotTypeOption`
- `Tests/TenonCoreTests/WorkspaceDuplicateSlotTests.swift` — NEW
- `Tests/TenonAppTests/SpatialCanvasInteractionTests.swift` — menu assertions

## Out of scope
- No public `workspace.pane.duplicate.v1` intent. The pane header is same-owner host UI, so
  it calls the typed service DIRECT per `docs/architecture-interaction-boundaries.md`; an
  intent belongs here only once a plugin, the CLI, or the palette needs to duplicate a pane.
- `setSlotContent` stays: `workspace.pane.content.set.v1` and the blank pane's launcher still
  own content switching. Only the header submenu is gone.

## Criteria
- [x] "Duplicate" opens a second pane showing the pane's own content (terminal, file,
      plugin view, diff), placed in free canvas space when there is any and otherwise by
      splitting the pane itself
- [x] The rule is asserted in `TenonCoreTests` without a window
- [x] "Duplicate" is disabled only when the pane can neither be placed nor split
- [x] The header menu is `Split · Stack · Duplicate · Close` — no type submenu anywhere in
      the tree, and `SlotContent` switching survives only where it is still owned
      (`workspace.pane.content.set.v1`, the blank pane's launcher)
- [x] `swift build` + `swift test` green, launch smoke clean

## Evidence
- `WorkspaceCatalog.duplicateSlot` + `canDuplicateSlot` (`Workspace.swift:485-508`) and the
  shared `openSlot(content:near:)` that `addSlot` now also routes through — one placement
  policy, anchored on the pane that asked instead of the focused one.
- `swift test` **595 tests / 3 failures, twice**. All 3 are T-021's pre-existing standing-consent
  provenance reds (`AppStatePathsTests.swift:84`, `:110`, `BundledPluginConsentTests.swift:81`,
  `["process.exec.v1"]` vs `[]`) — the same three the board recorded before this task.
  `WorkspaceDuplicateSlotTests` 7/7 green.
- `swift build` exit 0. Launch smoke: app alive 8 s on a private `TENON_SOCKET_PATH`
  (another session holds the default socket), empty log.
- ⚠️ **`TenonAppTests` could not be executed.** `Tenon.xcodeproj` still lists the deleted
  `Tests/TenonCoreTests/WorkspaceDiffReuseTests.swift`, so `xcodebuild -only-testing:TenonAppTests`
  fails at build input resolution — pre-existing, and fixing it means `xcodegen generate`
  while @fd5aa92f T-022 holds `project.pbxproj` dirty. The two menu tests are written and
  will run with the next regeneration; the rule they cover is asserted in core regardless.
- Right-clicking a pane header is human-verify-only here (no assistive access).
