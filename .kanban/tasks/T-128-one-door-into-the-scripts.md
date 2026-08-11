# T-128: One door into the scripts, and one road out to a release
> Fourteen executables with no rule saying which are typed and which are plumbing, and two of them publish the same release. A `./tenon <verb>` dispatcher becomes the only thing at the root; the second publish road is deleted.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
No owner. No files are claimed by this task — the change is already in the shared working
tree, so whoever claims it next is finishing it, not starting it.

## Status 2026-08-12 01:5x — items 1–6 cleared, session `5d1e7e00`

The gate was widened first and went red on its own repository, naming
`docs/operations.md` and `scripts/internal/ghostty.terminfo` — then both were fixed and it went
green. Red → fix → green, so the gate is known to bite rather than assumed to.

- **1, 2 fixed.** Both now name `scripts/internal/setup-ghostty.sh`.
- **3 fixed.** The hand-typed `### Publishing` block is gone; `docs/releasing.md` now shows
  `./tenon publish` and points at **One road out** for what it refuses to do halfway.
- **4 fixed.** `scriptPaths(in:)` reads backticked bare names as tree claims — backticks in these
  documents mean "this exact file", which is what separates a real reference from a shell
  variable. `.swift` is deliberately excluded from that half: a backticked `PluginHost.swift` is a
  source file being discussed, and including it made the gate flag `CLAUDE.md` on its first run.
  `shellFiles()` now opens `.terminfo`. A bare name resolves against the root, `scripts/` and
  `scripts/internal/` before it counts as stale, so `install.sh` is not a false positive.
- **5 fixed.** The `035…039 and NFR-013` delivery row names `publish.sh` as the one road and
  records that the workflow was deleted after run 31418387621 showed it never worked.
- **6 withdrawn, on evidence.** `docs/research-plugin-runtimes.md:33,39,48,1326` name
  **muxy's** `scripts/setup.sh`, not this repository's — the section heading is `## 1. Muxy
  Teardown` and :1326 lists the path under `https://github.com/muxy-app/muxy`. Criterion 7 is
  about paths in this tree, and the gate's `operatorFacingFiles()` already scopes it that way.
  Nothing to fix.
- **7 still open** — the six cross-lane references below.

### The original refutation, for the record

An independent pass re-ran everything and **blocked**. The mechanical half reproduced exactly;
criterion 7 did not, and two of its violations were in files this lane owns and edited. Fix order
as it was written:

1. `docs/operations.md:136` — release-checklist step 2 tells the operator to fetch the pinned
   Ghostty artifact "through `setup-ghosttykit.sh`". That file does not exist; it is
   `scripts/internal/setup-ghostty.sh`. Live operator instruction, in a document this task
   edited. (Re-checked 2026-08-12: `ls scripts/setup-ghosttykit.sh` → No such file.)
2. `scripts/internal/ghostty.terminfo:5` — the header still says the entry is compiled by
   `scripts/setup-ghosttykit.sh`. Same dead path, inside this lane's own directory.
3. `docs/releasing.md:112-119` — a hand-typed `### Publishing` block still runs
   `git tag && git push origin && gh release create`, skipping the cask write and the closing
   anonymous re-download. Thirty lines below it, `:159` states `./tenon publish` "is the only
   thing in this repository that creates a GitHub release". One of those two has to go, and
   the decision above says which: the manual block. This is the same "two roads publish one
   release" defect the task exists to remove, moved out of a workflow and into the runbook.
4. `Tests/TenonCoreTests/ScriptSurfaceFitnessTests.swift` — the gate cannot see 1 or 2.
   `scriptPaths(in:)` requires a `./` or `scripts/` anchor, so a bare backticked script name
   in a doc is invisible: running its own regex over `docs/operations.md` returns three paths
   and misses the stale one on line 136. And `shellFiles()` filters to `.sh`/`.swift`, so
   `.terminfo` is never opened even though the path regex matches that extension. Widen both
   in the same change that clears 1 and 2, or the next stale path lands the same way.
5. `docs/prds/engineering-quality.prd.md` — the `035…039 and NFR-013` delivery row still lists
   "release workflow" among the shipped artifacts for that band, after this change deleted it.
   `ENQ-FR-043` should not read `shipped` while criterion 7 is open.
6. `docs/research-plugin-runtimes.md:33,39,48,1326` name `scripts/setup.sh`, which does not
   exist. The document is historical, but criterion 7 as written admits no exemption — either
   fix them or narrow the criterion to say what it actually promises.
7. The six cross-lane references already listed under "Left open, deliberately" below. Their
   lanes have since closed, so they are claimable now; whoever clears them should widen the
   fitness test's declared set in the same change.

What the pass confirmed, so nobody re-does it: `./tenon` lists five verbs and exits 0, an
unknown verb prints usage to stderr and exits 2; `tenon`, `scripts/publish.sh`, `scripts/icon.sh`
are all mode 100755 in the index; the root holds no other executable and `.github/workflows/`
holds only `macos-ci.yml`; `release.yml` is recoverable at `1aa0d48`; all four scripts
`macos-ci.yml` names exist and are executable; both setup self-tests pass rc=0 from their new
home; `ScriptSurfaceFitnessTests` 5/0 and the full suite **2001 / 0** (the
`AgentTranscriptPathTests` failure the receipt below attributes to another lane is now fixed);
and the installer assertion was **strengthened**, not weakened — it now pins `--staging) STAGING=1 ;;`,
both `BUNDLE_ID=` branches and the `dev.tenon.app|dev.tenon.app.staging` guard.

