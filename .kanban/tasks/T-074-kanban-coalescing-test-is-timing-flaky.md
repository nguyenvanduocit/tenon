# T-074: Two suites are timing-flaky under load

> Both waited on wall time rather than on a fact, so they passed alone and failed when the
> machine was busy. Two of them was a pattern, and it is fixed once.

## What each one was actually measuring

**`KanbanPluginTests.testABurstOfWritesCoalescesIntoOneReparse`** slept 600 ms after a burst
of eight refresh requests and asserted the board was read exactly once. Two different things
under load broke that number, and neither is a behaviour change: a slow turn leaves the
surviving debounce timer unfired, and a late FSEvent from the fixture's *own* board write
arrives after `resetReadCount` and lands as a second read. It reported 2 where it wanted 1.

**`AgentFleetIntegrationTests.testOneEventHandler…`** and its twin in
`FleetReviewExampleTests` waited `attempts: 1600` × 5 ms. That reads as eight seconds and is
not: it is 1600 turns, and how much wall time they buy depends on how fast the turns run. The
tell was the duration — 7.0 s on the failing run against 0.95 s on the passing ones, i.e. it
hit the bound rather than disagreeing about behaviour.

## What they assert now

The kanban test asks the generation how many timers it holds
(`PluginRuntime.resourceCounts.timers`) immediately after the burst, and requires the delta
to be **one**. That is the coalescing rule stated outright, and it needs no clock at all: the
burst is a single synchronous evaluation, so no timer can fire inside it. A second assertion
waits on the *fact* that a read happened (`>= 1`, because a stray filesystem event may
legitimately add another) instead of on a duration. Runtime fell from 600 ms of sleeping to
0.43 s of work.

The two fleet waits became deadline-based rather than turn-based. The deadline is far past any
real run and a passing run never spends it — its only job is to fail a hung test instead of
hanging the suite behind it.

## Receipts

- **Mutation.** Deleting `tenon.timers.cancel(st.debounceHandle)` from
  `plugins/kanban/main.js:667` turns the kanban test red with the loop's real shape:
  `("8") is not equal to ("1") - eight refresh requests armed 8 timers`. Restored and
  re-verified green.
- **20 consecutive runs** of all three tests: 0 failures. Run 8 took 6.3 s against a ~2.8 s
  median — a genuinely slow run, of exactly the kind that used to land near the old 8 s bound,
  and it passed.

## Criteria

- [x] The coalescing window is driven by an injected clock rather than wall time, so the
      assertion is about the rule and not about how busy the machine was.
      *Answered by removing the clock from the assertion entirely rather than injecting one:
      the live timer count is the rule, and it is readable synchronously. An injected clock
      would have been a second mechanism for a question that needs none.*
- [x] The test fails when coalescing is genuinely removed — prove it with a mutation.
- [x] 20 consecutive full-suite runs with no flake, or the test is rewritten to assert
      something deterministic.
      *Both branches: the kanban assertion is now deterministic, and all three tests were run
      20 consecutive times green.*
