# T-158: A compiled view's click reaches its program

> Route view select/submit/open/close through `BundledPluginProgram` so a bundled-swift
> plugin that publishes views stops rendering UI whose every click is silently dropped —
> the first of the three runtime capabilities the migration map says every remaining port
> waits on.

- **priority**: high
- **effort**: M
- **PRDs**: `TENON-PRD-010` (plugin runtime), `TENON-PRD-011` (interaction boundaries)

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

- [ ] `BundledPluginProgram` carries optional per-view callbacks; existing programs compile
      unchanged and declare none.
- [ ] `invokeViewSelect`/`invokeViewSubmit` answer handler presence synchronously and run
      the handler through the same bounded mailbox as events, in enqueue order.
- [ ] `openViewInstance`/`closeViewInstance` track instances (idempotent, instanced-only),
      publish them in the snapshot, prune the closed instance's published view body, and
      deliver `open`/`close` to the program.
- [ ] A throwing view callback fails the plugin generation, not the host.
- [ ] T-156's migration guard stays green: shipped compiled plugins still publish no views
      and report select/submit unhandled.
- [ ] Focused tests + full `swift test` pass; `xcodegen generate` is deterministic.

## Owner / files (agent lock)

Session: claude `4844889b` 2026-08-14 (operator-directed, uncommitted shared tree)

- `Sources/TenonBundledPlugins/BundledPluginRuntime.swift`
- `Sources/TenonBundledPlugins/BundledPluginProgram.swift` (new)
- `Tests/TenonCoreTests/BundledPluginViewRoutingTests.swift` (new)
- `Tenon.xcodeproj/project.pbxproj` (regenerated via `xcodegen generate` only)
