# T-043: Three test directories sit outside the evidence bar, and one has rotted
> `Tests/` holds six directories; `Package.swift` declares three test targets. The
> difference is not documented anywhere, and the excluded `TenonAppTests` no longer compiles.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 247281cf — **DONE 03:3x, ALL LOCKS RELEASED.** Every file below is free again; the
list stays as the record of what this task changed.

Files changed:
- `Tests/TenonAppTests/{PluginWebSurfacePoolTests,SidebarResizeTests,SpatialCanvasInteractionTests}.swift`
- `Package.swift` (one `.testTarget`, if the files are repaired rather than retired)
- `docs/tdd.md` and/or `CLAUDE.md` ▸ Verification (whichever states which runners cover what)

## Evidence (2026-07-31, at `17bf0a6`)

`CLAUDE.md` ▸ Verification says *"`swift build` + `swift test` are the evidence bar"*. They
do not reach everything under `Tests/`:

| directory | in `Package.swift` | in `Tenon.xcodeproj` |
|---|---|---|
| `TenonIntentCoreTests` | yes | yes |
| `TenonCoreTests` | yes | yes |
| `TenonAppStateTests` | yes | **no** |
| `TenonAppTests` | **no** | yes |
| `TenonIntegrationTests` | **no** | yes |
| `TenonUITests` | **no** | yes |

Two disjoint runners, neither covering everything. `TenonUITests` explains itself (its
README: XCUITest needs a GUI session) and `TenonIntegrationTests` is a live-Ghostty smoke,
so both are defensibly outside a headless run. `TenonAppTests` is not: its four files are
ordinary headless app-layer tests, and nothing records why they are excluded.

**They no longer compile.** Declaring the target and running `swift test` produced hard
errors, not warnings — API drift plus Swift 6 isolation:

- `SpatialCanvasInteractionTests.swift`: `missing arguments for parameters 'webPool',
  'editorStates', 'pluginSnapshots', 'pluginViewSections', 'webSurfaceTitles',
  'paneAttention'` — the call site is several signatures behind — plus ~12
  `main actor-isolated ... from a nonisolated context` errors (`:757`–`:788`).
- `PluginWebSurfacePoolTests.swift`: `missing argument for parameter 'stateRoot'` (`:171`),
  `cannot infer type of closure parameter` (`:176`), and a `weak var never mutated`
  warning that warnings-as-errors turns into a build failure (`:104`).

Since these errors are signature mismatches, they fail under *any* runner: the Xcode
project cannot have been building them either. They are dead files that read as coverage.

## Already fixed, so this task does not have to
`TerminalIntentProviderTests.swift` was the one file in that directory that still
compiled, and it was the only coverage of `TerminalIntentProvider` anywhere. It has been
moved to `TenonAppStateTests/`, where `swift test` runs it, and extended with the
`command-finished` cases (see T-009). Three files remain in `TenonAppTests/`.

## Criteria
- [x] Decide per file — **all four repaired, none deleted**; every rule they name is now
      asserted by a running test (breakdown under "What each file needed")
- [x] Whatever survives is reached by `swift test`; `Tests/TenonAppTests/` no longer
      exists — the directory is removed and the name appears in no manifest
- [x] Each repaired test is mutation-proven — table below. Two of my own replacements were
      **tautological on the first attempt** and are recorded as such
- [x] The Xcode project and `Package.swift` agree: `project.yml`'s target was renamed to
      `TenonAppStateTests` over `Tests/TenonAppStateTests`, the scheme's test list follows,
      and `xcodegen generate` (2.45.4, matching `minimumXcodeGenVersion`) regenerated
      `Tenon.xcodeproj`. `xcodebuild -list` reports the eight expected targets
- [x] `docs/tdd.md` gains a "Which runner covers which directory" table — five directories,
      three headless in both runners, `TenonIntegrationTests` and `TenonUITests` Xcode-only
      with the reason stated
