# T-103: Remove the docs pane
> "Open Docs" opens a worse copy of a pane the file kind already draws better — the command and the `.docs` content kind both go.
- **priority**: medium
- **effort**: M

## Why

`SlotContent.docs` renders one of three hard-coded candidates
(`["README.md", "VISION.md", "docs/README.md"]`, `BuiltInSlotViews.swift:250`) as plain
`Text` in 10 pt mono — no markdown, no navigation, no way to reach any other file under
`docs/`. `SlotContent.file` already routes the same job through three renderers
(image / web preview / text editor with editor state, `BuiltInSlotViews.swift:64-80`), and
the bundled file explorer reaches every file in the tree. The only thing `.docs` still buys
is "open README without typing its name", which is not worth a content kind, a view, a
model, a header projection, a persistence record, a settings option and a palette command.

User-directed, 2026-08-09: remove the command **and** the slot kind. No shim, no deprecated
alias — the tree must read as if the docs pane had never existed.

## Owner / files (agent lock)

Session `d1c1a8c6`. **ALL LOCKS RELEASED 13:0x** — every file below is free.

## What shipped

Nine source files, two plugin files, twelve test files and four documents. The command is
gone from `plugins/core-commands` (12 provisions → 11), and `SlotContent.docs`,
`DefaultPaneContent.docs`, `DocsSlotView`, `DocsModel` and `DocsPaneHeader` no longer exist —
155 lines came out of `BuiltInSlotViews.swift` alone. `rg '\.docs\b'` over `Sources/`,
`Tests/` and `plugins/` returns nothing.

**The removal exposed a defect worth more than the removal.** `AppPreferences.init(from:)`
decoded its three `DefaultPaneContent` keys with a throwing `decodeIfPresent`, so retiring a
case would have made every preferences document naming it fail *whole* — accent, sidebar
width and every paused automation schedule lost with it, silently, on first launch. The two
other decoders on this path were already fail-soft (`WorkspaceCatalogStore.content(of:)` →
`.empty`, `RecentStore.decode` → drop the row); this one now matches them, and the rule is
mutation-proved: putting one key back to a strict decode turns
`testAPaneContentThisBuildCannotNameCostsThatKeyOnlyAndNotTheDocument` red on its own
(restore `cmp`-verified byte-identical).

Tests that used `.docs` merely as *some* content kind were re-pointed rather than deleted —
each to a value distinct from the others in its own test, since several assert that two
workspaces hold different lists. Two existing tests already covered the saved-state halves
(`testAContentTypeThisBuildCannotNameDegradesThatPaneToEmpty`, renamed from
`…FromANewerBuild…` because a retired kind is now the second way to arrive there), so the
only new tests are the preferences one above and a recents one that hand-edits an unreadable
row into the persisted JSON.

EVIDENCE: full suite **1696 / 0** at 12:44. A later full run showed exactly one failure,
`DomainTagFitnessTests.testLongTaggedFilesTagEveryMarkSection`, naming
`ShellTitleBar.swift:917/943/984` — three new `// MARK:` sections without `@domain:` tags in
T-101's file, untouched by this task (⚠️ **for session `aae57603`**: that is yours, and the
same session briefly broke the shared target's compile at `ShellTitleBar.swift:456`). Scope
re-run over all 19 affected suites: **220 / 0**.

⚠️ **One honest limit**: `EmptyStateCard` lost a button and was never photographed. The
snapshot renderers cover plugin views, diff, changes, timeline and the sidebar; no offscreen
renderer exists for the empty-state launcher card, so its new four-button layout is asserted
in code and unseen.

## Criteria
- [x] No `SlotContent.docs`, `DefaultPaneContent.docs`, `DocsSlotView`, `DocsModel` or
      `DocsPaneHeader` remains anywhere under `Sources/`; `rg` proves zero hits.
- [x] `plugins/core-commands` neither provides nor handles `docs.open.v1`, and the palette
      no longer offers "Open Docs".
- [x] A saved workspace holding a docs pane restores to an empty pane instead of failing.
- [x] A preferences file naming `"docs"` still decodes, costing that one key only.
- [x] A recents row naming a retired content is dropped, not surfaced.
- [x] `swift build` clean; suite 1696 / 0, scope 220 / 0.
