# T-188: The launcher becomes one catalog in one card language
> Operator-reported (two screenshots): the tab-strip launcher (`LauncherMenu`, purpose `.open`,
> after T-187) is still too long and fragmented, its card language doesn't match the empty-pane
> card (`EmptyStateCard`), and only the empty-pane card can run typed text as a shell command.
- **priority**: high
- **effort**: M

## Root cause (verified 2026-08-19)
- `LauncherMenu`'s grouped layout (T-187) regroups ranked commands **verbatim by each plugin's
  own manifest `category`** (`LauncherSections.swift:39-52`). `core-commands/manifest.json`
  gives "New Tab" `category: "New"` and the two split commands `category: "Split"` — after the
  terminal CTA is pulled out, "New" is left with exactly one row and "Split" with two, each
  still paying for its own section header. That's the length/fragmentation the screenshot shows.
- `EmptyStateCard`'s "Open a view" tile is **not** driven by `CommandIndex` at all — it's a
  hardcoded 4-item list (`EmptyPaneOfferings.swift:35-48`) rendered as a 2×2 grid, which is
  exactly `docs/prds/command-surfaces.prd.md:114`'s named non-goal ("a second command
  registry") and `CMD-G-001` ("without a duplicate catalog"). It is missing Kanban's own
  `fillsPane` command, a known drift **left unfixed this task** — see Known gaps.
- `EmptyPaneLauncher`/`RunCommandOffer` (`TenonCore/EmptyPaneLauncher.swift`) is the pure,
  already-shared "does this query read as a command line" rule; `LauncherMenu` never calls it.

## Scope decided (operator, via AskUserQuestion: "Hợp nhất triệt để")
1. `LauncherMenu`'s grouped layout (`purpose == .open`, empty query) splits ranked commands by
   `fillsPane` instead of by category: `fillsPane` commands draw as a 2-column tile grid under
   one "Open a view" header (`CommandTile`, new — `Command.icon` is an SF Symbol, so it cannot
   reuse `EmptyStateCard`'s `LaunchTile`, which draws `SlotContent`'s text glyph); everything
   else (`New Tab`, `Split Right`, `Split Down`) folds into the existing "Pane" section next to
   Copy Tab ID / Arrange Panes, rather than keeping its own one-row category header.
   **Correction found by `swift test`**: `CommandTile` could not live in `LauncherMenu.swift` —
   `InteractionBoundaryFitnessTests.testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics`
   (`CMD-NFR-008`) source-scans exactly that file (and `PaletteOverlay.swift`) for a restated
   `.onHover`/`isHovered`. Declared beside `LaunchTile` in `EmptyStateCard.swift` instead,
   `internal` for the same reason every other grouped-layout row type already is.
2. `LauncherMenu` gains `runCommand: ((String) -> LauncherOutcome)?`, wired at all three anchors
   (`ShellTabStrip.swift` `+`/right-click via `.newTab`/`.tab(id)`, `SpatialCanvasNSView.swift`
   fillEmptyGrid via `.emptyGrid(rect)`) through the existing `TerminalCommandLaunch.run`, the
   same placement/delivery path agent launches and `EmptyStateCard`'s own run-command already
   share. Typed-query flat list only (grouped layout has no typed text); reuses
   `RunCommandOffer.placement(for:)` unchanged, no second "is this a command line" rule.
3. `LauncherMenu` gains `initialQuery: String = ""` (mirrors `EmptyStateCard`'s existing seam)
   so the typed-query run-command row is height-testable the same way
   `EmptyPaneSearchTests.height(typing:)` already proves it for the empty-pane card.
4. `.fillEmptyGrid` and the flat list's existing rows/rendering stay byte-for-byte unchanged
   except for the new optional run-command row — same invariant T-187 held.

## Known gaps (left out of this task, on purpose)
- `EmptyPaneOfferings.views`' hardcoded list (missing Kanban) is not touched — replacing it with
  a real `CommandIndex.paneFillersOnly` ranking needs `SlotContent`'s closed-enum id→content
  mapping to become dynamic, which is T-149's exact scope ("A native surface declares itself
  instead of being spelled into an enum"), not this task's.
- `EmptyStateCard`'s own dispatch (`onLaunch(SlotContent)`, no intent runtime) is left exactly
  as-is — routing it through `PaletteIntentInvoker` the way `.fillEmptyGrid` already does would
  need pane/tab-scoped intent invocation this task did not verify exists; too large a blast
  radius to take on silently inside a presentation-consistency fix.
- Grid-height arithmetic for the new tile section has no live-pixel check available (no
  `TENON_*_SNAPSHOT` route reaches a real `NSPopover`, same limitation T-187 recorded) — owed a
  live `./tenon dev` look.

## Owner / files (agent lock)
Released 2026-08-19 — task Done, not committed.

## Criteria
- [x] `LauncherMenu`'s grouped layout renders `fillsPane` commands (minus the CTA) as a 2-column
      tile grid under "Open a view"; non-`fillsPane` launcher commands render inside "Pane"
      alongside Copy Tab ID / Arrange Panes instead of their own category section.
- [x] `groupedContentHeight` accounts for the grid's row-packed height exactly (no estimate);
      a test proves 2-column packing (3 items need one more row than 2; 4 items need the same
      row count as 3).
- [x] `runCommand` renders a leading/trailing row in the typed-query flat list per
      `RunCommandOffer.placement(for:)`, dispatches through the supplied closure (not the intent
      path), and is absent entirely when `runCommand` is `nil`.
- [x] All three anchors wire `runCommand` through `TerminalCommandLaunch.run` with their own
      placement, matching how they already wire `launchAgent`.
- [x] `.fillEmptyGrid` purpose and every existing typed-query row/behavior are unchanged except
      for the new optional run-command row.
- [x] `swift build` and `swift test` both green (full suite **2392 / 0**, up from 2387 — 5 new
      tests); new/extended tests cover the grid packing, the Pane-section fold, and the
      run-command row's placement + dispatch + absence-when-nil.
- [x] `command-surfaces.prd.md`/`.feature` updated: `CMD-FR-022`/`CMD-FR-023` added to the
      requirements table, delivery matrix, decision log, change history, verification receipts,
      and 5 new Gherkin scenarios in `command-surfaces.feature`.

## Result
`CommandTile` ended up in `EmptyStateCard.swift`, not `LauncherMenu.swift` as scoped — see the
correction note under Scope decided. Everything else shipped as scoped. Not committed; files
released for the next agent/commit pass.
