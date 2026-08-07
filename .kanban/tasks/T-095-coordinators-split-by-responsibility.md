# T-095: Coordinators split by responsibility

> The structural half of the 2026-08-07 Swift architecture audit: four files that each owned
> several concerns at once, decomposed without changing behaviour, plus the domain ontology
> that says which concern is which.

- **priority**: medium
- **effort**: L

## Owner / files (agent lock)

Session `784166de` — RELEASED. Landed in:
`Sources/TenonApp/Canvas/*` (new folder, from `SpatialCanvasView.swift`),
`Sources/TenonCore/{PluginHost,PluginHostModels,PluginHostPersistence,PluginHostPolicy}.swift`,
`Sources/TenonIntentCore/{IntentIdempotencyTypes,IntentIdempotencyStore,IntentIdempotencySQLite}.swift`,
`Sources/TenonIntentCore/IntentDispatcher.swift`, `docs/domains.md`, `CLAUDE.md`,
`Package.swift`, and every source file under `Sources/` (one `@domain:` line each).

## What moved

| Before | After |
| --- | --- |
| `SpatialCanvasView.swift` 2,537 | `Canvas/` — interaction 409, representable 82, NSView 1,139, overlays 76, pane host 24, card 859 |
| `PluginHost.swift` 3,177 | coordinator 2,638 + models 332 + persistence 24 + policy 208 |
| `IntentIdempotency.swift` 2,406 | types 327 + store 899 + SQLite 1,201 |
| `IntentDispatcher.send` 753 | 404, three typed phases + a named invocation context |

## Criteria

- [x] Every split preserves behaviour: no test changed except the fitness tests that name a
      file path, and those name the new one.
- [x] Every source file carries a `@domain:` tag and `untaggedFileBudget` is 0; seven domains
      were declared for the concerns that had none.
- [x] Every `// MARK:` in a file over 400 lines carries its own domain.
- [x] The package publishes two executables and no library, which is the API-surface decision
      the audit asked for.
- [x] `IntentDispatcher.send` carries typed phase values: `RequestAuthorizationPhase`
      (validate, authorize, prepare idempotency), `CallerConsentPhase` (confirmation) and
      `ProviderAdmissionPhase` (lease + global budget). 753 → 467 lines, 143 kernel tests green
      at each step.
- [x] The event routing rules — the `terminal.read` gate, the publish declaration, the observer
      set — are `PluginEventRouting`, a pure unit with its own tests, instead of three inline
      copies inside `PluginHost`.
- [x] The mailbox operation is `makeProviderOperation(_:)` over an `InvocationContext`. The
      closure runs detached and therefore captures rather than reads; naming the set it captures
      turned ten loose locals into one value, which is the typed phase context the audit asked
      for rather than the ten-parameter factory it warned about. 753 → 404 lines.
- [x] `PluginContributionProjection` is what a live generation puts on screen — status items,
      view sections, intent presentations, palette sections, key-binding and command indexes —
      as one pure, total transformation with its own tests. `publish()` now decides the order
      and publishes the result. `PluginIntentPresentation.projected(for:pluginID:)` moved onto
      the type it produces.
