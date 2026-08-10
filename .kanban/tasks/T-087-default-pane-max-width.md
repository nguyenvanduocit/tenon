# T-087: New panes respect the default max width
> Let the user choose a preferred maximum width so a newly created pane does not expand beyond the size they find useful.

- **priority**: medium
- **effort**: M

## Criteria
- [x] Host-native Settings exposes an optional default maximum width for newly created panes, following `docs/designs.md` and the existing settings vocabulary instead of introducing feature-local tokens. — "Widest a new pane opens" in the existing **New panes** section of `SettingsView`, a native `Picker` matching its three sibling rows; options are `SpatialExtentFraction`'s own `label`s (1/3, 1/2, Full) plus "As wide as it fits", the unset state.
- [x] The preference is validated, persisted, and restored across app launches; invalid or out-of-range values cannot create an unusable layout. — `AppPreferences.newPaneMaximumWidth: SpatialExtentFraction?`, `Codable` round-trip per case; a name this build cannot read, and a file written before the field existed, both load as "no maximum" without failing the document.
- [x] Initial pane sizing considers both available space and the configured limit: a new pane is never wider than the available layout permits or the user's maximum. — `fitting` only ever narrows what the layout already offered; a 3-column hole stays 3 under a 6-column maximum.
- [x] When the preference is unset or disabled, pane creation behaves exactly as it does today. — `.unlimited` is the default parameter on every entry point, asserted by running a capped and an uncapped catalog through five creations side by side and comparing rects.
- [x] Changing the preference affects future pane creation only; existing panes keep their current size and remain freely resizable by the user. — restore reads persisted rects verbatim; resize is untouched, with a test that drags a 1/3-capped pane to full width.
- [x] Every pane-creation entry point uses the same typed sizing policy, with built-in SwiftUI calling it directly in accordance with `docs/architecture-interaction-boundaries.md`. — `NewPaneSizing`; the empty-canvas launcher is the one entry point that applies it in the app layer, for the reason in **Shape**.
- [x] Tests cover unset, wide-space, narrow-space, boundary-value, persistence, and existing-pane cases. — 21 in `NewPaneSizingTests`, 3 in `AppPreferencesTests`, 2 in `SpatialCanvasInteractionTests`; 7 mutation proofs below.

## Owner / files (agent lock)

**RELEASED.** Session `c440d38c` finished at 15:0x and holds nothing. Every file below is free:
`Sources/TenonCore/{NewPaneSizing,SpatialLayout,AppPreferences,Workspace,WorkspaceStore}.swift`,
`Sources/TenonApp/{SettingsView,TenonApp}.swift`,
`Sources/TenonApp/Canvas/{SpatialInteraction,SpatialCanvasNSView}.swift`,
`Tests/TenonCoreTests/{NewPaneSizingTests,AppPreferencesTests}.swift`,
`Tests/TenonAppStateTests/SpatialCanvasInteractionTests.swift`.

`SpatialCanvasNSView.swift` and `SpatialInteraction.swift` were not in the original claim; they
were added when the clicked-cell problem surfaced, and neither was claimed by another task.

## Evidence

`swift test` — **1583 tests, 2 failures**, both peers' in-flight work on files this task never
touched: `KanbanPluginTests.testDroppingACardOnAColumnMovesItThere` (T-056, uncommitted
alongside `plugins/kanban/main.js` and `PluginViewNode.swift`) and
`AgentSessionTimelineTests.testAnInventedAnchorIsRefused` (T-089, an untracked new file).
Neither test mentions `NewPaneSizing`, `newPaneMaximumWidth`, or `sizing:`. Reported to their
owners here rather than touched. Zero failures in this task's scope.

Not committed — several peers have uncommitted work in this shared tree.

## Notes
The product intent is a default creation constraint, not a permanent width lock. Compute the
new pane's initial width from the space-based layout first, then cap that result with the
configured maximum; the sibling or remaining layout retains the unused width.

## Shape

`NewPaneSizing` (`Sources/TenonCore/NewPaneSizing.swift`, `@domain: workspace-model`) is the
one typed policy. It is a pure value with two uses: `fitting(_:keeping:)` narrows a rect the
layout already chose, and `maximumColumns` is what `SpatialLayout.split` takes as
`newSlotMaximumWidth`. `.unlimited` is the default parameter on every creation entry point,
so "preference unset" and "no policy supplied" are the same code path rather than two.

**The width vocabulary is `SpatialExtentFraction` — 1/3, 1/2, Full — not a column count.**
That enum already exists as the pane border's contextual-menu vocabulary, so Settings and the
border spell a pane width identically instead of this feature minting a second unit; its
`label` moved out of `SpatialCanvasNSView`'s menu literals so there is one spelling. It also
answers criterion 2 by construction rather than by validation: every fraction of a 12-column
canvas is ≥ `minimumWidth`, so no persisted value can describe an unusable pane, and a value
this build cannot name decodes back to "no maximum".

