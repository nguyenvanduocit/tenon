# Ground-truth verification of the shared tree

> Read-only PM verification pass. Nothing was edited, staged, committed or fixed.
> This file is the only write.

- **When**: 2026-07-30 ~20:02–20:06 +07
- **Where**: `/Users/firegroup/projects/tenon`, branch `main`, HEAD `3c06770` ("Merge process resource monitor design")
- **Tree**: 49 modified + 20 untracked + 1 deleted (`git status --porcelain` = 71 entries). Nothing committed since `3c06770`.
- **Deleted file**: `poc/Tests/TenonCoreTests/WorkspaceDiffReuseTests.swift` (consistent with T-024, which deleted `showDiff`).

---

## Build

`cd poc && swift build`

**Exit code: 0.** `Build complete! (43.25s)`. Re-run for a clean exit code (no pipe): `BUILD_EXIT=0`.

**Zero errors.** Three warnings, all verbatim:

```
warning: 'poc': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
    /Users/firegroup/projects/tenon/poc/Sources/TenonApp/Assets.xcassets
warning: (arm64)  could not find symbol '_ImFontConfig_ImFontConfig' in object file '.../GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a(ext.o)'
warning: (arm64)  could not find symbol '_ImGuiStyle_ImGuiStyle'  in object file '.../GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a(ext.o)'
```

Notes:
- The `Assets.xcassets` warning is **new and attributable**: `poc/Sources/TenonApp/Assets.xcassets/` is untracked (arrived with the app-icon work alongside `poc/scripts/generate-app-icon.sh`). SwiftPM does not process asset catalogs; the directory needs an explicit `.copy`/`.process` resource rule or an `exclude` in `Package.swift`, otherwise every `swift build` from now on prints it.
- The two `Im*` linker warnings are pre-existing vendored-GhosttyKit noise (dear-imgui symbols absent from the prebuilt static lib), unrelated to any in-flight task.

---

## Test totals

`cd poc && swift test`

```
Test Suite 'TenonPackageTests.xctest' failed at 2026-07-30 20:05:01.598.
	 Executed 595 tests, with 3 failures (0 unexpected) in 42.392 (42.496) seconds
Test Suite 'All tests' failed at 2026-07-30 20:05:01.598.
	 Executed 595 tests, with 3 failures (0 unexpected) in 42.392 (42.501) seconds
```

**Exit code: 1.**

### THE REAL NUMBER IS 595 / 3 — every board claim is wrong

| Task | Claimed total | Verdict |
|---|---|---|
| T-021 | 499, then 526 | wrong — stale |
| T-022 | 562 | wrong — stale |
| T-024 | 574 | wrong — stale |
| T-025 | 583 | wrong — stale |
| **Measured now** | **595 / 3 failures** | **ground truth** |

The board is wrong, but *not* because anyone lied. Each number is a truthful snapshot taken at that task's own moment, written into a document that is read as if it described the present. They form a monotonically increasing series (499 → 526 → 562 → 574 → 583 → 595) that exactly tracks tests being added by successive tasks. **The failure is the format, not the arithmetic**: a bare total with no HEAD/timestamp anchor is unfalsifiable the moment the next task lands. Recommend future entries record `<total>/<failures> @ <HEAD>+<dirty-file-count> <time>` or drop the total entirely.

The one thing every task agreed on is **correct and I independently confirm it: the same 3 tests, and only those 3, are red.** No task introduced a new failure. The mutual blame in the board is misdirected — see Ownership.

### Suites with failures

```
Test Suite 'AppStatePathsTests' failed  — Executed 7 tests, with 2 failures (0 unexpected) in 6.664s
Test Suite 'BundledPluginConsentTests' failed — Executed 6 tests, with 1 failure (0 unexpected) in 6.927s
```

Trailer worth knowing: the run ends with `✔ Test run with 0 tests in 0 suites passed` — that is the **swift-testing** framework reporting an empty run. The entire 595 are XCTest. Nothing is hiding in swift-testing.

---

## Failures table

