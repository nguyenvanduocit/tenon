# T-133: Two majors the closed-schema law requires

> `workspace.state.v2` and `workspace.pane.split.v2`. T-132 stopped at the edge of both rather
> than widen a closed object inside one major, and left the migration mapped out.

- **priority**: medium
- **effort**: L
- **source**: T-132's decision log, `.kanban/tasks/T-132-five-things-the-app-knows-and-the-cli-cannot-ask.md`
- **owning PRD**: `docs/prds/spatial-panes.prd.md` (decision already recorded there), `docs/prds/cli-control.prd.md`

## Why this is a mint and not an edit

`docs/design-intent-bus.md:620-624` answers it in a table row, verified verbatim:
**"Add any top-level input/output field to a closed object → same major? no."**
`FC-NFR-009` (`files-and-content.prd.md:289`) states the same rule without the "top-level"
qualifier — *"Closed schemas MUST not widen inside one major"* — and `IAR-NFR-008` repeats it.

The standing precedent is `filesystem.directory.list.v2`, whose v1 was **removed outright** with
no shim, pinned today by
`Tests/TenonCoreTests/CoreIntentCatalogTests.swift:111 testTheDirectoryListingShapeChangeMintedANewMajorInsteadOfMutatingV1`.
Follow that shape: mint v2, delete v1, migrate every caller in the same change. No alias, no
deprecation window — `CLAUDE.md`'s "Replacement finishes" applies.

## The two mints

**(b) `workspace.state.v2`** — pane nodes carry `title`, `cwd`, and `exited`.
The data exists: `SurfacePool.swift:445` derives the title from OSC, `:194` holds cwd per pane.
This is what turns `tenon-cli state` from a geometry map into the supervision primitive
`orca worktree ps` provides — the capability survey names that shape as the nearest thing in
either reference to what `VISION.md:18-22` asks for, and it is the single highest-value row
left in the report.

**(d) `workspace.pane.split.v2`** — returns the created `paneID`.
`WorkspaceIntentProvider.swift:330-339` already computes the before/after slot-ID sets and
identifies the new slot, then discards it through `emptySuccess`. `terminal.open.v1` returns
its paneID; a scripted caller cannot chain a split without one.

## What a correct mint must also carry

Worked out by T-132 before it stopped. Every shipped plugin naming the old id in `uses` breaks
if its manifest is not migrated in the same change — that is why these two go together, since
they touch the same three plugins.

| Mint | Files that must move with it |
|---|---|
| `workspace.state.v2` | `plugins/{git,file-explorer,core-commands}/{manifest.json,main.js}`, `Sources/TenonCLI/main.swift` (the `state` alias), `Tests/TenonCoreTests/{KanbanPluginTests,WorkspaceScopedViewStateTests,CLIActionParserTests,CLIProtocolTests,CoreCommandsPluginTests,BundledPluginConsentTests,InteractionBoundaryFitnessTests}.swift`, `docs/{design-cli,design-pane-slots,development,architecture-interaction-boundaries,research-reference-terminals}.md`, `docs/prds/cli-control.feature` |
| `workspace.pane.split.v2` | `plugins/{core-commands,file-explorer}/{manifest.json,main.js}`, `Tests/TenonCoreTests/{FileExplorerPluginTests,CoreCommandsPluginTests}.swift`, `docs/{design-command-palette,design-pane-slots,architecture-interaction-boundaries}.md`, `AGENTS.md` |

## Criteria

- [ ] `workspace.state.v2` minted; pane nodes carry title, cwd, exited; v1 removed outright
- [ ] `workspace.pane.split.v2` minted returning `paneID`; v1 removed outright
- [ ] Every bundled plugin manifest and `main.js` naming an old id migrated in this same change
- [ ] `Sources/TenonCLI/main.swift`'s `state` alias points at v2
- [ ] A fitness test pins each mint the way `testTheDirectoryListingShapeChangeMintedANewMajorInsteadOfMutatingV1` pins the directory-listing precedent
- [ ] No alias, no deprecation shim, no second code path left behind
- [ ] `swift test` green; contract behavior asserted in `TenonCoreTests` without a window
- [ ] Both PRDs' delivery matrices updated with a dated verification receipt

## Owner / files (agent lock)

_Unclaimed._ Claim by listing files here with your session id before the first edit.
⚠️ Touches three bundled plugins and the CLI alias at once — check the board for any Doing task
holding `plugins/` or `Sources/TenonCLI/` before starting.
