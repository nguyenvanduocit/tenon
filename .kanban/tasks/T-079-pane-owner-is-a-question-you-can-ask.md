# T-079: The pane→workspace edge is a question you can ask

> `workspace.state.v1` publishes a paginated snapshot; four shipped plugins re-derive the
> pane→tab→workspace join from it by hand, 19 byte-identical lines each. Publish the edge
> as a narrow core contract, `workspace.pane.owner.v1`, and delete the four copies.

- **priority**: high
- **effort**: M

## Why a second contract rather than a field on `workspace.state.v1`

The fitness function at `docs/architecture-interaction-boundaries.md` ("two public
mechanisms perform the same action") is answered explicitly: the two contracts perform
different actions with different result cardinality.

- `workspace.state.v1`'s action is "return a bounded, paginated structural snapshot of the
  catalog" — a whole-structure read whose result is a page plus a cursor.
- `workspace.pane.owner.v1`'s action is "resolve one edge for one named pane" — total,
  unpaginated, single-valued.

Evidence they are not interchangeable, in both directions: the snapshot cannot answer the
edge question correctly past its first page (`snapshotPage` stops at 256 nodes or at
`maximumEncodedBytesExceeded`, `WorkspaceIntentProvider.swift:627-675`, so a pane in a
large catalog silently resolves to "no owner"); and the edge contract cannot answer
`plugins/git/main.js:65-77`'s selected-workspace question at all, because that question is
about the catalog's selection, not about any pane. Neither subsumes the other, and after
this change each is used only where it fits.

Adding `pane.workspaceID` to `workspace.state.v1` was rejected for two independent reasons.
The decisive one: with the field present the JS still sends the paginated snapshot and
still scans `nodes` twice, so the duplication survives at ~14 identical lines and the
past-first-page wrong answer survives untouched. The secondary one: `design-intent-bus.md`
forbids adding a top-level field to a closed object inside a version.

## Equal-benefit check

`.programmatic` audience, identical to `workspace.state.v1`. `CoreIntentAudienceProfile`
has exactly two cases and neither names `.core` (`CoreIntentCatalog.swift:64-76`), so no
provenance test exists anywhere on the path. What the contract removes — having to
reverse-engineer pane→tab→workspace from a paginated snapshot — is knowledge bundled
authors already have and third-party authors must infer, so third parties benefit strictly
more. No design smell.

## Owner / files (agent lock)

Session `fdb5e373` (pane-owner lane) — **RELEASED 2026-08-07**. Every file below is free.

Landed in: `Workspace.swift`, `CoreIntentCatalog.swift`, `WorkspaceIntentProvider.swift`,
`CoreIntentCatalogTests.swift`, `InteractionBoundaryFitnessTests.swift`,
`WorkspaceScopedViewStateTests.swift`, `KanbanPluginTests.swift`,
`WorkspaceIntentProviderTests.swift`, four `plugins/*/main.js`, four
`plugins/*/manifest.json`, `design-plugin-view-instances.md`, `design-pane-slots.md`.

## Criteria
- [x] `workspace.pane.owner.v1` exists in the core catalog: `.programmatic` audience,
      `.workspace` lane, `.read` effects, `paneID` in, `{workspaceID, workspacePath, tabID}` out
- [x] `WorkspaceCatalog.owner(ofSlot:)` walks the whole catalog, not just the active workspace
- [x] A pane in an unselected workspace resolves correctly
      (`testPaneOwnerResolvesForAPaneInAnUnselectedWorkspace`)
- [x] A pane past the first `workspace.state.v1` page resolves correctly, and the same test
      asserts the snapshot does not (`testPaneOwnerResolvesAPaneBeyondTheFirstSnapshotPage`)
- [x] No shipped plugin re-derives the join: no `tabWorkspace` map in any `main.js`
      (`testNoShippedPluginReimplementsThePaneToWorkspaceJoin`)
- [x] `kanban` and `claude-sessions` no longer declare `workspace.state.v1` in `intents.uses`
- [x] `docs/architecture-interaction-boundaries.md` lists the intent in its Workspace row
      (:450) and its `workspace` lane row (:473). T-078 released that file mid-task, so
      this lane closed the row itself rather than handing it on.

## What the count actually cost

The core inventory grew 42 → 43. The edit surface around that was eight hard-coded count
assertions, not the six the design predicted: `CoreIntentCatalogTests.swift:41-44,68,69,687`
(`:41` is `contractSnapshot.revision`, which equals the contract count and the design
missed) and `InteractionBoundaryFitnessTests.swift:814`, which the design did not list at
all and which only surfaced on the full-suite run.
