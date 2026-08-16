# T-170: A fitness test pins behaviour, not the text the behaviour is written in
> `InteractionBoundaryFitnessTests` keeps the boundary rules it was built for and stops
> holding 398 source-code literals hostage to every refactor.
- **priority**: medium
- **effort**: M

## Why

Measured before the first edit, over the whole tree (2292 tests, 0 failures, 136.8 s):

- The suite has essentially no classic dead weight to delete: **0** tautological tests,
  **4** zero-assertion tests (all four legitimate — `XCTestExpectation` with `isInverted`
  carries the assertion), **16** near-duplicate shapes (all parameterised cases with
  different inputs), **3** `XCTSkip`s (all conditional on a real PTY or `script(1)`).
  Test-to-source ratio is 84 123 / 98 614 = **0.85**.
- The 245 tests of ≤4 lines are not filler. Each pins one distinct rule —
  `testAggregateOfNothingReadableIsUnavailableNotZero`,
  `testAggregateRSSOverflowIsUnavailableRatherThanWrapping`,
  `testContiguousRunOutscoresScatteredMatch`. Merging them would cost fault localisation
  and save no wall-clock: they run at ~0 ms.
- The real maintenance cost sits in one file. `InteractionBoundaryFitnessTests.swift` is
  **1913 lines / 23 tests** pinning **398 source-code string literals** —
  `"return $0.target < $1.target"`, `"case .production: \"Tenon\""`,
  `"guard isSocketNode(at: path) else { return false }"`. Ratio of `assertContains`
  (pins that source text is PRESENT) to `assertDirect` (pins that a cross-owner entry is
  ABSENT) is **74 : 6**. Text matching cannot catch a wrong behaviour, but it does turn
  every pure rename or reformat red.

T-020 built this file for one job, recorded in its criteria: *"Internal app code has no
generic app intent principal or dispatcher shortcut"* — an **absence** rule, unreachable by
calling code. Later tasks borrowed the file as a place to pin their implementations. That
borrowing is what this task removes; the absence rules stay.

## Criteria
- [x] Every anchor that pins how a line is written, rather than what the system does, is gone.
      **1913 → 918 lines, 23 → 20 tests, 398 → 129 string literals, `assertContains` 74 → 0.**
      The 129 that remain are forbidden-token lists — the thing a sweep must name to look
      for it — not transcripts of shipped code.
- [x] Every absence rule T-020 built survives: no generic app principal, no dispatcher
      shortcut outside the two adapters, no removed public API returning, no sender chosen
      at a call site. Also kept, each for a stated reason: the drag-region properties
      (`scripts/internal/drag-region-probe.swift` is the only other route and it needs a
      screen), the two orderings that guard a race, the single-owner sweeps, and Settings
      staying preference-only.
- [x] Behaviour that only a deleted anchor covered gains a real test that runs the code,
      or is shown to be already covered elsewhere — named test, not assumed:
      - install channels → `CLISocketServerTests.testInstalledBundleIdentifiersResolveTheClosedInstanceChannels`,
        `testProductionAndStagingCanBothOwnTheirSingletonChannels`,
        `testSocketSymlinkCannotRedirectActivationAcrossChannels`
      - public plugin surface → `PluginBuiltinsTests.testRuntimeExportsOnlyTheClassifiedPublicSurface`
        (drives a real generation and pins all 31 member paths)
      - Agent Lens RESOURCE/STREAM bounds → `AgentLensTests.testNativeProtocolBoundedWriterTerminatesOnConsumerOverflow`,
        `testTranscriptTailerReadsExistingLineAndCancellationFinishes`
- [x] `swift test` green, and the retained rules proven load-bearing by mutation rather
      than assumed. **Full suite `Executed 2289 tests, with 0 failures`, exit 0** (2292
      before; the 3 fewer are the merged cases). Scope 20 / 0.

## Mutation receipts — the rules were watched to fail

Every mutation was taken with `cp` backups and restored byte-identical (`cmp -s` clean, and
`git status` shows neither `Sources/` file), because this tree is shared with four other
sessions.

| Mutation | Result |
|---|---|
| `CoreIntentName.allCases.count` expectation 51 → 52 | RED: `("51") is not equal to ("52")` — the count is read from the enum, not restated |
| `AppInstanceChannel.stagingBundleIdentifier` → `dev.tenon.app.preview` | RED twice, naming the new value: the installer no longer ships what the app declares |
| `PaletteIntentInvoker.prepare(` renamed in `LauncherMenu.swift` | Build error at `LauncherMenu.swift:346` — the string the ordering test reads is live code |
| Sweep list widened to forbid `AppIntentRuntime` on Agent Lens files | RED at `AgentLensSession.swift:461`, which is a lawful `responder:` principal — so the sweep reports precisely, and the widening was reverted rather than shipped |

The last row is worth keeping: it was my error, and the test caught it in one run. A rule
that fails only when it should is the property this file is supposed to have.

## What the measurements refuse

The request was to cut small and unimportant tests. The data says those are not the cost:
`ProcessTelemetryTests.testAggregateOfNothingReadableIsUnavailableNotZero` is three lines,
runs in ~0 ms, and separates "unreadable" from zero — the exact silent-wrong-number class.
Merging tests like it would buy nothing and lose the fault localisation that makes a red
suite readable. The 398 pinned literals were the cost, and they are gone.

Untouched and worth a task of its own: the suite takes **140 s**, while `CLAUDE.md` still
advertises "~1s". The time is spread, not concentrated — the slowest single test is 2.45 s
and the top 20 together are ~30 s — so it is a real piece of work rather than a quick win.

## Owner / files (agent lock)

**RELEASED 2026-08-16 08:0x by session `2700a0db`** — all four criteria met, full suite
green at 2289 / 0. No file is claimed by this task now.

Held while the work ran, and released: `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`,
`docs/design-agent-lens.md` (one paragraph corrected to name the tests that actually run the
stream), this task file, and its board line. `Sources/TenonApp/AppInstanceChannel.swift` and
`Sources/TenonApp/LauncherMenu.swift` were each mutated for one test run and restored
byte-identical; neither appears in `git status`. Nothing held by T-144, T-141, T-140, or
T-135 was written.