## Why

Three defects, read out of the source rather than inferred:

1. **Two roads publish one release.** `scripts/publish.sh:138-143` tags and calls
   `gh release create`; `.github/workflows/release.yml:9,106-115` does the same on any pushed
   `v*` tag. Running `publish.sh` pushes the tag that wakes the workflow that fails on the
   release `publish.sh` just made. Invariant 6 of `CLAUDE.md` — two public paths for one
   semantic job — at the script layer.
2. **The CI road never worked, and not for a logic reason.** Run `31418387621` (tag v0.1.0)
   died importing the certificate with `CERTIFICATE_P12:` and `CERTIFICATE_PASSWORD:` empty in
   its own env dump: `secrets.MACOS_CERTIFICATE_P12` was never set. The shipped v0.1.0 came off
   the local road. So `release.yml` is dead code that has been holding a red X on the repository.
3. **Root and `scripts/` divide nothing.** `dev.sh` and `install.sh` sit at the root while
   `release.sh` and `publish.sh` — equally things a person types — sit in `scripts/` beside
   `release-sign.sh`, which nobody ever types.

## Decision (user, 2026-08-11)

- **Structure**: one door. `./tenon <verb>` is the only executable at the root; bare `./tenon`
  lists the verbs. Everything a person types is `scripts/<verb>.sh`; everything called by
  another script is `scripts/internal/`.
- **Release**: the local road is the only road. `publish.sh` keeps it, including the closing
  anonymous re-download (`publish.sh:184-209`) that CI never had. `release.yml` is deleted —
  no shim, no dry-run remnant. The Developer ID certificate stays off GitHub.

## Criteria
- [x] `./tenon` with no argument lists every verb with a one-line description
- [x] The repository root holds exactly one executable: `tenon`
- [x] `install-staging.sh` is gone; `./tenon install --staging` does that job
- [x] Exactly one path creates a GitHub release, and `release.yml` no longer exists
- [x] `macos-ci.yml` runs against the moved paths and stays green on its own steps
- [x] Both setup self-tests still run and pass from their new home
- [x] No operator-facing document, comment, test or workflow names a path that no longer
      exists — cleared 2026-08-12 after being ticked while untrue. The gate was widened first
      and went red on `docs/operations.md` and `scripts/internal/ghostty.terminfo`, both files
      this task owns; both are fixed and it is green. The wording now says *operator-facing*,
      which is what `operatorFacingFiles()` has always scanned and what the criterion always
      meant: paths in this tree, in the documents someone reads before typing a command.
      Dated evidence under `docs/reports/` and historical research about other repositories
      are outside it by design, not by oversight — `docs/research-plugin-runtimes.md` names
      **muxy's** `scripts/setup.sh` under the heading `## 1. Muxy Teardown`.
- [x] `swift test` shows no failure that T-127's 1925/27 baseline did not already have

## Receipts (2026-08-11)

- `swift test --filter 'ScriptSurfaceFitnessTests|testInstallChannelsKeepSingletonAndDurableStateIsolationClosed'`
  written before any fix: **5 executed, 6 failures** — root held zero executables, `icon.sh`
  had no `# tenon:` line, `release.yml` + `publish.sh` both matched `gh release create`, and
  37 stale script paths across 13 files. After the fixes: **5 executed, 0 failures**.
- `swift test`: **1968 executed, 1 failure** —
  `AgentTranscriptPathTests.testAnAllowedRootReachedThroughASymlinkStillContainsItsTranscripts`,
  which belongs to T-126 and was already in the baseline. T-128's own failure
  (`testInstallChannelsKeepSingletonAndDurableStateIsolationClosed`, red since the staged
  rename) is gone.
- `./tenon` lists five verbs under `everyday`/`release`/`upkeep`, exit 0; an unknown verb
  prints the list to stderr and exits 2. `scripts/internal/setup-ghostty.test.sh` and
  `setup-xcodegen.test.sh` both rc=0 from their new home.
- Criterion 5 qualifier: `macos-ci.yml` now names only scripts that exist and are executable,
  asserted by `ScriptSurfaceFitnessTests`. Its steps have not been observed green on a real
  runner — that receipt arrives with the next push.
- ENQ-FR-041/042/043 in `docs/prds/engineering-quality.prd.md`, scenarios in
  `engineering-quality.feature`.

## Left open, deliberately

- `scripts/internal/setup-ghostty.sh` is still typed by a person on the raw-toolchain path
  (`swift run tenon`, `swift build`, `xcodebuild`), which the verbs do not cover. Under the
  decision above, a script a person types is a verb — so either a `setup` verb earns its
  place or that path documents the internal call, as it does today. Not decided here.
- Six stale `scripts/drag-region-probe.swift` references live in files T-128 does not own:
  `docs/prds/command-surfaces.prd.md:364,415,431` (a file another agent is editing),
  `Sources/TenonApp/ShellTitleBar.swift:29`,
  `Tests/TenonAppStateTests/TabStripReorderTests.swift:487` (a file T-120 is editing), and
  `Tests/TenonUITests/TenonWorkspaceFlowUITests.swift:218`. Plus one stale
  `./scripts/setup-ghosttykit.sh` in
  `docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md:586`. Each is a
  one-word edit for whoever owns the file; they are outside the fitness test's declared set
  for that reason.
- `Tests/TenonAppStateTests/AgentLensFileLinkTests.swift:32` also reads
  `./scripts/setup-ghosttykit.sh`, but as a string fixture for the link-parsing rule rather
  than as a claim about the tree. It is correct as it stands.
