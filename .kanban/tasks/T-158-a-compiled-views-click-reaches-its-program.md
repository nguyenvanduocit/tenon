# T-158: A compiled view's click reaches its program

> Route view select/submit/open/close through `BundledPluginProgram` so a bundled-swift
> plugin that publishes views stops rendering UI whose every click is silently dropped —
> the first of the three runtime capabilities the migration map says every remaining port
> waits on.

- **priority**: high
- **effort**: M
- **PRDs**: `TENON-PRD-010` (plugin runtime), `TENON-PRD-011` (interaction boundaries)
- **DONE 2026-08-14. Operator-directed; a concurrent session committed the shared tree as
  `a6c5f80` mid-verification, which included this task's files at their final content —
  this session itself committed nothing.**

## Decision

The seam extends the same runtime protocol T-155 landed; it authorizes nothing new. A
program declares per-view callbacks (`select`/`submit`/`open`/`close`), keyed by view id,
mirroring the JavaScript bootstrap's per-view handler map (`PluginRuntimeBootstrap.swift:919`):
the `Bool` the host receives from `invokeViewSelect/Submit` means "a handler is registered
for this view id", and the handler itself runs on the plugin's own bounded callback pump —
never awaited by the host, ordered FIFO with event delivery, failing the plugin and not the
host. The actor tracks open view instances so `PluginRuntimeSnapshot.openViewInstances`
stops being hardcoded `[]` — without that, `PluginHost.performViewInstanceReconcile`
(`PluginHost.swift:1816`) re-opens every instanced compiled view on every reconcile.
Dynamic palette providers and view-owned timer/watch/process resources remain the follow-up
T-155 named; this slice does not touch them.

## Criteria

- [x] `BundledPluginProgram` carries optional per-view callbacks; existing programs compile
      unchanged and declare none.
- [x] `invokeViewSelect`/`invokeViewSubmit` answer handler presence synchronously and run
      the handler through the same bounded mailbox as events, in enqueue order.
- [x] `openViewInstance`/`closeViewInstance` track instances (idempotent, instanced-only),
      publish them in the snapshot, prune the closed instance's published view body, and
      deliver `open`/`close` to the program.
- [x] A throwing view callback fails the plugin generation, not the host.
- [x] T-156's migration guard stays green: shipped compiled plugins still publish no views
      and report select/submit unhandled.
- [x] Focused tests + full `swift test` pass; `xcodegen generate` is deterministic.

Verification 2026-08-14: red first at the routing assertions (6 tests, 12 assertion
failures — `handled` false, recorders empty, `openViewInstances` empty), then green;
focused sweep (`BundledPluginViewRoutingTests` + `BundledPluginRuntimeTests` +
`BundledPluginMigrationGuardTests` + `DomainTagFitnessTests`) **22/0**; full suite
**2257/0**; `xcodegen generate` run twice, second run produced no diff. Follow-ups still
open before a view-publishing port: dynamic palette providers, view-owned
timer/watch/process resources, and swapping T-156's views-empty guard for routing coverage
of the first real port. The `plugin-runtime.prd.md` delivery note for `PRT-FR-048`
("native view interaction ports remain follow-up work") can now name this seam — left to
the PRD owner, since this task was scoped to `Sources/TenonBundledPlugins` + tests.
