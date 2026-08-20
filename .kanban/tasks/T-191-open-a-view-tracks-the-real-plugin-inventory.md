# T-191: The empty-pane card's "Open a view" list tracks the real plugin inventory

> Operator-reported (screenshot): `+`/tab-right-click's `LauncherMenu` popover and the
> empty-pane/empty-tab `EmptyStateCard` showed visibly different "Open a view" sections —
> 6 tiles with full command names versus 4 with short ones — from what `command-surfaces.prd.md`
> §3 calls one shared launcher vocabulary.

- **priority**: medium
- **effort**: S

## Root cause (verified 2026-08-19)

- `LauncherMenu`'s "Open a view" tile grid reads live off `CommandIndex` — every plugin
  manifest command declaring `launcher: true, fillsPane: true`
  (`LauncherMenu.swift:523-526, 576-593`).
- `EmptyStateCard`'s own "Open a view" grid instead reads `EmptyPaneOfferings.views`
  (`EmptyPaneOfferings.swift:35-48`) — a **hand-written, static array**, 4 entries (Files,
  Changes, Automation, Browser).
- T-188 (same day, task immediately before this one) already found and named this exact gap
  — "`EmptyPaneOfferings`' hardcoded 'Open a view' list (missing Kanban) is a named 'second
  command registry'" — and deliberately left it, because deriving `views` from `CommandIndex`
  for real needs a command id to resolve back to the `SlotContent` an empty pane can fill in
  place, which needs `SlotContent` to stop being a closed enum (T-149, effort L: rewrites
  `Workspace.swift`/`WorkspaceCatalogStore.swift` and 5 exhaustive switches across 16 files).
- Confirmed against the real `plugins/` inventory: 7 manifests declare `fillsPane: true`
  (terminal, changes, automation, files, browser, kanban, claude-sessions). Excluding the
  terminal CTA, `views` was missing exactly 2 — `dev.tenon.kanban.open.v1` and
  `dev.tenon.claude-sessions.open.v1` — the precise 4-vs-6 gap in the screenshot.
- Operator chose the narrow fix over T-149: keep `views` hand-synced (still a "second
  registry"), but make the sync failure loud — a test walking the real manifest inventory,
  not a screenshot — instead of silent.

## Scope

1. `EmptyPaneOfferings.swift`: append `.pluginView(pluginID: "dev.tenon.kanban", viewID:
   "board")` and `.pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions")` to
   `views` (appended, not inserted, so existing index-addressed tests/pick ids for Files/
   Changes/Automation/Browser are untouched).
2. New test `EmptyPaneSearchTests.testOpenAViewOffersEveryFillsPaneCommandInTheRealPluginInventory`:
   loads every manifest under `plugins/` via `PluginLoader`, collects every
   `launcher: true, fillsPane: true` command id (minus the terminal CTA), and asserts both
   that this set matches a hand-written expectation map and that `views` offers the expected
   `SlotContent` for each — red first (2 ids missing), green after.
3. `command-surfaces.prd.md`/`.feature`: new `CMD-FR-025`, delivery-matrix row, decision log
   entry, verification receipts, change history, 2 new Gherkin scenarios; the CMD-FR-022/023
   delivery-matrix row's stale "4-item list (missing Kanban)" claim corrected.

## Owner / files (agent lock)

- `Sources/TenonApp/EmptyPaneOfferings.swift`
- `Tests/TenonAppStateTests/EmptyPaneSearchTests.swift`
- `docs/prds/command-surfaces.prd.md`, `docs/prds/command-surfaces.feature`

None held by any current `Doing` card (T-179/T-178/T-177/T-144/T-141/T-140/T-135 name none of
these three files).

## Explicitly out of scope

Rewriting `SlotContent` from a closed enum into a registry so `views` is genuinely derived
(T-149) — the operator chose the narrow sync-and-test-guard fix after seeing T-149's real
blast radius (`Workspace.swift`, `WorkspaceCatalogStore.swift`, 5 exhaustive switches, 16
referencing files), which is disproportionate to a presentation-parity report.

## Criteria

- [x] `EmptyPaneOfferings.views` offers all 6 real `fillsPane` plugin views (Files, Changes,
      Automation, Browser, Kanban, Agent Sessions).
- [x] New fitness test proven red-then-green against the exact regression, sourced from the
      real `plugins/` inventory rather than a hand-copied list.
- [x] `swift build` clean; full `swift test` green with no regressions.
- [x] `command-surfaces.prd.md`/`.feature` updated: `CMD-FR-025`, delivery matrix (new row +
      corrected CMD-FR-022/023 gap note), decision log, verification receipts, change
      history, 2 new Gherkin scenarios.

## Result

Red-then-green confirmed: `swift test --filter
EmptyPaneSearchTests/testOpenAViewOffersEveryFillsPaneCommandInTheRealPluginInventory` failed
naming both missing ids against the pre-fix `views`, passed after appending the two entries.
Full suite **2397 / 0** (up from 2396, +1 test), 172 s. No new source file, so no `xcodegen`
step was needed. Not committed — left for the operator's own commit/review pass.
