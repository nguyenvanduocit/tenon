# T-074: Two suites are timing-flaky under load

> Both wait on wall time rather than on a fact, so they pass alone and fail when the
> machine is busy. Two of them is a pattern worth fixing once.

## The second one

`AgentFleetIntegrationTests.testOneEventHandlerFansOutTwoSupervisedAgentsAndPublishesTheAggregate`
fails roughly one run in three. The tell is the duration: **7.0s on the failing run against
0.95s on the passing ones** — it is hitting a wait bound, not disagreeing about behaviour.
Same fix as below: give it a fact to wait on, or an injected clock.

## The first one


> `testABurstOfWritesCoalescesIntoOneReparse` expected 1 reparse and got 2 in a full run,
> then passed 3/3 in isolation seconds later. It asserts a debounce window against real
> time, so under full-suite load the burst outlives the window and stops coalescing.

- **priority**: low
- **effort**: S

## Evidence

Full suite at 16:0x: 1188 tests, this one failure. Immediately re-run alone three times:
green, green, green. Nothing in that run touched the kanban plugin — the concurrent work
was in the intent kernel and the app shell.

## Why it matters more than one red

A test that fails only under load is worse than no test: it trains everyone to read a red
suite as noise, which is exactly how a real regression gets waved through. This one already
cost a full-suite re-run to attribute.

## Criteria

- [ ] The coalescing window is driven by an injected clock rather than wall time, so the
      assertion is about the rule and not about how busy the machine was.
- [ ] The test fails when coalescing is genuinely removed — prove it with a mutation.
- [ ] 20 consecutive full-suite runs with no flake, or the test is rewritten to assert
      something deterministic.
