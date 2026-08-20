# T-193: A tab only auto-closes when its last pane moves away
> Emptying a tab by closing its last pane (or abandoning a launcher reservation) keeps the tab and shows its own Empty slot state instead of silently vanishing; auto-close stays only for a pane moving out to another tab.
- **priority**: medium
- **effort**: M

## Owner / files (agent lock)
- **RELEASED 2026-08-20 — done, full suite 2400/0, not committed.**
- files were: `Sources/TenonCore/Workspace.swift`, `Tests/TenonCoreTests/TabContextPlacementTests.swift`, `Tests/TenonCoreTests/WorkspaceTests.swift`, `docs/prds/spatial-panes.prd.md`, `docs/prds/spatial-panes.feature`, plus three fallout tests the plan did not foresee: `Tests/TenonAppStateTests/``{PaneProcessAndTabCloseIntentTests,EmptyPaneSearchTests,WorkspaceIntentProviderTests}.swift`

## Context

Operator-reported (Vietnamese chat): confused why an "Empty slot" panel exists at all, then
correctly root-caused it — `closeTabIfEmpty` (`Workspace.swift:1550-1558`) is called
identically from three call sites and treats them as the same event:

- `closeSlot` (`Workspace.swift:973`) — user explicitly closes the last real pane in a tab.
- `moveSlot`/`moveSlotToNewTab` (`Workspace.swift:1126,1198,1354`) — the last pane is dragged
  to another tab/window.
- `discardEmptySlot` (`Workspace.swift:779`) — a `+`/empty-canvas-click launcher reservation
  (`SlotContent.empty`) is abandoned without picking anything.

All three currently auto-remove the tab via `closeTab` (`Workspace.swift:654-684`), which
itself refuses to remove a workspace's *last* tab — leaving a genuine 0-slot "ghost" tab in
that case. That ghost is a known, already-pinned, unfixed gap:
`TabContextPlacementTests.testATabEmptiedToTheWorkspacesLastPaneResolvesToNothingEvenThoughItStillExists`
(commit `b62d07e`) — `TabContextPlacement.scopedPane` reads the ghost tab exactly like a
closed one, so its own right-click menu (including "New Terminal") silently fails
("This space is no longer available", `LauncherOutcome.swift:321`).

This behavior is a deliberate, documented decision — `SP-FR-006`
(`docs/prds/spatial-panes.prd.md:294`) plus its 2026-08-13 decision log entry
(`docs/prds/spatial-panes.prd.md:508`): "Empty source tabs were residue from closing or
moving a final pane, not durable working state. The model applies the rule once across
close, move, and reservation cleanup." Operator wants this decision partially reversed.

`SlotContent.empty` / `EmptySlotView` (`Sources/TenonApp/BuiltInSlotViews.swift:145-153,811`,
title "Empty slot" at line 212) already exists as a pane-level placeholder — it is the
reusable building block for the new behavior, just never used for this case before.

## Decision (operator-confirmed via AskUserQuestion, 2026-08-20)

- `closeSlot` emptying a tab → convert that tab's surviving slot's content to `.empty`
  (reuse `EmptySlotView`) instead of removing the slot/tab. No auto-close.
- `discardEmptySlot` emptying a tab → same: show Empty slot, no auto-close. (Operator chose
  "Đổi thành show Empty slot" over keeping today's silent auto-close, for consistency: every
  path that empties a tab except an explicit move behaves the same way.)
- `moveSlot`/`moveSlotToNewTab` emptying the source tab → **unchanged**, keeps auto-closing
  via `closeTabIfEmpty`/`closeTab` exactly as today.
- Net effect: a workspace's last tab, once emptied by close/discard, becomes a tab with one
  `.empty` slot instead of a genuine 0-slot ghost — `b62d07e`'s pinned gap is closed as a
  side effect, not a separate fix.

## Criteria
- [x] Failing test written first (TDD) proving: closing the last real pane in a non-last tab
      no longer removes the tab — the tab survives with one `.empty` slot.
- [x] Failing test proving: closing the last real pane in a workspace's *only* tab now
      produces a tab with one `.empty` slot (not zero slots) — supersedes/rewrites
      `testATabEmptiedToTheWorkspacesLastPaneResolvesToNothingEvenThoughItStillExists` to
      assert the fixed behavior instead of pinning the gap.