**Where the declined width goes** differs by axis, and both cases are in the task's own
wording ("the sibling **or remaining layout**"):

- horizontal split — back to the pane being split, which keeps a larger share. No gap.
- vertical split — back to the canvas as empty space. The new pane sits *beneath* its
  sibling and inherits its width, so there is no neighbour to widen.
- free canvas / first pane of a tab — the unused columns stay empty canvas.

**The empty-canvas click is the one entry point where the app applies the policy, not the
model.** `SpatialCanvasInteractionCoordinator.emptyGridLauncherTarget` knows the *cell* the
person pointed at; `Workspace.addSlot(id:content:at:)` receives only a rect. Left-anchoring a
narrowed region there would open the pane away from the pointer, so the canvas calls
`fitting(_:keeping:)` DIRECT (it reads `WorkspaceStore.newPaneSizing`) and the model places
the fitted rect verbatim. This also keeps `LauncherOutcome`'s `slot.rect == reservation.rect`
guard honest — a model-side narrowing would have silently voided every reservation. Both
downstream consumers of that rect (the `.empty` reservation and `AgentLaunchTarget.emptyGrid`)
come from this one function.

`accessibilityCustomActions` still enumerates *uncapped* empty regions: "Fill empty region,
columns 3 through 9" names where empty canvas is, which is true whatever the maximum says.
Firing the action re-hit-tests at the region centre and gets the same capped pane a pointer
click there would.

No new DIRECT inventory entry: this sits inside the law's existing "`WorkspaceStore` and typed
workspace use cases" and "SwiftUI workspace, tab, pane, and settings interactions" entries, so
`docs/architecture-interaction-boundaries.md` is untouched.

## Deliberately not done

- **`moveSlotToNewTab` and cross-tab `placement(forSlot:…)` are uncapped.** Both move a pane
  that already exists — identity, terminal and all — and criterion 5 protects exactly that.
  A pane popped out to its own tab still fills that tab.
- **No `docs/design-*.md`.** One pure 70-line type and one preference; the reasoning above is
  the record.

## Mutation proofs

Every rule was falsified against a patched `Sources/` (backups by `cp`, never `git checkout` —
this tree is shared). Baseline: 30/30 green, no failing lines.

| # | mutation | caught by |
| --- | --- | --- |
| M1 | horizontal split stops capping the new half | `testSplittingHandsTheUnusedWidthBackToThePaneBeingSplit`, `testSplittingStillResizesThePaneBeingSplit`, `testTheCapCanNeverProduceAPaneNarrowerThanTheLayoutAllows` (4 assertions) |
| M2 | vertical split stops capping the inherited width | `testAVerticalSplitReturnsTheUnusedWidthToTheCanvas` |
| M3 | `capped()` drops its `minimumWidth` floor | `testTheCapCanNeverProduceAPaneNarrowerThanTheLayoutAllows` |
| M4 | narrowed region stops following the pointed-at cell | 4 tests incl. the AppKit `testACreationMaximumNarrowsTheClickedRegionAroundTheCellClicked` |
| M5 | an unnameable stored width stops falling back to "no maximum" | `testAWidthThisBuildCannotNameLoadsAsNoMaximumRatherThanFailingTheFile` |
| M6 | `fitting` stops narrowing at all | 8 assertions across both targets |

**M7 changed the design.** `maximumColumns` originally floored its result at `minimumWidth`,
which made `testEveryFractionOfTheCanvasIsAtLeastAUsablePaneWide` vacuous, so the floor was
removed to let the test be the guard. Shrinking the canvas to 8 columns (making 1/3 = 2, below
the minimum) showed why that is wrong: `Tab.init`'s `precondition(SpatialLayout.isValid)`
**crashes** at pane creation, and the crash aborts the run before the alphabetically-later
guard test ever speaks. The floor is back, and the test now reads
`fraction.extent(of: SpatialLayout.columns)` directly so the floor cannot answer for it.

## Working notes

Two peer sessions (T-056 drag-and-drop, T-089 Agent Lens) were editing `TenonApp` and
`TenonCore` throughout, so the shared test target's compile was intermittently red on files
this task never touched — `BuiltInSlotViews.swift`, `PluginViewNode.swift`,
`PluginRuntimeValueParsing.swift`, `AgentSessionTimelineTests.swift`. Runs were retried rather
than "fixed"; a first mutation batch reported three false SURVIVED verdicts from exactly this
(only 62 of 92 tests executed) and was re-run once the tree settled.