| # | Suite | Method | File:line | Assertion (verbatim) |
|---|---|---|---|---|
| 1 | `TenonAppStateTests.AppStatePathsTests` | `testEnvironmentOverrideIsUntrustedForCopiedBundledPluginID` | `poc/Tests/TenonAppStateTests/AppStatePathsTests.swift:84` | `XCTAssertEqual failed: ("["process.exec.v1"]") is not equal to ("[]")` |
| 2 | `TenonAppStateTests.AppStatePathsTests` | `testUnknownTrustFlagValueLeavesOverrideUntrusted` | `poc/Tests/TenonAppStateTests/AppStatePathsTests.swift:110` | `XCTAssertEqual failed: ("["process.exec.v1"]") is not equal to ("[]")` |
| 3 | `TenonCoreTests.BundledPluginConsentTests` | `testPluginHostDefaultsToUntrustedInventory` | `poc/Tests/TenonCoreTests/BundledPluginConsentTests.swift:81` | `XCTAssertTrue failed - omitting inventory provenance must never seed standing consent` |

All three say the same thing in three places: **standing consent is being granted where the tests require it to be withheld.**

---

## Ownership

Grep of `.kanban/tasks/` + `.kanban/board.md` for the failing test file names:

- `.kanban/tasks/T-021-standing-consent-for-bundled-plugins.md:101` — `poc/Tests/TenonCoreTests/BundledPluginConsentTests.swift — NEW`. **T-021 (session `c7da3ffe`) authored the file and owns the feature.**
- `AppStatePathsTests.swift` is named in no task's claim list. It is owned by the same feature (`grantsStandingConsent` provenance), so it belongs to T-021 by subject matter.
- T-022, T-024, T-025 and T-027 each disclaim these 3 reds and attribute them to T-021.

**That attribution is CORRECT, and I verified it independently of anyone's say-so:**

1. Both failing test files are **tracked and clean** — `git status --porcelain` on them returns empty. No live agent has touched them.
2. Both were added in commit **`de0de44`** ("Ship the bundled plugins and the tests that hold the boundary") — `git log --diff-filter=A`.
3. The product code that decides their outcome is either untouched or irrelevant:
   - `poc/Sources/TenonApp/AppStatePaths.swift` — **clean**, last modified in `8620bc3`, which is *older* than `de0de44`.
   - `poc/Sources/TenonApp/TenonApp.swift` — **clean**.
   - `poc/Sources/TenonCore/PluginHost.swift` — dirty, but the entire working-tree diff is 3 insertions / 1 deletion adding T-022's `launcher: Bool` to `PluginIntentPresentation`. Nothing consent-related.
4. `git show HEAD:poc/Sources/TenonCore/PluginHost.swift` already has `authorization: PluginHostAuthorization = .bundledInventory` at line 429, and `git show HEAD:poc/Sources/TenonApp/AppStatePaths.swift` contains no trust concept at all.

**Conclusion: these 3 tests were committed RED at `de0de44` and have been red ever since.** They are not caused by any of the five in-flight tasks, and reverting all uncommitted work would not fix them. T-022's board claim that it "reproduced them on a scratch copy with every line of mine reverted" is consistent with what I measured.

---

## Verdict per failure: REAL DEFECT ×3 (no stale assertions)

### #3 — `testPluginHostDefaultsToUntrustedInventory` → **REAL DEFECT**

The product code contradicts *its own documented contract*, and the test agrees with the doc.

- `poc/Sources/TenonCore/PluginHost.swift:183-187` — the struct's own doc comment and init default:
  ```swift
  /// Standing consent defaults to `false` while `.bundledInventory` is `true`: a caller
  /// that forgets to decide gets prompts, never silent authority.
  public init(
      approvedOpenIntentIDs: @escaping OpenIntentApprovals,
      grantsStandingConsent: @escaping StandingConsentDecision = { _, _ in false }
  )
  ```
- `poc/Sources/TenonCore/PluginHost.swift:430` — the convenience init defeats it:
  ```swift
  authorization: PluginHostAuthorization = .bundledInventory,
  ```
  and `.bundledInventory` is `grantsStandingConsent: { _, _ in true }` (`PluginHost.swift:175-178`).

So "a caller that forgets to decide" gets **full silent standing authority** — the precise opposite of the stated design. It is a fail-**open** default on a security gate, which violates CLAUDE.md invariant 5 (*fail-closed checks*) and the comment at `PluginHost.swift:171-174`: *"A user-installed plugin directory must never be authorized through this value."*

The test encodes the intended rule. The code is wrong. **Fix the code, not the test.**

### #1 and #2 — `AppStatePathsTests` provenance → **REAL DEFECT (unimplemented feature)**

These two tests specify inventory-trust provenance:
- an inventory selected via `TENON_PLUGINS_DIR` is **not** bundled → no standing consent;
- unless the developer opts in with `TENON_TRUST_PLUGIN_INVENTORY` set to exactly `"1"` (`"true"` must not count).