- [x] Failing test proving: `discardEmptySlot` abandoning a launcher/empty-canvas reservation
      leaves the tab showing `.empty` rather than closing it.
- [x] Existing `moveSlot`/`moveSlotToNewTab` auto-close tests still pass unchanged — moving
      the last pane away still closes the source tab exactly as before.
- [x] `SP-FR-006` restated in `spatial-panes.prd.md`, with a dated decision-log entry marking
      the 2026-08-13 "applies the rule once across close, move, and reservation cleanup" row
      superseded and explaining why (operator-directed UX change + free bug fix).
- [x] `TabContextPlacement`/`ShellTabStrip` context-menu commands (New Terminal etc.) verified
      to work against a now-properly-populated last tab — the `b62d07e` gap's actual symptom.
- [x] `swift test` green, full suite, no regressions; exact before/after count in the receipt.

## Outcome (2026-08-20)

**Shipped.** `closeSlot` notes whether the pane it is closing is the tab's only one; the pane still
leaves through the untouched `removeSlot` and still publishes `.slotClosed` first, so surface-pool,
plugin-resource and terminal-job teardown are unchanged — then a **new** `WorkspaceSlot` (fresh UUID,
`fullGridRect`, `.empty`) takes its place with `.slotOpened` + `.slotFocused`, the pair `newTab`
publishes. `setSlotContent` was deliberately NOT used: it would have skipped `.slotClosed` and leaked
the pane's live resource. `discardEmptySlot` returns `[]` when the reservation is the tab's only pane.
`moveSlot`/`moveSlotToNewTab`/`closeTabIfEmpty` behavior is byte-for-byte unchanged; the now-unreachable
`closeTabIfEmpty` call inside `discardEmptySlot` was deleted rather than left as a dead branch.

Full suite **2400 / 0** (baseline before any edit: 2399 / 0; +1 for the new full-grid placeholder test).
Red first: 10 assertion failures across the 5 rewritten/new tests. Not committed.

### Three consequences outside the planned file set, all handled and none hidden

1. `EmptyPaneSearchTests.testATypedCommandInAnEmptyTabAddsThePaneItRunsIn` and
   `WorkspaceIntentProviderTests.testOpeningIntoAnEmptyTabAddsItsFirstPaneAndNeverOpensATab` used a
   close as a *fixture* to reach a 0-slot tab. Assertions unchanged; the fixtures now build a slotless
   tab directly, which is how one actually arises — `WorkspaceCatalogStore.swift:355` decodes it,
   `WorkspaceStageView.swift:71` draws it, `Tab.init` permits it. So `openSlot`'s empty-tab branch is
   not dead and keeps its coverage.
2. `PaneProcessAndTabCloseIntentTests.testPaneCloseAlsoClosesItsEmptyTabWhenAnotherTabSurvives` was the
   *subject*, at the intent layer → rewritten as `testPaneCloseLeavesItsEmptiedTabStandingWithAnEmptyPane`.
3. **Open question recorded, not decided** (`spatial-panes.prd.md` decision log, 2026-08-20): the
   2026-08-13 row minted `workspace.pane.close.v2` because *adding* the tab removal "changes observable
   side-effect meaning, so same-major evolution is forbidden". Removing it is the same kind of change, so
   the symmetric answer is a `.v3` — reaching `CoreIntentName.swift`, `CoreCommandsPlugin.swift`,
   `plugins/core-commands/manifest.json` and three design docs, none in this task's file set.

### Owed / flagged for the operator

Criterion 6 holds at the layer that was broken: `TabContextPlacement.scopedPane` now resolves the
emptied tab's placeholder, so `ShellTabStrip.send` no longer returns `.targetUnavailable` and the tab's
own right-click commands land — pinned by the rewritten `TabContextPlacementTests` case. But the pane
they land *as* is worth a look: `openSlot` (`Workspace.swift:839`) sees a full grid, so New Terminal on a
just-emptied tab **splits** the placeholder — terminal in half the tab, leftover Empty slot in the other.
Strictly better than the old outright failure, and it is pre-existing `openSlot` policy (the same thing
already happens with a `+` reservation), but if the operator expects one full-grid terminal the fix is
for `openSlot` to consume a lone `.empty` pane instead of splitting it. That changes the `+`-reservation
flow too, so it is a separate task, not part of this diff. No live-app run was possible from this session.
