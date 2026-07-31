# T-054: A path whose ancestor directory does not exist is denied as invalid instead of answering path-not-found
> `filesystem.file.read.v1` of `<workspace>/.kanban/board.md` in a workspace with no `.kanban/` is denied `invalid-filesystem-path` by the kernel binding; even `filesystem.path.exists.v1` cannot answer `false` for such a path. The kanban pane in the poc workspace renders "Board read failed: invalid-filesystem-path" where "No board at …" is the truth.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
Released — DONE 01:0x, session ed76fd97. All claimed files are FREE.

## Root cause (verified)
- `IntentPolicy.swift:93-145` — `AuthorizedFilesystemPath.init` already tolerates a
  nonexistent **leaf** (`existedAtAuthorization=false`, needed by file.create) but
  requires the **immediate parent** to open (`Darwin.open(parent, O_DIRECTORY)`,
  :112-117); a missing ancestor throws → `PolicyDenialReason.invalidFilesystemPath`.
- Seen live at 23:4x in the poc-workspace kanban pane; the same denial breaks
  `filesystem.path.exists.v1` (cannot say `false`) and misclassifies create/write
  toward missing directories.
- No recorded decision and no test pins missing-parent-as-invalid; the only pin is
  relative paths deny (`IntentPolicyTests.swift:224`), which must stay.

## Design
Bind against the deepest EXISTING ancestor instead of the immediate parent:
- Walk up from the parent until a directory opens; open+verify it exactly as today
  (O_DIRECTORY, fstat/lstat dev+ino cross-check).
- Validate every missing suffix component lexically, fail closed: non-empty, not "."
  or "..", no NUL, no "/". They cannot be symlinks at binding time (they do not
  exist); the provider's open must not follow symlinks anywhere in the suffix at use
  time (O_NOFOLLOW_ANY or a component-wise openat walk) to close the create-a-symlink
  TOCTOU in the widened window.
- `resolvedPath` = resolved ancestor + literal suffix, so grant prefix matching is
  unchanged; a missing path OUTSIDE the grant still denies exactly as today.
- Keep unchanged: relative/NUL/empty deny, symlink-leaf deny, dev/ino cross-check.
- Provider: a read/list of a path with `existedAtAuthorization == false` (or ENOENT at
  open) reports `path-not-found`; `path.exists` answers `false`; create/write toward a
  missing ancestor keeps failing (no implicit mkdir) with `path-not-found`.
Result: kanban's existing mapping renders "No board at <path>" with zero plugin change.

## Criteria
- [x] Read of a missing file whose ancestors are also missing, inside the grant →
  `dev.tenon.core.path-not-found`, not a policy denial —
  `testReadListAndExistsOnMissingAncestorChainAnswerNotFound` (read + directory.list)
- [x] `filesystem.path.exists.v1` answers `exists:false` for the same path — same test;
  after review-fix, a regular FILE occupying an ancestor position also answers
  false / path-not-found instead of denying (the walk treats lstat-non-dir like ENOENT
  without ever traversing the occupying file)
- [x] A missing path outside the grant still denies (`filesystem-path-outside-grant`),
  and relative/NUL/`..`/symlink-leaf paths still deny exactly as before —
  `testMissingAncestorChainBindsInsideGrantAndOutsideGrantStillDenies`,
  `testMissingSuffixComponentValidationRejectsTraversalSpellings`,
  `testSymlinkLeafOnExistingParentStillFailsBinding` (pins untouched, incl.
  IntentPolicyTests relative-path pin)
- [x] Provider open follows no symlink in the previously-missing suffix —
  per-component `O_NOFOLLOW|O_DIRECTORY` openat walk, consolidated after review into
  ONE implementation `AuthorizedFilesystemPath.openLeafParentDirectoryDescriptor()`
  used by both the provider and `validatedResolvedPath`;
  `testSymlinkGrownIntoMissingSuffixAfterBindingFailsClosed` proves a symlink grown
  into the gap fails closed (`authorized-path-became-symlink`), never serves smuggled
  bytes
- [x] Full `swift test` green: **928 / 0** after the review-fix round (921 before it;
  the 918→921 delta was peer T-057's tests). Mutation proofs (a) drop `..` rejection,
  (b) drop the no-follow, (c) drop the dev/ino cross-check — each reddened exactly its
  named test, restores cmp-verified against golden copies. Adversarial panel: 5 raw
  findings → 4 confirmed (1 medium: the `validatedResolvedPath` suffix walk had zero
  coverage — now tested; 3 low: stale API contract — the public
  `duplicateParentDirectoryDescriptor()` trap was deleted outright — stale doc
  comments, and the file-mid-chain truth-table gap) → all four fixed TDD-first.
