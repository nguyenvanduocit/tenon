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

## Fixed (session 784166de, 2026-08-08)

`PluginLogQueue` — ordered, bounded, and outside the actor:

- **Ordered.** One queue with one consumer, so lines arrive in the order they were written.
  `PluginLogOrderingTests` proves it, and the mutation proves the test: restoring the
  per-line fan-out scrambles 200 lines into `0, 1, 3, 4, …, 2, 20, 22, 18, …` and loses the
  last-line guarantee.
- **Bounded, and loud about it.** A full queue counts what it refused and says
  `N log line(s) were dropped` once, when it drains — never silence.
- **Outside the actor.** Two designs were tried and rejected on evidence before this one: a
  chained task per line released recursively and took the stack with it (SIGSEGV), and a drain
  that hopped back onto the actor trapped on the pinned executor during shutdown (SIGTRAP).
  The consumer never re-enters the runtime.
- Shutdown drains the queue with the storage chain, because the last thing a failing
  generation says is usually the most useful thing it said.

## It also made the suite flaky

`PaneHeaderSchemaTests.testAHeaderFullOfMalformedItemsNamesTheFirstFewAndCountsTheRest` failed
once in a full run and passed in the next full run and in three isolated runs. It asserts the
*order* of two `tenon.log` lines, and every line goes through `hostTasks.launch`, which neither
orders nor guarantees delivery. So the same defect that can drop a line can also reorder two —
the flake is a symptom of this card, not a separate one, and fixing the ledger fixes both.
