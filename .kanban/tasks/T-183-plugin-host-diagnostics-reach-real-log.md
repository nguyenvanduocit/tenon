# T-183: Plugin-host diagnostics reach a real system log
> Operator follow-up on T-182: none of `PluginHost.appendLog`'s lines — including the mailbox
> overflow that caused T-182 — were visible anywhere except an in-memory array nothing reads.
- **priority**: medium
- **effort**: XS

## Owner / files (agent lock)
Released — DONE 2026-08-18 17:4x, this session (`tenon-33`). File was free (no active claim).

## What was missing
`PluginRuntimeConfiguration.log` (both `BundledPluginRuntime.swift` and the JS `PluginRuntime.swift`
funnel through it) wired to `PluginHost.appendLog` (`PluginHost.swift:1130`), which only appended to
`log: [String]` — capped, in-memory, never read by any UI, never persisted. Diagnosing T-182's
"compiled callback mailbox exceeded 256 entries" required a purpose-built test harness with its own
log capture; on a real install that exact line would have been unrecoverable evidence.

## Fix
`appendLog` now also logs through a `Logger(subsystem: "dev.tenon.app", category: "plugin-host")`
declared in `PluginHost.swift` itself — `TenonCore` cannot import `TenonApp.TenonLog` (wrong
direction), so this is its own logger under the same subsystem, same as every other `TenonLog`
category, filterable the same way (`log show --predicate 'subsystem == "dev.tenon.app"'`). Every
`appendLog` call site (mailbox overflow, a failed compiled handler, a rejected watcher/timer, a
plugin load failure, hot-reload activity) is covered by construction — one sink, not one call site
found and fixed at a time. `line` is logged `privacy: .public` (matches the established pattern in
`AgentTimelineSynthesis.swift`/`CLISocketServer.swift`/`DiagnosticsCommands.swift`) since these are
internal diagnostic strings, never user secrets.

## Scope note
Deliberately did not add severity levels (`.error` vs `.notice` vs `.fault`) per call site — every
line lands at `.notice` uniformly. `appendLog`'s ~25 call sites mix routine activity ("host:
reloaded X") with genuine failures; splitting those honestly needs reading each site's intent, not
a guess, and blanket visibility already closes the gap that mattered today (nothing was visible at
all). A follow-up could thread severity through if a specific failure needs faster triage than
`log show` scrolling provides.

## Criteria
- [x] Every `PluginHost.appendLog` line reaches a queryable system log, not just the in-memory array
- [x] Both plugin runtimes covered (they share the one `configuration.log` sink)
- [x] `swift build` clean, full `swift test` **2373 / 0**
