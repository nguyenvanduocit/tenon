# T-189: The `+` and tab-right-click launchers stop sharing a tab's own utilities
> Operator-reported (screenshot + Vietnamese message, not the first time on this launcher):
> clicking `+` — which is supposed to open something new — showed an "Arrange Panes" option,
> which only makes sense for a tab that already exists. `+` and right-click share one popover
> type but must not share every optional callback wired into it.
- **priority**: high
- **effort**: S

## Root cause (verified 2026-08-19)
- `LauncherMenu` is one shared view (`Sources/TenonApp/LauncherMenu.swift`) anchored by three
  call sites; `ShellTabStrip.swift` supplies two of them — `tabLauncher(for:)` for a tab's
  right-click, `newTabButton` for `+`.
- `copyTabID` was already correctly `nil` for `+` (never wired there at all).
- `paneArrangements`/`arrangePanes` were **not** correctly scoped: `newTabButton` wired
  `paneArrangements: activeWorkspace?.activeTab.map { arrangements(for: $0) } ?? []` and
  `arrangePanes: { preset in store.arrangeActiveTab(preset) }` — both reading/mutating
  whichever tab merely happened to be **active**, not any tab the `+` click named (`+` creates
  a destination and names no existing tab — `command-surfaces.prd.md` §1 "Proposed outcome"
  and `CMD-FR-004`). Choosing "Arrange Panes" from `+` silently rearranged the wrong tab.
- The other rows folded into the same "Pane" section — New Tab / Split Right / Split Down —
  are **not** part of this bug: they resolve through `sendInNewTab`'s fresh placeholder tab
  (`ShellTabStrip.swift:219-232`), so they are correctly scoped to `+`'s own destination
  already. That is what let the one mis-scoped utility hide beside correctly-scoped commands.
- `docs/prds/command-surfaces.prd.md` had **zero** mentions of "Arrange Panes"/
  `PaneArrangement` anywhere — the utility shipped with no requirement ever written for it,
  so this task both fixes the wiring and writes the requirement (`CMD-FR-024`) it should have
  had from the start.

## Scope
1. `ShellTabStrip.swift`'s `newTabButton` no longer passes `paneArrangements`/`arrangePanes` to
   its `LauncherMenu` — matching the existing (correct) `copyTabID` omission — with a comment
   at the call site stating why, so a future presentation-unification pass does not restore it.
2. `LauncherMenu.swift`'s type-level doc comment and the `paneArrangements`/`arrangePanes`
   property docs state the general rule: a tab-scoped utility is supplied only by the anchor
   that names a real existing tab; "shared launcher" means shared vocabulary, not shared
   callbacks.
3. New headless fitness test (`InteractionBoundaryFitnessTests
   .testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities`) sweeps `newTabButton`'s
   construction for the absence of `arrangePanes:`/`paneArrangements:`/`copyTabID:`, and
   `tabLauncher(for:)`'s for their presence — red first against the pre-fix source, green after.
4. `command-surfaces.prd.md`/`.feature`: new `CMD-FR-024`, product-vocabulary note, decision
   log entry, delivery-matrix row, verification receipts, change history, and two new Gherkin
   scenarios.

## Owner / files (agent lock)
- `Sources/TenonApp/ShellTabStrip.swift`
- `Sources/TenonApp/LauncherMenu.swift`
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`
- `docs/prds/command-surfaces.prd.md`, `docs/prds/command-surfaces.feature`

None of these are held by any *current* work — `T-177`'s Doing entry lists `ShellTabStrip.swift`
among its "held" files, but `git log` shows T-177 already committed (`e0107e8`), the tree is
otherwise clean, and `T-188`'s own Done entry on this same board says "files released"; that
claim reads the same as the already-noted-stale `T-144`-inside-`T-177` claim beside it and is
treated the same way. Not touching the rest of the board's stale bookkeeping — out of this
task's scope.

## Criteria
- [x] `newTabButton`'s `LauncherMenu` construction no longer wires `paneArrangements`/
      `arrangePanes`; `tabLauncher(for:)`'s still does.
- [x] `LauncherMenu.swift` doc comments state the "shared vocabulary, not shared callbacks"
      rule at both the type and the two properties.
- [x] New fitness test proven red-then-green against the exact regression.
- [x] `swift build` clean; full `swift test` green with no regressions.
- [x] `command-surfaces.prd.md`/`.feature` updated: `CMD-FR-024`, vocabulary, decision log,
      delivery matrix, verification receipts, change history, 2 new Gherkin scenarios.

## Result
Red-then-green confirmed: `swift test --filter
InteractionBoundaryFitnessTests/testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities`
failed with `arrangePanes:`/`paneArrangements:` found on the `+` anchor before the fix, passed
after. Full suite **2393 / 0** (up from 2392, +1 test), `swift build` clean. Not committed —
left for the operator's own commit/review pass.
