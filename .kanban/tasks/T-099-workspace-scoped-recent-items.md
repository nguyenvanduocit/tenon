# T-099: Recently Opened is scoped to its workspace
> The empty-panel launcher's recent list must show only items opened in the workspace that owns that panel.

- **priority**: high
- **effort**: S

## Criteria
- [x] Every recent item is recorded against a stable workspace identity (with a canonical root fallback for migration), rather than in one app-global list.
- [x] An empty tab or pane receives its workspace explicitly and renders only that workspace's recent items; it never derives scope from whichever window or pane happens to be focused later.
- [x] Switching workspaces updates the launcher immediately, and no title, view type, or file path from another workspace appears during loading, restoration, or rapid switching.
- [x] Opening a recent item targets the workspace and pane from which it was chosen and cannot mutate or reveal another workspace's catalog state.
- [x] The same item may have independent recency in multiple workspaces, and clearing or deleting one workspace's history does not change another workspace's list.
- [x] Workspace-scoped history persists across relaunch; legacy global recent data is migrated or discarded deterministically and never assigned to an unrelated workspace.
- [x] This corrects the existing same-owner launcher state through typed DIRECT calls under `docs/architecture-interaction-boundaries.md`; it adds no public intent, capability, or app-global mutable scope.
- [x] Tests use at least two simultaneous workspaces to prove isolation, switching, independent ordering/deduplication, restoration, deletion, and legacy-data handling.

## Owner / files (agent lock)

**RELEASED 18:2x, session `2780aeb5`.** Nothing here is held any more.

## What shipped

`RecentStore` keeps one list per workspace instead of one list for the app. Its persisted
document is one row per workspace — `workspaceId`, the canonical `root`, and that
workspace's `views` — and `recent(for:)` requires a workspace id, so **there is no longer an
accessor that can return an unscoped list**. That is the load-bearing part of the fix: the
old leak is not guarded against, it is unspellable.

Three decisions worth recording:

- **Attribution comes from the mutation's own events, not from the selection.**
  `WorkspaceStore.recordRecent(_:from:)` reads `events.first?.workspaceID`, because
  `setSlotContent` addresses a pane anywhere in the catalog — filling an empty pane in an
  unselected workspace has to land in *that* workspace's list. `apply` kept its `-> Bool`
  signature and gained `applyEvents` beside it, so the fifteen existing call sites (and the
  ones T-096/T-097 were writing in the same file at the same time) were untouched.
- **The workspace id is the identity; the canonical root is only an heir-finder.**
  `.workspace-catalog.json` can be declined wholesale (corrupt, oversized, newer version),
  and the next launch mints fresh ids for the same folders. `RecentStore.adopt` re-keys a
  bucket whose id is gone onto the live workspace rooted at a byte-identical canonical root,
  once, at launch, and a live workspace that already has a list keeps it. Anything that does
  not match is left where it is — its workspace may simply be closed.
- **The old app-global file is discarded, not migrated.** Its rows carry no workspace at
  all, so any attribution would be a guess, and the guess would reproduce exactly the leak
  this task removes — once, on one machine, invisibly. Deterministic and stated in the test
  name.

`clear()` was replaced by `clear(_ workspaceID:)`; the store no longer has a whole-app
mutation. `EmptySlotView` became internal so the hosted test can mount it.

## Evidence

- Scope suites **127 / 0**: `RecentStoreTests` 23, `WorkspaceRecentLauncherTests` 2,
  `SpatialCanvasInteractionTests` 62, `PluginPaneHeaderRouteTests` 2, `WorkspaceStoreTests`
  10, plus the three fitness gates green — `InteractionBoundaryFitnessTests` 20,
  `DomainTagFitnessTests` 5, `DirectInventoryGateTests` 3. The boundary and DIRECT-inventory
  gates staying green is the receipt for criterion 7: no intent, no capability, no new
  inventory entry.
- Full suite reached **1678 / 0** at 18:0x. Later runs show peer failures only
  (`WorkspaceIdentity*` = T-097, `WorkspaceTabOrder*` = T-096, `FleetReviewExampleTests`
  timing), all in files this task never opened.
- **8 mutations, 8 caught**, each run individually with a `cmp`-verified restore:
  M1 unknown-workspace read falls back to the first list · M2 attribution reads
  `activeWorkspaceID` · M3 adoption drops the root match · M4 adoption overwrites a live
  workspace's own list · M5 legacy rows attributed instead of dropped · M6 `clear` wipes
  every workspace · M7 workspace-bucket cap removed · M8 the launcher view reads the
  selected workspace instead of the one it was handed.
- **M4 initially SURVIVED and that found a real defect in this task's own test.**
  `testALiveWorkspaceKeepsItsOwnListInsteadOfAdoptingAStaleOne` wrote the stale list
  *before* the live one, so the duplicate row adoption produced sorted behind the live one
  and `recent(for:)` never saw it. Written in the dangerous order — stale list newer — the
  mutation returns the stale list, and the test now also asserts the persisted document has
  no duplicate workspace id, which is the invariant that mutation actually breaks.

## Not covered

- "Updates immediately" on workspace switch is structural rather than asserted: `catalog` is
  `@Observable`, `WorkspaceStageView.body` reads it, and the workspace id is re-threaded from
  that read. `testTheLauncherFollowsItsOwnWorkspaceRatherThanTheSelectedOne` proves the
  correct list is drawn after a selection change, not the SwiftUI invalidation itself.
- The hosted launcher test asserts row *count* through rendered height, not row *labels* —
  no test in this repo reads text out of a hosted SwiftUI view, and the three-way height
  ordering (4 rows > 1 row > no section) is what distinguishes the buckets.
- Not run in the installed app: reinstalling would destroy other sessions' open panes. The
  one user-visible effect on first launch is that the existing `.recent-views.json` is read
  and discarded, so every workspace's launcher starts with no recents.

## Reference
The reported launcher shows `Terminal`, `status`, and task Markdown files under `RECENTLY OPENED` without making their workspace ownership visible. This task scopes the data itself; adding a visual workspace label to globally mixed results is not an acceptable fix.

## Notes
- This is the recent item/view list inside the empty-panel launcher from T-008, not the recent-workspaces menu from T-003/T-032.
- Not committed.
