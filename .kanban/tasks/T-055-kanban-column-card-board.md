# T-055: Kanban renders a real column/card board and moves cards between columns
> Replace the row-tree list with native columns and cards (hstack/card/badge/button vocabulary already shipped), with per-card move buttons that rewrite board.md. Requires paged atomic write on `filesystem.file.write.v1` — the real board is 113 KB and the write intent is bounded at 48 KB inline, exactly the bound T-052 lifted for reads.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
Session ed76fd97 (ultracode). QUEUED behind T-054's build lock — claims recorded now,
work starts when T-054's workflow finishes testing:
- poc/Sources/TenonCore/CoreIntentCatalog.swift
- poc/Sources/TenonCore/FilesystemIntentProvider.swift
- poc/plugins/kanban/main.js
- poc/plugins/kanban/manifest.json
- poc/Tests/TenonCoreTests/CoreIntentCatalogTests.swift
- poc/Tests/TenonCoreTests/FilesystemIntentProviderTests.swift
- poc/Tests/TenonCoreTests/KanbanPluginTests.swift

## Design
Host — paged atomic write, mirroring T-052's read paging vocabulary:
- `filesystem.file.write.v1` gains optional `cursor`. First page (no cursor) writes to a
  host-owned staging file beside the target and returns a cursor; later pages append to
  the staging file via that cursor; the page carrying `commit: true` atomically renames
  staging over the target. Bounded: per-page ≤ `maximumInlineTextCharacters`, total
  staged bytes bounded (e.g. 1 MB), abandoned stagings expire (bounded lifetime,
  invariant 10). Single-page writes (no cursor, commit default) behave byte-identically
  to today — existing consumers untouched. Watchers/agents never observe a half-written
  board: only the rename is visible.
Plugin — the board:
- `tenon.views.set` body tree: `hstack` of column `vstack`s — header text + count
  `badge`, then `card` per task (id, clipped title, meta badge), buttons on the card:
  `[◀]`/`[▶]` move to adjacent column, `▸ Start` = existing `terminal.open.v1` flow,
  card button toggles the detail (description/priority/criteria from the task file)
  rendered under the card. Read `view-gallery` for the exact node JS shapes.
- Bounds stay: ≤12 cards per column + "… N more", labels clipped, board read is the
  T-052 paged read.
- Move = re-read board (paged), relocate the one task line to the target column
  section, paged-write + commit. On write failure or invalidation, refresh and report
  in-pane (honest errors per T-052). The fs.watch refresh reconciles concurrent agent
  edits; last-writer-wins on the one moved line is acceptable for the PoC board.
- manifest: permissions += "filesystem.write"; intents.uses += filesystem.file.write.v1.
Note for dev runs: `filesystem.file.write.v1` is `confirmation: policy` — an untrusted
`TENON_PLUGINS_DIR` inventory prompts per consent; `TENON_TRUST_PLUGIN_INVENTORY=1`
gives the dev inventory the bundled standing consent (documented flag, this exact use).

## Criteria
- [ ] Paged write: a >48 KB body lands byte-identical via pages + commit; the target
  never holds intermediate content (watcher sees exactly one change); single-page
  writes keep today's reply shape; staged bytes and staging lifetime bounded;
  mutation proofs on the atomicity and bounds
- [ ] Board renders columns side by side with cards (hstack/card tree through the real
  shipped JS in tests), 12-per-column cap intact, detail expansion works
- [ ] Move buttons rewrite the real 113 KB-scale board correctly: the task line moves
  column, everything else byte-identical
- [ ] Failed/invalidated write renders an honest in-pane error, never silent loss
- [ ] Full `swift test` green; independent review pass
