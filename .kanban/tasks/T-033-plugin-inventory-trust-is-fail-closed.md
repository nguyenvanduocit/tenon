# T-033: Plugin inventory trust is fail-closed
> `PluginHost`'s convenience init defaults to `.bundledInventory`, so a caller that forgets
> to decide gets full silent standing consent — the exact opposite of the contract written
> in its own doc comment. And the `TENON_TRUST_PLUGIN_INVENTORY` provenance the tests
> specify was never implemented, so `TENON_PLUGINS_DIR=/anywhere` trusts an arbitrary user
> directory as if it shipped in the app bundle.

- **priority**: critical
- **effort**: S

## Owner / files (agent lock)
**LANDED 22:34 — LOCKS RELEASED.** session bac7c45f, claimed 22:11. `AppStatePaths.swift`,
`TenonApp.swift`, `PluginHost.swift`, `poc/README.md` and `CLAUDE.md` are free. Not
committed (the coordinator owns commits).

What landed, in the three files:
- `PluginHost.swift:430` — the convenience init now defaults to
  `PluginHostAuthorization(approvedOpenIntentIDs: { _, _ in [] })`, whose own init supplies
  `grantsStandingConsent: { _, _ in false }`. A caller that omits the argument gets prompts.
- `AppStatePaths.swift` — new `let trustsPluginInventory: Bool`, computed in `resolve`:
  `true` on the bundled-root branch, and on the `TENON_PLUGINS_DIR` branch only when
  `environment["TENON_TRUST_PLUGIN_INVENTORY"] == "1"`. **Provenance keys off whether an
  override was supplied at all, not off comparing URLs** —
  `testEnvironmentOverrideIsUntrustedForCopiedBundledPluginID` points `TENON_PLUGINS_DIR`
  at the same path as `bundledPluginsRoot`, so a URL comparison would wrongly trust it.
- `TenonApp.swift:189` — `authorization:` is now a ternary on `paths.trustsPluginInventory`.

Locked files were (exact):
- `poc/Sources/TenonCore/PluginHost.swift` — **line 430 only**
- `poc/Sources/TenonApp/AppStatePaths.swift` — whole file (small)
- `poc/Sources/TenonApp/TenonApp.swift` — **line 189 only**
- `poc/README.md`, `CLAUDE.md` — the `TENON_PLUGINS_DIR` doc line
- `poc/Tests/TenonAppTests/AppStatePathsTests.swift` — read-only (no edits; the tests are
  the spec and stay as written)

T-027 status at claim time: still in **Todo**, unclaimed. `AppStatePaths.swift` mtime
Jul 25 10:45, `TenonApp.swift` mtime Jul 25 21:05, both clean in `git status`, and
`WorkspaceCatalogStore.swift` does not exist. No collision.

Expected files:
- `poc/Sources/TenonCore/PluginHost.swift` — line 430 only (Fix A). T-022 holds one hunk in
  this file (`launcher: Bool` on `PluginIntentPresentation`) ~1870 lines away.
- `poc/Sources/TenonApp/AppStatePaths.swift` — NEW stored property + one branch in `resolve`
- `poc/Sources/TenonApp/TenonApp.swift` — line 189 only, one ternary
- `poc/README.md` + `CLAUDE.md` — the `TENON_PLUGINS_DIR` doc line gains the trust flag

⚠️ **T-027 (`restore-workspace-catalog-on-launch`, in `Doing`) names `AppStatePaths.swift`
and `TenonApp.swift` in its plan.** As of 22:04 it had written neither (its
`WorkspaceCatalogStore.swift` does not exist yet). This task is XS and T-027 is L — claim
these two files on the board immediately, land fast, and release, so T-027 is blocked for
minutes rather than hours.

## Why / evidence
Measured in `.kanban/reports/verify-tree.md` (PM verification pass, 2026-07-30 20:02–20:06).

These are the 3 red tests the board has been passing around for hours, each task
disclaiming them. They are **not** stale assertions and **not** caused by any in-flight
work: both test files are tracked and clean, both were added in commit `de0de44`, and the
source that decides them is clean. **They were committed red and have been red ever since.**

1. `PluginHost.swift:183-187` documents the contract: *"Standing consent defaults to `false`
   while `.bundledInventory` is `true`: a caller that forgets to decide gets prompts, never
   silent authority."* But `PluginHost.swift:430` sets
   `authorization: PluginHostAuthorization = .bundledInventory`, and `.bundledInventory` is
   `grantsStandingConsent: { _, _ in true }` (`:175-178`). Fail-**open** default on a
   security gate — violates CLAUDE.md invariant 5 (fail-closed checks) and the written
   prohibition at `PluginHost.swift:171-174`.
