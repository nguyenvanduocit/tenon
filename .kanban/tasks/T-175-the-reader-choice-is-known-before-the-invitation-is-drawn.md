# T-175: The reader choice is known before the invitation is drawn
> Opening Timeline draws its controls, then re-flows them a moment later when the reader
> picker arrives — because the scan that answers "which CLIs does this machine have" is
> started by the view that needs the answer, and costs 2.107 s where the question costs 1.20 ms.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)

**RELEASED 2026-08-17 by session `d653bc85`.** No file below is held any longer.
`AgentLensView.swift` was held by T-141 throughout and was never touched.

## What was reported

From a live pane: bấm sang Timeline thì nó hiện "default gì đó", rồi một lúc sau mới hiện
"Claude Code" hoặc "Codex".

## What it actually is, measured before the first edit

The first frame of `AgentSessionTimelineView` draws with `availableReaders == []`
(`AgentLensSession.swift:285`), and `readerPicker` is conditional on `count > 1`
(`AgentTimelineView.swift:130`). So the leftmost visible control is `modelPicker` showing
`AgentReadingModel.providerDefault` → `"Default model"`. When the scan answers, the reader
picker is **prepended**, pushing the whole row right.

The scan is started by `.task` on the view (`AgentTimelineView.swift:54`) and runs
`AgentLaunchDetector.scan()`, which reads and parses shell history to guess preferred
arguments — a result `installedProviders` discards outright
(`AgentTimelineSynthesis.swift:701` keeps only each suggestion's agent). First estimated with a
replica of `readTail` on this machine (`.bash_history` 4.8 MB, `fish_history` 895 KB,
`.zsh_history` 17 KB; 512 KB tail per file) — the shipped types were then measured directly and
came in far worse, see **What shipped**:

| Work | Cost | Used |
|---|---|---|
| read tails, 1.07 MB | 3.9 ms | discarded |
| split + scan 23,265 lines | **94.2 ms** | discarded |
| probe 64 PATH dirs + 8 bin dirs for two binaries | **0.5 ms** | the answer |

94.2 ms is a floor: the probe used `contains("claude")` while `AgentLaunchHistory.invocation`
tokenizes arguments per line. `installed(provider:)` (`AgentTimelineSynthesis.swift:596-603`)
pays the same cost on the run path and discards the same field, so every "Read this session"
also carries it before the CLI is launched.

Nothing caches: the account switch at `AgentLensView.swift:526-534` destroys and rebuilds the
view, so `.task` re-runs the whole scan on every visit to Timeline, in every pane.

## Criteria

- [x] `installedProviders` and `installed(provider:)` ask `AgentExecutableLocator`, not
      `AgentLaunchDetector`; no shell history is read to answer which binaries exist
- [x] The reader scan runs once per pane and is not repeated by re-opening Timeline
- [x] The scan is started by the pane, not by the view that shows its result, so the reader
      picker is present on the invitation's first frame
- [x] `AgentLaunchDetector` keeps its history parsing for the launcher surfaces that use the
      arguments it guesses
- [x] Red first, then green; `AgentReadingOptionsTests` + `AgentSessionTimelineTests` green
- [x] `AL-FR-055` written, Gherkin scenario tagged, receipt appended to the PRD

## What shipped

Measured on the shipped types before the first edit, mean of five after a warm run:

| Call | Cost |
|---|---|
| `AgentLaunchDetector.scan()` | **2.107 s** |
| `AgentExecutableLocator.scan()` | **1.20 ms** |
| `installedProviders()` after the change | **1.20 ms** |

1751×. The replica in the section above measured 98 ms because it matched history lines with
`contains`; the real `AgentLaunchHistory.invocation(in:for:)` tokenizes arguments on every one
of 23,265 lines. `installed(provider:)` paid the same 2.1 s on the **run** path, before the CLI
that takes the reading was launched.

Three changes:

1. `installedProviders(locator:)` and `installed(provider:locator:)` ask `AgentExecutableLocator`
   — which is what `SettingsView` and `CompanionStructuredOutputRunner` already asked.
2. `loadAvailableReaders()` keeps a found answer, and re-asks only an empty one.
3. `start()` asks, so the answer is on hand for the invitation's first frame.

## Mutation receipts

One at a time, file restored byte-identical between each.

| Mutation | Test that caught it |
|---|---|
| `guard availableReaders.isEmpty` removed | `testTheReaderScanIsAskedOncePerPane` — `("3") is not equal to ("1")` |
| `askWhichReadersExist()` removed from `start()` | `testThePaneAsksWhichReadersExistBeforeTimelineIsEverOpened` — `("[]")` against both CLIs |
| `installedProviders` returning `allCases` | `testAReaderWithNoBinaryIsNotOffered` |

`AgentReadingOptionsTests` 13 → **18 / 0**, `AgentSessionTimelineTests` **33 / 0**, full suite
**2289 / 0** in 138 s.

## Owed

- The jump is removed by a head start, not a reserved slot: a pane opened and clicked within the
  same millisecond would still draw the row once without the picker.
- No photograph. The Timeline snapshot writer mounts a finished reading, not an invitation
  mid-scan, so there is no visual receipt of the jump before or after.
- `ContentView.swift:161` and `AgentIntentProvider.swift:53` still pay the 2.107 s detector.
  They use the arguments it guesses, so it is correct there — but that the launcher surface
  spends two seconds on it is untested and belongs to another PRD.
