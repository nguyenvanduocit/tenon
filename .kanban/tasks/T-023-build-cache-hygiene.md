# T-023: One build cache, pruned before every run
> `.build` had grown to 7.0 GB because four build trees each checked out the
> dependency graph and kept its own module cache. Collapse them to one, and prune
> the duplicates before every `dev.sh` / `install.sh` run.
- **priority**: high
- **effort**: S

## Owner / files (agent lock)
RELEASED — session 68979863 is done with `install.sh`, `dev.sh`,
`scripts/prune-build-cache.sh`, `CLAUDE.md`, `README.md`, `docs/development.md`, and
`docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md`.

`install.sh` was already dirty when this started (uncommitted `tenon-cli` bundling
stage, mtime 13:18) and no `Doing` task claimed it — those edits are preserved and
mine are additive.

## Measured before
```
.build                     7.0 G
  xcode                        1.9 G   README's xcodebuild derived data
  xcode-install                1.8 G   install.sh derived data
  arm64-apple-macosx           1.3 G   SwiftPM incremental (dev.sh)
  swiftpm-install-cli          749 M   install.sh scratch, for ONE cli binary
  checkouts + repositories     874 M   deps
  index-build                  491 M   sourcekit-lsp index store
```
The dependency graph is checked out four times (`checkouts`, `xcode/SourcePackages`,
`swiftpm-install-cli/checkouts`, `index-build/checkouts`), and ModuleCache is kept
three times (428 M + 394 M + …).

## Criteria
- [x] Exactly two build trees exist: `.build/arm64-apple-macosx` (SwiftPM) and `.build/xcode` (one derived data path for every configuration) — steady state holds exactly those two plus the shared dep caches
- [x] Dependencies are checked out once and shared — `xcodebuild` is pointed at `.build` via `-clonedSourcePackagesDirPath`; `-resolvePackageDependencies` re-resolved all 12 packages with **delta 0 MB** and never recreated `SourcePackages`, and a full Release build did not either
- [x] `install.sh` builds `tenon-cli` in the shared scratch, not a private one — `swift build --configuration release --product tenon-cli` green in 55.9 s
- [x] `dev.sh` and `install.sh` both prune regenerable junk before building — the six-line call is in both; the prune itself is verified directly, the wrapper lines only by `bash -n` (see Not verified)
- [x] Prune skips itself while another build holds the tree (several agents share this checkout) — run against a live `xcodebuild`: printed `Skipping build-cache prune: another build is running`, exit 0, deleted nothing
- [x] `install.sh` drops build intermediates after the app is installed — the step freed **479 M** of `Intermediates.noindex` with `Build/Products/{Debug,Release}` intact
- [x] `swift build` still green after a prune; `xcodebuild` does not re-checkout the deps — 13.9 s incremental, exit 0

## Measured after
```
.build                     3.8 G   (3.3 G before the extra Release products landed)
  xcode                        1.6 G   Products (Debug+Release) 793 M + ModuleCache
  arm64-apple-macosx           1.3 G   SwiftPM debug + release
  checkouts + repositories     875 M   deps, ONE copy, read by both toolchains
```
A second prune on this tree reports `nothing to prune` — it is idempotent and takes
nothing an incremental build needs.

## Not verified
- **`install.sh` end to end.** It runs `xcodegen generate`, which would overwrite
  `project.pbxproj` while @fd5aa92f (T-022) holds it dirty. Both builds it performs were
  verified individually instead.
- **The Xcode path is red in this tree, from before this task.** A Release
  `xcodebuild` reached `ShellTitleBar.swift:120: cannot find 'LauncherMenu' in scope`
  because `LauncherMenu.swift` is untracked and absent from `project.pbxproj` — T-022's
  pending `xcodegen generate`. The same sources build clean under SwiftPM, which reads
  `Sources/` directly, so the failure is file membership, not build configuration.
- **`dev.sh` end to end.** It launches a window; the prune it calls is verified on its
  own and `swift run tenon` is unchanged.
