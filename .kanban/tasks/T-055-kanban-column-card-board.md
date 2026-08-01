# T-055: Kanban renders a real column/card board and moves cards between columns
> Replace the row-tree list with native columns and cards (hstack/card/badge/button vocabulary already shipped), with per-card move buttons that rewrite board.md. Requires paged atomic write on `filesystem.file.write.v1` — the real board is 113 KB and the write intent is bounded at 48 KB inline, exactly the bound T-052 lifted for reads.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
Released — DONE 09:0x, session ed76fd97. All claimed files are FREE.

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
- [x] Paged write: staging dot-file (0600, O_EXCL/O_NOFOLLOW, through T-054's bound
  parent) + fsync + atomic `renameat`, so the target changes exactly once; single-page
  writes keep today's exact `{}` reply; bounds are named constants
  (`maximumStagedFileWriteBytes` 1 MiB, 4 concurrent stagings, 300 s lifetime swept at
  next use); forged/replayed/expired/cross-target cursors fail closed as
  `tenon.invalid-input` and reclaim the staging. Mutations: stage into the target
  directly / drop the bytes bound / drop cursor identity — each reddened exactly one
  named test. Review added the missing atomicity pin: the committed target's inode
  equals the staging's, which a rewrite-in-place could never satisfy.
- [x] Board renders columns side by side with cards, 12-per-column cap + "… N more",
  detail expansion in-card
- [x] Move buttons rewrite the board correctly (verbatim line relocation, everything
  else byte-identical), staged pages + commit on a >48 KB board
- [x] Failed/invalidated write renders an honest in-pane error and re-reads from disk
- [x] Full `swift test` green (972 tests; the one red is peer T-062's in-flight
  `PluginIntentManifestTests` — they made the intents envelope optional mid-TDD, no
  overlap with these files). Owned areas 57/0, build clean under warnings-as-errors.
- [x] **Looks like a board — verified in pixels, not in prose.** The 5-finding review
  panel and 24 green tests both passed a board that rendered as scattered cards. An
  offscreen render (`NSHostingView` + `cacheDisplay`, the `DiffSnapshot` recipe; the
  process has no Screen Recording grant so `screencapture` fails) showed columns
  vertically centred against each other, empty columns collapsed to nothing, titles
  wrapped into single-word columns and buttons truncated to "Det…". Fixed: a column is
  a `box` (the one node claiming full offered width) ending in a `spacer` (fills the
  row height, so cards pin to the top); the card's title is its own line under the id;
  `MAX_CARD_TITLE`/`MAX_CARD_META` clip what text nodes will not; the control row is
  packed, not spread. Re-rendered to confirm. New test
  `testEveryColumnIsAFullWidthBoxThatPinsItsCardsToTheTop` pins the two structural
  halves; mutations M47 (drop the spacer) and M48 (box → vstack) each reddened it on
  its named assertion, both restores cmp-verified byte-identical. Snapshot scaffolding
  removed (`PluginNodeView` visibility restored byte-identical); the capability is
  filed as [[T-063]].
