# T-080: A plugin's log line can vanish without a trace
> `tenon.log` delivers each line by launching a host task. When that 512-entry ledger is
> full the line is discarded and nobody is told — not the plugin, not the host, not the log.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
Unclaimed.

## What happens

`PluginRuntime.emitLog` (`poc/Sources/TenonCore/PluginRuntime.swift:1911`) does:

```swift
func emitLog(_ message: String) {
    let prefix = "[\(manifest.name)] "
    let sink = configuration.log
    _ = hostTasks.launch { … }
```

The `_ =` discards the launch result. `hostTasks` is bounded at 512, so under saturation the
line is dropped silently. This affects **every** `tenon.log` line from every plugin, not one
feature's diagnostics.

Found while landing T-076 step 4, whose header decoder reports malformed items through exactly
this channel — a fail-soft contract whose explanation can disappear precisely when a plugin is
misbehaving enough to produce many of them. T-076 bounded its own side (a header emits at most
`PluginParsedHeader.maximumDiagnostics` = 16 lines per `views.set`) and deliberately did not
touch `emitLog`.

## Why it was not fixed in T-076
Making `emitLog` block would put the runtime actor at deadlock risk, and the change is a
runtime-wide backpressure decision rather than a header one. It wants its own reasoning and its
own test.

## Reproduction
Saturate the host-task ledger with a slow log sink and emit past it. The probe run during T-076
measured the drop at the 512/1024 boundary.

## Criteria
- [ ] A failing test shows a `tenon.log` line lost while the host-task ledger is saturated
- [ ] The chosen policy is stated in the code: drop with a counted summary, a bounded log-only
      queue, or backpressure — whichever, silence is not one of them
- [ ] No path can deadlock the runtime actor; the actor-reentrancy argument is written down
- [ ] Full suite green