2. `TENON_TRUST_PLUGIN_INVENTORY` appears in `AppStatePathsTests.swift:93,105` and **nowhere
   in `Sources/`**. `AppStatePaths` (91 lines) has no trust field; `resolve` (`:43-51`)
   points `pluginInventoryRoot` at any directory named by `TENON_PLUGINS_DIR`;
   `TenonApp.swift:189` passes `.bundledInventory` unconditionally.
3. **The two sibling provenance tests that pass do so vacuously** —
   `testBundleFallbackTrustsPluginInventory` (`:71`) and
   `testEnvironmentOverrideWithExactTrustFlagIsDeveloperTrusted` (`:98`) both expect
   `["process.exec.v1"]` and would pass identically with the trust logic ripped out, which
   is the current state. Of 4 provenance tests, 2 fail and 2 give false green.

## Criteria
- [x] `PluginHost`'s convenience init defaults to an **untrusted** authorization; a caller
      that omits the argument gets prompts, never standing consent
- [x] `AppStatePaths` carries resolved inventory provenance: bundled root → trusted;
      `TENON_PLUGINS_DIR` override → untrusted, unless `TENON_TRUST_PLUGIN_INVENTORY` is
      exactly `"1"` (`"true"` must NOT count)
- [x] `TenonApp` passes `.bundledInventory` only when provenance says trusted
- [x] All 3 red tests green: `AppStatePathsTests:84`, `AppStatePathsTests:110`,
      `BundledPluginConsentTests:81` — by name,
      `testEnvironmentOverrideIsUntrustedForCopiedBundledPluginID`,
      `testUnknownTrustFlagValueLeavesOverrideUntrusted`,
      `testPluginHostDefaultsToUntrustedInventory`, all `passed` in the final full run
- [x] The two vacuous siblings are made non-vacuous — after the fix they must be able to
      fail. Prove it: break the trust rule locally, watch them go red, restore.
- [x] `poc/README.md` and `CLAUDE.md` document `TENON_TRUST_PLUGIN_INVENTORY` next to
      `TENON_PLUGINS_DIR`, since dev ergonomics change (`TENON_PLUGINS_DIR=/path swift run
      tenon` will now prompt without it)
- [x] `swift build` exit 0 and `swift test` **653 tests / 0 failures** (the 595 in this
      criterion was the baseline at 22:04; five workers landed +58 tests during this slice)

## Vacuity proof — the two false-green siblings can now fail

Each mutation was applied alone, measured with `swift test --filter AppStatePathsTests`,
then reverted. Both kill exactly one test, so each sibling is load-bearing on its **own**
rule rather than on trust logic in general.

| Mutation in `AppStatePaths.resolve` | Result |
|---|---|
| bundled branch → `trustsInventory = false` | `testBundleFallbackTrustsPluginInventory` **FAILED** at `:71` (`"[]"` ≠ `"["process.exec.v1"]"`). Other 6 passed. |
| override branch → `trustsInventory = false` (flag ignored) | `testEnvironmentOverrideWithExactTrustFlagIsDeveloperTrusted` **FAILED** at `:98` (`"[]"` ≠ `"["process.exec.v1"]"`). Other 6 passed. |

`grep -rn MUTATION Sources/` returns nothing; the diff is back to the fixed state.

## Verification

- `swift build` exit 0.
- `swift test` — **653 tests, 0 failures (0 unexpected)**, 39.2 s, on a tree whose
  `Sources/` + `Tests/` mtimes had been stable for 80 s. Log:
  `<session scratchpad>/final2.log`.
- Earlier full runs during this slice were noise from live neighbours, not from this
  change: 631/0 at 22:19; then 647/2; then two runs where the **test target would not
  compile** — first `TenonAppStateTests/LauncherSectionsTests.swift` referencing a
  `LauncherSections` that landed a minute later, then
  `TenonCoreTests/PaneCwdSubscriptionTests.swift` calling `PluginManifest.loadManifest`.
  `swift build` (sources only) was exit 0 throughout. Both cleared on their own once the
  owning workers finished writing; nothing of theirs was touched.
- Launch smoke NOT run: it needs a GUI session and would race five live workers for
  `.build`. The behaviour change it would show — `TENON_PLUGINS_DIR=/path swift run tenon`
  now prompting unless `TENON_TRUST_PLUGIN_INVENTORY=1` — is exactly what
  `AppStatePathsTests` asserts headlessly through a real `AppComposition.start()`.
