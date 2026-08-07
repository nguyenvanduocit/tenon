# T-081: The directory listing tells you how big and how old
> `filesystem.directory.list.v1` gains an opt-in `includeMetadata` flag carrying `sizeBytes`/`modifiedAt`, plus a required `path` echo of the resolved directory, so claude-sessions can stop shelling out to `stat -f`.
- **priority**: medium
- **effort**: M

## Owner / files (agent lock)
Released 2026-08-07 — done. No files are claimed by this task.

## Criteria
- [x] `includeMetadata: true` adds nullable `sizeBytes` and ISO-8601 `modifiedAt` to every entry; absent by default (pay for what you use) — `testDirectoryListReportsSizeAndModificationTimeWhenRequested`, `testDirectoryListOmitsMetadataUnlessRequested`.
- [x] The reply carries the resolved absolute `path` of the listed directory, matching every other filesystem intent — `testDirectoryListReportsTheResolvedDirectoryPath` lists through a symlinked parent, so requested and resolved differ by construction.
- [x] `includeMetadata` never changes `isDirectory` — `testIncludeMetadataDoesNotChangeIsDirectory`; a symlink to a directory reports false in both listings, which is what a stat that followed the link would get wrong.
- [x] A vanished entry yields null metadata and the page still succeeds — `testDirectoryListMetadataIsNullWhenAnEntryVanishesMidPage`. The swallowed `fstatat` resets `errno`; without that the end-of-directory check reads a clean scan as a failure and the whole call throws.
- [x] The page is validated once, not once per prefix — `testDirectoryListValidatesTheAssembledPageOnceInsteadOfEveryPrefix` counts exactly 1 for a 256-entry page. The old loop ran a full traversal plus a full `JSONEncoder` pass per entry.
- [x] claude-sessions scans transcripts through the intent; `parseStat` and the `%m %z %N` regex are deleted.

## Notes
- The accounting constant is measured, not derived on paper: canonical page bytes ==
  36 + |path| + |cursor| + Σ|entry| + (n−1), matched to the byte for escaped quotes,
  backslashes, an embedded `/` under `.withoutEscapingSlashes`, multi-byte UTF-8, and both
  a string and a `null` cursor.
- `directoryPage` / `DirectoryCursor` / `DirectoryPage` moved from the file's `private`
  extension into its existing internal one, whose comment already records why: the states
  these tests drive are unreachable through the public binding.
- Honest cost: this removes one of three exec sites. `process.exec.v1` survives for the awk
  enrichment pass and the Codex SQLite query, and declared authority GROWS by
  `filesystem.read`. Effective authority is unchanged — `process.exec` already subsumed
  reading these files. Do not describe this as reducing plugin authority.
- Follow-up worth having: above 256 transcripts a live session writing into the directory
  can retire the cursor mid-scan (`stale-cursor`), where the old shell glob had no
  equivalent failure. The plugin restarts once. The real fix is a fingerprint that ignores
  pure-append mtime bumps, not a deeper retry loop.