- [x] `swift build` exit 0 + full `swift test` **792 / 0** (from 750 at session start).
      The only warnings are the two prebuilt ImGui **linker** warnings T-020 measured and
      deliberately left outside warnings-as-errors

## What each file needed

| File | Why it failed | Fix |
|---|---|---|
| `TerminalIntentProviderTests` | nothing — it compiled | relocated (T-009); gained 3 `command-finished` cases |
| `SidebarResizeTests` | nothing — `SidebarResize`'s API never drifted | relocated unchanged |
| `PluginWebSurfacePoolTests` | `PluginHost` gained `stateRoot:`; manifest schema gained a required `intents` key; three `weak var` never mutated (warnings-as-errors); two tests held the `WKWebView` alive and then asserted it was gone | added `stateRoot:` + `.bundledInventory`, added `"intents"`, `weak let` (SE-0481, Swift 6.2), and replaced first-attempt assertions with bounded waits |
| `SpatialCanvasInteractionTests` | `configure` gained six parameters; `PluginHost` gained `stateRoot:`; ~12 Swift 6 actor-isolation errors; **5 assertions encoded a design the code never had** | `@MainActor` on the class, the six arguments, and the design conflict resolved below |

**The design conflict.** `testCanvasAndSlotRenderEdgeToEdgeWithoutDecorativeBorders`
asserted that cards fill the canvas with no border and no corner radius. The code insets
every card by half a gutter (`SpatialCanvasView.swift:693-696`) and the comment there gives
a *functional* reason, not a decorative one: the gap is a dead zone that keeps adjacent
resize edges from overlapping. Both the test and that comment date from the initial commit
`012a6a5` — they never agreed, and nothing ever ran the test to say so. The code carries the
reasoning, so the code wins: the test is now
`testCanvasIsUndecoratedAndTheCardCarriesTheChromeInsideAHalfGutter`, plus a new
`testNeighbouringCardsAreSeparatedByAFullGutterSoResizeEdgesNeverOverlap` that asserts the
functional claim the comment makes.

## Mutation proofs

Each mutation applied to the shipped source, suite run, source restored byte-identical
(`git status` clean on `Sources/` afterwards).

| # | Mutation | Named assertion that went red |
|---|---|---|
| M4 | `TenonTheme.slotGutter` 8 → 0 | `testCanvasIsUndecoratedAndTheCardCarriesTheChromeInsideAHalfGutter`, `testNeighbouringCardsAreSeparatedByAFullGutterSoResizeEdgesNeverOverlap` |
| M5 | resting `layer?.borderWidth` 1 → 0 (`SpatialCanvasView.swift:1199`) | `testInvalidLayoutPreviewKeepsItsErrorBorder` |
| M6 | `retainOnly` disposes nothing | `testRetainOnlyReleasesClosedPaneSurface`, `testLifecycleCallbackRetiresSurfacesWithoutASpatialCanvas` |
| M7 | per-installation persistent store → `WKWebsiteDataStore.nonPersistent()` | `testSurfaceUsesInstallationPersistentWebsiteDataStore` |
| M8 | `SidebarResize.resolve` never collapses | `testDraggingWellBelowTheIconsCollapses`, `testMinimumWidthStaysOpenButAnythingNarrowerCollapses` |

**M4 and M5 passed on the first attempt, and that was the finding.** The replacement
assertions derived their expected values from `TenonTheme`, so moving the constant moved
the expectation with it and the test could not fail. They now state the rule independently
— the card sits strictly inside the canvas, neighbours have a gap greater than zero, a card
has a corner radius greater than zero — with the exact theme-derived geometry kept
afterwards as documentation rather than as the whole assertion.

**Not a product bug.** The two `InvalidTransition` failures and the surviving `WKWebView`
looked like a renderer leak. They were not: the pool releases synchronously and the view
dies a turn or two later, so the original tests asserted before the run loop caught up —
and one of them held the view alive itself. M6 confirms the direction: with disposal
removed, the bounded wait times out and reports the leak it exists to catch.
