# T-130: One switch for every permission prompt
> A Permissions page in Settings whose bypass switch answers every confirmation without UI, and a standing consent that survives the app restart that currently erases it.

- **priority**: high
- **effort**: M
- **PRD**: TENON-PRD-004 (settings surface), TENON-PRD-010 (`PRT-FR-021`/`FR-022`/`FR-045`), TENON-PRD-000 (`PDR-FR-020`/`FR-021`)

## Owner / files (agent lock)
**DONE 2026-08-11 17:4x, session `cc5a315a`, LOCK RELEASED.** Files below are free.

- `Sources/TenonCore/AppPreferences.swift`
- `Sources/TenonApp/PluginUIPrompt.swift`
- `Sources/TenonApp/SettingsView.swift`
- `Sources/TenonApp/AppStatePaths.swift`
- `Sources/TenonApp/StandingConsentStore.swift` (new)
- `Sources/TenonApp/AppIntentRuntime.swift`
- `Sources/TenonApp/TenonApp.swift` (wiring only)
- `Sources/TenonIntentCore/IntentPolicy.swift`
- `Sources/TenonIntentCore/IntentKernelComponents.swift`
- `Tests/TenonAppStateTests/PermissionBypassTests.swift` (new)
- `Tests/TenonIntentCoreTests/StandingConsentPersistenceTests.swift` (new)
- `docs/prds/settings.prd.md`, `docs/prds/settings.feature`
- `docs/prds/plugin-runtime.prd.md`, `docs/prds/plugin-runtime.feature`

Disjoint from T-129 (`AgentLensView.swift`), T-124 (palette files), T-120 (`TabStripReorderTests.swift`).

## Why

The prompt is not asking too often; it is *forgetting* every answer. `standingCallerConsents`
and `standingCallerWideConsents` live only in the `PolicyEngine` actor
(`Sources/TenonIntentCore/IntentPolicy.swift:896-897`) and no code writes them anywhere —
so every "Always allow" the operator has ever clicked dies with the process. The CLI caller
id is stable (`cli:local-user`, `AppIntentRuntime.swift:31`), so caller-wide consent would
already cover an agent's whole session if it outlived a relaunch.

`PDR-FR-020`/`PDR-FR-021` and `PRT-FR-045` already require this ("unchanged ordinary
operations MUST NOT repeatedly prompt"), all three `planned/partial`.

## Decision

Product owner chose, 2026-08-11: bypass covers **every** confirmation including `.always`,
and it is **on by default**. The recorded risk they accepted: a user-inventory plugin then
runs its declared `.policy` contracts without anyone being asked, which is the outcome
`PRT-FR-006`/`PRT-FR-022` were written to prevent. Recorded in the PRD decision logs, not
argued again here.

The switch answers the confirmation phase only — `.allowOnce`, so it writes no consent
record and turning it off restores asking with no residue. Declared use, audience,
capability, scope, and provider eligibility still run on every invocation, exactly as they
do behind standing consent (`IntentPolicy.swift:713-717`).

## Criteria
- [x] `AppPreferences.bypassAllPermissionPrompts` defaults to `true` and round-trips through the existing `UserDefaults` blob, absent key included.
- [x] Settings has a Permissions page carrying the switch, its danger stated in the page, not only in its name.
- [x] With the switch on, a `.policy` request and an `.always` request both return `.allowOnce` and `PluginUIState.pending` stays empty.
- [x] With the switch off, the same request is presented and the operator's decision is what returns.
- [x] A standing consent grant is written durably before it is remembered; a writer that throws leaves no consent in memory (fail closed, `PRT-FR-023`).
- [x] Consent restored from disk skips the confirmation authorizer on the next launch.
- [x] Revocation (disable/uninstall/withdrawal) rewrites the durable snapshot, so a disabled plugin does not come back consented.
- [x] `swift test` green; PRD delivery matrices and decision logs updated in this change.

## Evidence

- `swift test --filter PermissionBypassTests` — **10/0**. Mutation: returning `.alwaysAllow`
  instead of `.allowOnce` from `standingPermissionAnswer()` fails 3 of them (recompile
  confirmed in the same run).
- `swift test --filter StandingConsentPersistenceTests` — **7/0**;
  `--filter StandingConsentStoreTests` — **6/0**. Mutation: removing the durable write from
  `grantStandingConsent(contract:caller:)` fails 5 across both files.
- Full suite: **1959 tests, 10 failing cases, none in anything this task touched** —
  `AgentReadingOptionsTests` (7, T-123), `AgentTranscriptPathTests` (1, T-126),
  `InteractionBoundaryFitnessTests` (2: T-124's `PaletteRowChrome`, T-128's moved
  `install.sh`). `DomainTagFitnessTests` went red mid-task because this change pushed
  `AppIntentRuntime.swift` from 393 to 401 lines, crossing the MARK rule's threshold; fixed by
  giving that file its four `@domain:`-tagged sections rather than by trimming lines to duck
  the check.

## Not verified

The Permissions page has no machine-checked appearance. `PaneViewSnapshotWriter` photographs
panes and Settings is a window scene, so nothing here proves its layout — only that the route,
the switch, and the text exist. A person opening ⌘, is still the only reader of that page.
