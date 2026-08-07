# T-093: Every request and generation ends

> The liveness half of the 2026-08-07 Swift architecture audit: five paths that accept work
> without a bound on when that work is finished with the resources it holds.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)

Session `784166de` — batch A of `docs/reports/2026-08-07-swift-architecture-audit.html`:

`Sources/TenonApp/CLISocketServer.swift`,
`Sources/TenonIntentCore/CLIProtocol.swift`,
`Sources/TenonApp/TenonApp.swift`,
`Sources/TenonApp/BuiltInSlotViews.swift`,
`Sources/TenonCore/NetworkIntentProvider.swift`,
`Sources/TenonCore/PluginRuntime.swift`,
`Sources/TenonCore/PluginHost.swift`,
`Tests/TenonAppStateTests/CLISocketServerTests.swift`,
`Tests/TenonCoreTests/PluginRuntimeShutdownTests.swift`,
`Tests/TenonCoreTests/PluginEventDeliveryTests.swift`.

## Criteria

- [x] A CLI request holds its concurrency permit from accept to terminal close, settles exactly
      once, and a flood of valid slow requests is refused with a `busy` failure instead of
      growing descriptors, tasks or the main queue.
- [x] Exactly one main window. `New Window` cannot reparent the single Ghostty surface out of
      the first window.
- [x] A plugin republishing a text field while the person is typing in it leaves the draft
      alone, and an external value applies after blur.
- [x] DNS resolution is cancellable and deadline-bounded; the transport deadline is recomputed
      from the time left after resolve.
- [x] `PluginRuntime.shutdown(timeout:)` bounds the whole state machine, not only the executor
      stop, so a synchronous runaway plugin cannot hold quit or reload past the deadline.
- [x] `tenon.events.emit` returns after a bounded enqueue; a slow observer cannot block the
      publisher, another observer, or shutdown.
