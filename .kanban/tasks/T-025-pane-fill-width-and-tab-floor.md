# T-025: Pane fills its width on header double-click, tab chips keep a floor width
> Double-clicking a pane header grows that pane sideways into whatever free columns its
> band has; a tab chip never shrinks below a readable width.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
session `dd2c89a8` — **LOCKS RELEASED**; every file below is free again. The list stays as
the record of what this task changed.

Files changed:
- `Sources/TenonCore/SpatialLayout.swift` — NEW pure `fillWidth(_:slotID:)` only
- `Sources/TenonCore/Workspace.swift` — NEW `WorkspaceCatalog.fillSlotWidth(_:)` only
- `Sources/TenonCore/WorkspaceStore.swift` — one forwarding method
- `Sources/TenonApp/SpatialCanvasView.swift` — header double-click → `onFillWidth`
- `Sources/TenonApp/ShellTitleBar.swift` — `TabChip` minimum width (T-022 released this)
- `Sources/TenonApp/TenonTheme.swift` — `tabMinWidth` constant
- `Tests/TenonCoreTests/SpatialLayoutTests.swift` — append
- `Tests/TenonCoreTests/WorkspaceTests.swift` — append
- `Tests/TenonAppStateTests/SpatialCanvasGestureTests.swift` — NEW
- `docs/design-pane-slots.md` — fill-width operation, mutation, and the click-count rule

## Criteria
- [x] `SpatialLayout.fillWidth` grows a pane to the nearest blocking pane / canvas edge on
      both sides of its own row band, shrinks nothing, and reports no-op when already full
- [x] `WorkspaceCatalog.fillSlotWidth` commits it through `applyResize` and emits `.slotsResized`
- [x] Double-click on a pane header fills that pane's width; single click still moves it,
      double-click on a resize edge or the body does not fill
- [x] A tab chip is never narrower than `TenonTheme.tabMinWidth` (140 pt)
- [x] `swift build` + `swift test` green (pre-existing reds excepted)

## Evidence
- `swift build` exit 0.
- `swift test`: 583 executed, 3 failures — the same 3 T-021 reds the board already records
  (`BundledPluginConsentTests.swift:81`, `AppStatePathsTests.swift:84` and `:110`, all
  `["process.exec.v1"]` vs `[]`). The 9 new tests here are green.
- Launch smoke: `TENON_STUB_TERMINAL=1 .build/.../tenon` alive after 8 s, empty log.
- Not verified: the on-screen result of the gesture and the chip's new floor — a headless
  shell cannot screenshot. One human look is still owed.