**The feature does not exist.** Evidence:
- `poc/Sources/TenonApp/AppStatePaths.swift` is 91 lines and has **no trust field**. `AppStatePaths` carries only `pluginInventoryRoot` and `stateRoot` (`:14-16`).
- `rg TENON_TRUST_PLUGIN_INVENTORY Sources/ Tests/` hits **only the two tests** (`AppStatePathsTests.swift:93,105`). No source file ever reads it.
- `AppStatePaths.resolve` (`:43-51`) will point `pluginInventoryRoot` at **any** directory named by `TENON_PLUGINS_DIR`.
- `poc/Sources/TenonApp/TenonApp.swift:135` — `let pluginsRoot = paths.pluginInventoryRoot`
- `poc/Sources/TenonApp/TenonApp.swift:189` — `authorization: .bundledInventory,` **unconditionally**.

So today, `TENON_PLUGINS_DIR=/anywhere` makes an arbitrary user directory fully trusted as if it shipped in the app bundle. That is exactly what `PluginHost.swift:171-174` forbids in writing.

### ⚠️ The two sibling tests that PASS are passing vacuously — do not read them as assurance

In the same file, `testBundleFallbackTrustsPluginInventory` (`:71`, expects `["process.exec.v1"]`) and `testEnvironmentOverrideWithExactTrustFlagIsDeveloperTrusted` (`:98`, expects `["process.exec.v1"]`) both **pass** — but only because the code grants consent to *everything*. They would pass identically with the trust logic ripped out, which is in fact the current state.

Net: of the 4 provenance tests, 2 fail and 2 give false green. **The trust axis has zero real coverage.** Anyone reading "4 provenance tests, 2 passing" as partial safety is being misled.

---

## Recommended minimal fixes — NOT APPLIED

### Fix A — one line, closes failure #3

`poc/Sources/TenonCore/PluginHost.swift:430`

```diff
-        authorization: PluginHostAuthorization = .bundledInventory,
+        authorization: PluginHostAuthorization = PluginHostAuthorization(
+            approvedOpenIntentIDs: { _, _ in [] }
+        ),
```

