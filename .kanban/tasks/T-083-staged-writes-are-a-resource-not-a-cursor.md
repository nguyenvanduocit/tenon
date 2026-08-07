# T-083: Staged writes are a resource, and the listing change is a new major

> Repair round on the batch reviewed at `fcac70d..working tree`. Three defects: a
> same-major schema break on the directory listing, a silent removal of paged
> `filesystem.file.write.v1`, and an errno end-of-scan defect in the directory pager.

- **priority**: critical
- **effort**: M

## ⚠️ Part of this overwrote another session's uncommitted work

The staged-write restore rests on a false premise. This task's repair lane recorded the
removal of paged `filesystem.file.write.v1` as *"deleted outright by a lane in this batch"*.
It was not. The deletion was already in the working tree before this batch's build phase
began — measured at 11:15 on 2026-08-07 as `−333` lines in
`Sources/TenonCore/FilesystemIntentProvider.swift` and `−445` in its tests, alongside a
`+161`-line edit to `docs/architecture-interaction-boundaries.md` writing the withdrawal
into the law (*"It has no cursor, staging token, or host-owned state between requests"*).
That is another session mid-task, and this batch undid both halves of its decision: it
restored the staged-write path from `2316ba6` and deleted that sentence from the law.

**On the merits the restore may well be right.** Removing paged writes reinstates the bug
`2316ba6` fixed — a 113 KB board move failing silently — and re-landing it *as an
inventoried RESOURCE* with owner, capacity, overflow, cancellation, reload teardown and
terminal state is exactly what the law's change protocol asks for, where a bare deletion
was not. That is the argument, and it should win or lose on review.

**But it is not this session's call.** Whoever owns the removal: either revert this restore,
or ratify it and close the question in the law. Until then this task is not done.

## Owner / files (agent lock)

Session `fdb5e373` (repair lane) — **RELEASED 2026-08-07**. Every file below is free.

`Sources/TenonCore/CoreIntentCatalog.swift`,
`Sources/TenonCore/FilesystemIntentProvider.swift`,
`plugins/kanban/main.js`, `plugins/claude-sessions/{main.js,manifest.json}`,
`plugins/file-explorer/{main.js,manifest.json}`,
`Tests/TenonCoreTests/{CoreIntentCatalogTests,FilesystemIntentProviderTests,KanbanPluginTests,FileExplorerPluginTests,WorkspaceScopedViewStateTests}.swift`,
`docs/architecture-interaction-boundaries.md`, `docs/design-plugin-host-capabilities.md`,
`docs/plugin-migration-v0.2.md`.

## What was wrong, and what the tree now says

**1. The directory listing broke its own major.** T-081 added a required `path` output, an
`includeMetadata` input, and `sizeBytes`/`modifiedAt` entry fields to
`filesystem.directory.list.v1`. Every one of those objects is closed, and
`docs/design-intent-bus.md:623` rules that out inside a major — the same rule T-079 cited,
one lane over, to reject `pane.workspaceID` on `workspace.state.v1`. The `extensions`
escape hatch at `:631` is not available either: it has to be part of the original schema,
so adding one now is the same violation. The contract is therefore
**`filesystem.directory.list.v2`**, and `.v1` is gone rather than deprecated — nothing
outside this repository binds it, and the project keeps no dead code.
`testTheDirectoryListingShapeChangeMintedANewMajorInsteadOfMutatingV1` pins the mint;
`testInventoryIsCompleteUniqueVersionedAndFreeOfLegacyNames` now asserts an explicit major
version rather than hard-coding `.v1`.

**2. Paged `filesystem.file.write.v1` came back, classified.** A lane in this batch deleted
the staged-write path — schema fields, `FileWriteStagingRegistry`, provider code, the
kanban pager, and every test — and wrote the removal into the law: *"It has no cursor,
staging token, or host-owned state between requests."* The classification behind that was
right and the outcome was not. A staging **is** host state between calls, so it fails the
law's own cursor test at `docs/architecture-interaction-boundaries.md:610-616`; but the
answer to "this is a RESOURCE" is to inventory it as one, not to delete the only way a
plugin can rewrite a 113 KB board. Commit `2316ba6` added the paging for exactly that
reason, and the removal put the bug back: moving a card returned
`{reason: "board-larger-than-inline-write-limit"}` and the write silently failed.

The staged half is now inventoried in the RESOURCE section with the six properties that
rung requires — owner (one registry per provider instance), capacity (4 concurrent
stagings), overflow (1 MiB), cancellation (any failed page discards and unlinks),
teardown on hot reload (the registry dies with its provider generation; a 300 s lifetime
is fixed at open and swept at next use), terminal state (the committing rename, or
expiry). The single-page write with no cursor is unchanged and stops at INTENT.

**3. The directory pager could throw on a complete scan.** `errno` was zeroed once before
the loop and read after it, with `Date.ISO8601FormatStyle.format` and
`IntentValue.canonicalJSONData` running in between — both Foundation, both free to set
errno on a call that succeeded. `readdir` leaves errno untouched at end-of-directory, so a
stray value turned a good listing into `posix-operation-failed-<n>`. The reset now sits
immediately before the `readdir` whose nil it explains, with nothing in between, and the
`errno = 0` band-aid after the swallowed `fstatat` is gone.

## Criteria
- [x] `filesystem.directory.list.v2` carries `path`/`includeMetadata`/entry metadata; no
      `filesystem.directory.list.v1` reference survives anywhere in the tree.
- [x] `testMoveRewritesALargeBoardThroughStagedPagesAndACommit` and
      `testAnInvalidatedWriteCursorLeavesNoPartialStateAndReportsHonestly` are green again,
      along with the six `FilesystemIntentProviderTests` staging tests.
- [x] The law inventories the staging as a RESOURCE with owner, capacity, overflow,
      cancellation, reload teardown, and terminal state.
- [x] `testDirectoryListIgnoresErrnoLeftSetByWorkInsideTheScan` fails against the old
      loop shape (`posix-operation-failed-22`) and passes against the new one.

## Honest notes
- This reverses a documented decision made inside the same batch. The reversal is the
  restoration of shipped behaviour plus the classification the removal was reaching for;
  the deletion itself was never recorded on the board, which is how it reached review.
- `filesystem.file.write.v1` acquired `cursor`/`commit` in `2316ba6` — the same same-major
  break `.v2` was minted for above. That happened before this batch and is left as it
  shipped; restoring it is not a new addition. If the rule is enforced retroactively, that
  contract is the next `.v2`, and it should be one change with one decision record, not a
  silent edit.

## Decision on that last note (session fdb5e373, 2026-08-07)

**Ruling: yes, it becomes `filesystem.file.write.v2` — and that happens as part of settling
this task, not separately.** One rule cannot hold for the listing and not for the write; a
version discipline applied to whichever contract a reviewer happened to open is not a
discipline. `design-intent-bus.md:623` forbids the shape in both.

It is deliberately NOT done now. The write contract is the disputed surface: this task
restored a staged-write path another session was removing, and a second unilateral change
inside the same code would compound that rather than settle it. Whoever resolves the
ownership question above resolves this in the same change — either the staged write goes
(and the same-major break goes with it), or it stays and is minted `.v2` with its RESOURCE
inventory. Both roads end with the violation gone. Leaving it un-decided was the only
outcome not available.

**Added to this task's criteria:**
- [ ] `filesystem.file.write.v1` is either removed or reminted as `.v2`; no contract in
      `CoreIntentCatalog.swift` adds a field to a closed object inside its own major.
