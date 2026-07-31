# T-052: Kanban pane reports "No board" when board.md exceeds the inline read limit
> The real board.md is 113 KB; `filesystem.file.read.v1` caps inline text at 48 KB, fails with `inline-content-limit-exceeded`, and the kanban plugin maps every failure to "No board at <path>" — the most misleading thing it could say about a file that exists.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
Released — DONE 22:1x, session ed76fd97. All claimed files are FREE.
(ShippedPluginsTests.swift was claimed but never needed: the regression landed in
KanbanPluginTests, which already drives the shipped JS.)

## Root cause (verified)
- `CoreIntentCatalog.swift:251` — `maximumInlineTextCharacters = 48 * 1024`.
- `FilesystemIntentProvider.swift:628-648` — read past the cap throws `contentTooLarge` → `inline-content-limit-exceeded`.
- `plugins/kanban/main.js` `readFile` returns null on any `!result.ok`; `refresh` renders "No board at …" for every failure, not just path-not-found.

## Design
Mirror `terminal.scrollback.read.v1` paging (T-044) on `filesystem.file.read.v1`:
optional `cursor` input; output gains nullable `cursor` + `invalidated`. First page
without cursor = today's behavior for small files (existing consumers unaffected;
kanban is the only consumer). Cursor encodes byte offset + file identity (size/mtime);
identity mismatch → `invalidated: true`, never shifted bytes. Pages split on UTF-8
boundaries. Kanban pages to completion under a bounded total, distinguishes
path-not-found ("No board…") from real failures, retries invalidated reads bounded.

## Criteria
- [x] `filesystem.file.read.v1` serves a >48 KB UTF-8 file completely via bounded cursor pages; every page respects `maximumInlineTextCharacters`; multi-byte characters never split across pages — `testFileReadServesLargeFileAcrossBoundedUTF8Pages` (3-byte ệ straddling the page boundary, 4-byte 😀 later; reassembly byte-for-byte equal)
- [x] A file mutated between pages returns `invalidated: true` rather than shifted content — `testFileReadCursorReportsInvalidatedWhenFileChangesBetweenPages`; review panel found and closed the final-page TOCTOU too: identity is re-checked *after* every page read (`testFileReadFinalPageInvalidatesWhenFileChangesInsideReadWindow`)
- [x] Small-file reads keep today's single-reply shape (cursor null) — `testFileReadReturnsWholeSmallFileWithNullCursorAndReportsNonText`; catalog SchemaShape pins input [path, cursor] / output [content, cursor, invalidated]
- [x] Kanban pane renders a >48 KB board through the shipped plugin JS — `testABoardLargerThanOneInlinePageRendersItsColumnsWithoutAnErrorRow` (~102 KB, 3 pages, Done column on the last page, no error row); plus `testAReadInvalidatedMidPageRestartsAndStillRendersTheBoard`
- [x] Kanban distinguishes errors — `testAMissingBoardFileStillRendersNoBoard` + `testAFailedBoardReadNamesTheReasonInsteadOfClaimingNoBoard`; only `dev.tenon.core.path-not-found` says "No board", everything else renders "Board read failed: <reason>"
- [x] Full `swift test` green: **909 / 0** (was 901), re-run independently by the coordinator, exit 0. Mutation proofs A–C (host: drop UTF-8 back-off / drop identity check / advance cursor past backed-off bytes) + 2 plugin mutations (drop cursor-follow / every failure claims "No board") each reddened exactly their named test; all restores cmp-verified byte-identical. Forged/malformed cursors fail closed as `tenon.invalid-input` field "cursor" (mirrors scrollback's precedent).
