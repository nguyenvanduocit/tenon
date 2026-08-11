# T-120: Four tab tests that only hold on a desktop

> `TabStripReorderTests` has four tests that inject `NSEvent`s and pump the run loop. They
> failed on one CI run and passed on a rerun of the same commit. On this machine they have
> never failed. That is a flake in the shared suite, and it hides real regressions.

- **priority**: high
- **effort**: M
- **prd**: TENON-PRD-015 (ENQ-FR-017 flake control, ENQ-FR-007 adapter receipts)

## Measured

Run `31446806778`, first attempt — four failures, all in the same suite:

| Test | What it asserted |
|---|---|
| `testARealPressAndDragOnTheStripMovesTheTabItStartedOn` | drag to the end lands the tab last |
| `testAShortDragPastOneNeighbourSwapsThatPair` | drag past a midpoint swaps the pair |
| `testAPressThatDoesNotTravelSelectsTheChipUnderIt` | a click selects its tab |
| `testAPressOnTheCloseControlClosesThatTab` | a click on ✕ closes that tab |

Each failed by the tab order or selection being **unchanged** — the events did not reach
the view. A rerun of the same commit passed all four.

What narrows it: **12 of the 16 tests in that suite passed on the failing run**, including
`testAChipCentreHitTestsToTheStripSurfaceInsideARealTitleBarWindow`, which mounts a real
title-bar window and hit-tests a chip centre. So the window exists, layout happens, and
hit-testing answers correctly on the runner. The four that fail are exactly the four that
call `send(.leftMouseDown/.leftMouseDragged/.leftMouseUp, in: window)` and then
`RunLoop.main.run(until:)`.

The suspicion that fits every one of those facts: event *delivery* needs a running
`NSApplication`, and a `swift test` process on a runner has no `NSApp` pumping events, so
whether an injected press is dispatched before the run-loop deadline is a race that a
loaded machine loses. A desktop with a logged-in session wins it every time, which is why
this has never failed here.

## Why not just re-run

A test that passes on the second attempt still spends the first attempt's signal. The suite
is the evidence bar for every concurrent agent in this tree; one that is red at random
teaches everyone to re-run rather than to read, and the next real regression arrives
looking exactly like this.

## Criteria

- [ ] The reason those four fail on a runner is established, not assumed — an
      instrumented CI run that prints whether `NSApp` is running and whether the press was
      dispatched, rather than a guess confirmed by a green rerun
- [ ] They assert the same behaviour without depending on an unowned race: either drive the
      responder path deterministically, or run them in a lane that has a GUI session, or
      make them wait on the state they expect instead of a fixed deadline
- [ ] `TabStripReorderTests` passes on ten consecutive CI runs of an unchanged tree
- [ ] The drag-region rule stays covered — `scripts/drag-region-probe.swift` and the
      hit-test tests are what stopped T-101 from shipping a fourth wrong fix

## Owner / files (agent lock)

Unclaimed.
