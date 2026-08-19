# T-187: The tab-strip launcher groups like the empty-state card
> Operator-requested (screenshot): `+` and tab-chip right-click (LauncherMenu, purpose `.open`) get
> the same empty-query grouped presentation as EmptyStateCard — Add Terminal CTA, Start an Agent,
> grouped commands, Recently Opened, Pane utilities — while `.fillEmptyGrid` and any typed query
> stay exactly as they are today.
- **priority**: medium
- **effort**: M

## Scope decisions (asked via AskUserQuestion, all "Recommended" accepted)
1. Only `.open` purpose (tab-strip `+`, tab-chip right-click). `.fillEmptyGrid` (empty canvas
   click) is untouched.
2. Add a "Recently opened" section, bound to `store.recent?.recent(for: workspaceID)`, same as
   EmptyStateCard.
3. `PaneArrangementMenu`/Copy Tab ID move into a new labelled "Pane" section, same card style.

## Pre-existing uncommitted work on these files (T-177, session 2d71b9c2)
`ShellTabStrip.swift` (new, untracked), `LauncherMenu.swift`, `EmptyStateCard.swift`,
`LauncherListHeight.swift`, `Tests/TenonAppStateTests/LauncherListHeightTests.swift`,
`Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` already carry uncommitted diffs
(tab strip split to its own file, opens at either window edge, EmptyStateCard's search-first
rework). Operator confirmed (2026-08-19) it is safe to build on top of that tree as-is.

## Owner / files (agent lock)
Released 2026-08-19 — task Done, not committed.

## Criteria
- [x] `LauncherMenu` renders the grouped card layout only when `purpose == .open` and the query
      is empty; typed query and `.fillEmptyGrid` are byte-for-byte unchanged.
- [x] "Add Terminal" is pulled out of the ranked list by its canonical command id and dispatched
      through the existing `run(_ match:)` path (no second terminal-launch mechanism).
- [x] "Recently opened" reuses `RecentRow`, wired from each call site's own `store.recent`.
- [x] Pane utilities render under a "Pane" section in the grouped layout, unchanged elsewhere.
- [x] `swift build` and `swift test` both green (2387/0); `DomainTagFitnessTests` isolation
      comment updated — `EmptyStateCard` left the isolated set, budget held at 8 since an
      unrelated file (concurrent work, out of scope) filled the slot.
- [x] New tests cover: terminal CTA extraction, category filtering, recents wiring, and that
      `.fillEmptyGrid` is unaffected. Typed-query is a reading guarantee, not a runtime one —
      `LauncherMenu` has no query-injection seam (`EmptyStateCard`'s `initialQuery` has no
      equivalent here), and `results`/`PaletteRow` are untouched code, gated behind
      `!showsGroupedLayout` rather than modified.

## Known gaps
- Grouped-layout height is computed from literal `.frame(height:)` constants read off every
  reused row type (exact by construction), but no headless run can photograph a live
  `NSPopover`'s actual pixels — a several-point mismatch would be a cosmetic defect this
  suite cannot catch. Worth a live look (`./tenon dev`) before calling this pixel-verified.
- Only `.open` groups, by explicit operator choice; `.fillEmptyGrid` (empty-canvas right-click)
  keeps the flat list, so the app now has two distinct popover presentations by design.