(The struct's own init default supplies `grantsStandingConsent: { _, _ in false }`, so this is the untrusted value.)

**Blast radius — measured, small.** Only six `PluginHost(` construction sites exist in `Tests/`:
- `PluginHostTests.swift:1137` (the shared `makeHost` helper) passes `.bundledInventory` explicitly at `:1141` → unaffected;
- `BundledPluginConsentTests.swift:237` passes explicitly → unaffected; `:245` is the nil-authorization branch, i.e. the failing test itself → fixed;
- `PluginHostStateRootTests.swift:42` uses the default → `rg 'consent|Consent|process.exec'` on that file returns **nothing**, so it is consent-agnostic;
- `TenonAppTests/SpatialCanvasInteractionTests.swift:760` and `TenonAppTests/PluginWebSurfacePoolTests.swift:170` use the default but are **Xcode-only** (see next section).

Production is unaffected: `TenonApp.swift:189` names `.bundledInventory` explicitly.

### Fix B — three edits, closes failures #1 and #2. **This is not a one-liner; do not let the table above imply it is.**

The tests demand a capability that was never built, so the fix adds it:

1. `poc/Sources/TenonApp/AppStatePaths.swift` — add `let trustsPluginInventory: Bool` to the struct (`:14-16`).
2. `poc/Sources/TenonApp/AppStatePaths.swift:42-58,74` — compute it in `resolve`: `true` when the inventory came from `bundledPluginsRoot` (no env override), or when `environment["TENON_TRUST_PLUGIN_INVENTORY"] == "1"` (exact string — `"true"` must yield `false`, per `:105`); `false` otherwise. Pass it into the `AppStatePaths(...)` initializer.
3. `poc/Sources/TenonApp/TenonApp.swift:189` —
   ```swift
   authorization: paths.trustsPluginInventory
       ? .bundledInventory
       : PluginHostAuthorization(approvedOpenIntentIDs: { _, _ in [] }),
   ```

Smallest honest description: **one new stored property, one branch in `resolve`, one ternary at the call site.**

⚠️ Fix B changes developer ergonomics: after it lands, `TENON_PLUGINS_DIR=/path swift run tenon` will prompt for `.policy` intents unless `TENON_TRUST_PLUGIN_INVENTORY=1` is also set. That is the tests' intent, and `poc/README.md` / `CLAUDE.md` document `TENON_PLUGINS_DIR` without it — whoever takes this should update that doc line in the same slice.

**Sequencing**: Fix A and Fix B are independent and can land separately. Fix A is safe to land alone right now; it touches one line in a file whose only dirty hunk (T-022's `launcher` flag) is ~1870 lines away. Fix B touches `AppStatePaths.swift` + `TenonApp.swift`, both currently **clean and unclaimed** — but T-027 (`restore-workspace-catalog-on-launch`, Todo) names `AppStatePaths.swift` in its plan, so Fix B should land before T-027 starts or be coordinated with it.

---

## Test-target reachability

**T-024's claim is VERIFIED TRUE.** `poc/Tests/TenonAppTests/` is not a SwiftPM target and never runs under `swift test`.

`poc/Package.swift:105-110` declares exactly three test targets:

```swift
.testTarget(name: "TenonIntentCoreTests", dependencies: ["TenonIntentCore"]),
.testTarget(name: "TenonCoreTests", dependencies: ["TenonIntentCore", "TenonCore"]),
.testTarget(name: "TenonAppStateTests", dependencies: ["TenonApp"]),
```

`poc/Tests/` holds **six** directories. The mapping:

| Directory | `swift test` | Xcode (`project.yml`) |
|---|---|---|
| `TenonIntentCoreTests` | ✅ runs | ✅ `project.yml:150,231` |
| `TenonCoreTests` | ✅ runs | ✅ `project.yml:133,232` |
| `TenonAppStateTests` | ✅ runs | ❌ **absent entirely** |
| `TenonAppTests` | ❌ never | ✅ `project.yml:166,233` |
| `TenonIntegrationTests` | ❌ never | ✅ `project.yml:182,234` |
| `TenonUITests` | ❌ never | ✅ `project.yml:204,235` |

Empirical confirmation from the run log: `grep -c SpatialCanvasGestureTests` (in `TenonAppStateTests`) = **6 hits**; `grep -c SpatialCanvasInteractionTests` (in `TenonAppTests`) = **0 hits**.

### The bigger finding T-024 did not report: the two build systems are DISJOINT

It is not merely that `TenonAppTests` is Xcode-only. `TenonAppStateTests` is the mirror image — it exists in `Package.swift` but has **no target definition and no scheme entry in `project.yml` at all**. So:

- `swift test` runs `TenonAppStateTests` but skips `TenonAppTests`, `TenonIntegrationTests`, `TenonUITests`.
- Xcode runs those three but skips `TenonAppStateTests`.

**There is no single command that runs the whole test suite.** Any "N/M" figure on the board is a partial count by construction, including the 595 in this report — which excludes `TenonAppTests`, `TenonIntegrationTests` and `TenonUITests` entirely.

### Immediate consequence for work in flight

`poc/Tests/TenonAppTests/SpatialCanvasInteractionTests.swift` is **modified** in the working tree and is claimed by **T-026** (still in `Doing`; its claim list names the file). Those edits are **not exercised by `swift test`** — they compile only under `xcodebuild`, which nobody has run this session (T-022 and T-023 both record that `xcodegen generate` was deliberately skipped because `project.pbxproj` is held dirty). T-026 must not cite a `swift test` total as evidence for its `SpatialCanvasInteractionTests.swift` changes.

T-025 handled this correctly and is worth copying: it put its `press(region:clickCount:)` assertions in `Tests/TenonAppStateTests/SpatialCanvasGestureTests.swift` (reachable, 6 log hits) rather than in the Xcode-only file.

Recommended follow-up (not applied, out of scope here): add `TenonAppStateTests` to `project.yml` and file a task to reconcile the two target lists, so one command can be the evidence bar CLAUDE.md says it is.

---

## Summary for the board

1. **595 tests, 3 failures, `swift test` exit 1; `swift build` exit 0.** Every board total (499/526/562/574/583) is stale.
2. **The 3 reds are pre-existing at HEAD `3c06770`** — committed red in `de0de44`. No in-flight task caused them; reverting all uncommitted work would not fix them.
3. **All 3 are REAL DEFECTS, not stale assertions.** The product grants standing plugin consent where the tests require it withheld, contradicting its own doc comments at `PluginHost.swift:171-174` and `:183-184`.
4. **2 sibling provenance tests pass vacuously** — the trust axis has no real coverage.
5. **No single command runs the whole suite**; `swift test` and Xcode cover disjoint target sets.
