# T-184: Docs still point at the file a split deleted
> `CoreIntentCatalog.swift` (2,830 lines) was split into `CoreIntentModel.swift`,
> `CoreIntentName.swift`, `CoreIntentRules.swift` (uncommitted, mtimes 2026-08-17) with no
> accompanying doc update and no kanban claim.
- **priority**: low
- **effort**: XS

## Owner / files (agent lock)
Released — DONE 2026-08-19 04:0x, session `16f4140d`. Files were free (no active claim).

## What was stale
Six docs cited `CoreIntentCatalog.swift` as a single file, by path or `.swift:LINE`. The type
still exists (now in `CoreIntentModel.swift`), so bare-symbol mentions elsewhere (PRDs citing
`CoreIntentCatalog`/`CoreIntentCatalogTests` by name, not by path) needed no change — only the
six citing the deleted file path did. Excluded on purpose: `docs/reports/*` (dated evidence,
never edited per this repo's own rule) and the kanban archive (historical receipts).

`docs/domains.md`'s "five longest unsectioned files" example was doubly stale: not just the
named file, but the counts around it (65 files over 400 lines / 49 unsectioned / 41,879 lines
/ "more than half the source tree") no longer match the tree, verified directly (`wc -l` +
`grep -c "// MARK:"` over every `Sources/**/*.swift`, cross-checked against
`DomainTagFitnessTests.testLongFilesDeclareTheSectionsTheMarkRuleReads`'s own predicate, which
still passes: 47 ≤ budget 49). Current: 79 files over 400 lines, 47 declare no MARK at all,
41,005 lines, ~40% of the tree. `CoreIntentRules.swift` (2,401 lines, the split's largest
piece) does NOT enter the new top five — it picked up 4 `// MARK:` sections in the split, so
it no longer qualifies as unsectioned. Not touched: the separate "51 of 78 tags" sentence
below it (different metric, not broken by this split, not independently verified here).

## Fix
Repointed each stale citation to whichever successor file(s) actually carry that row's claim
(name/audience/lane → `CoreIntentName.swift`; contract/schema/bounds → `CoreIntentRules.swift`;
`README.md`'s row already named the enum `CoreIntentName` so it repoints 1:1). Rewrote
`domains.md`'s paragraph with the verified current counts and the new top-five list
(`IntentDispatcher.swift`, `AgentLensView.swift`, `Workspace.swift`, `IntentPolicy.swift`,
`FilesystemIntentProvider.swift`). Split `development.md`'s one source-map line into three.

## Scope note
Left `Tests/TenonCoreTests/DomainTagFitnessTests.swift`'s `unsectionedLongFileBudget = 49`
un-lowered — it is a ratchet meant to trend to zero and the actual count (47) already sits
under it, so nothing is red; tightening it to 47 is a one-line follow-up for whoever owns that
file next, not a docs change.

## Criteria
- [x] No doc outside `docs/reports/` and `.kanban/` cites `CoreIntentCatalog.swift` as a file
- [x] `docs/domains.md`'s file-count claims verified against current `Sources/` tree, not guessed
- [x] `swift build` unaffected (docs-only change)
