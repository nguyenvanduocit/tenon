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

**Refuted — see "Root cause" below.** The suspicion that fitted those facts at the time:
event *delivery* needs a running
`NSApplication`, and a `swift test` process on a runner has no `NSApp` pumping events, so
whether an injected press is dispatched before the run-loop deadline is a race that a
loaded machine loses. A desktop with a logged-in session wins it every time, which is why
this has never failed here.

## Why not just re-run

A test that passes on the second attempt still spends the first attempt's signal. The suite
is the evidence bar for every concurrent agent in this tree; one that is red at random
teaches everyone to re-run rather than to read, and the next real regression arrives
looking exactly like this.

## Root cause — measured, and it is not a race

`NSWindow.sendEvent` dispatches a mouse event only for a window the window server carries on
its **on-screen list**. A machine running the suite with no display session never puts one
there, so the press is built, resolves, and hit-tests correctly, and `mouseDown:` is simply
never called. Nothing about it is timing, load, or `NSApp` not pumping — the account in the
section above was wrong, and a rerun could not have fixed it.

Measured on a window held off that list, with the shipped bar mounted:

| Question | Answer |
|---|---|
| `window.windowNumber` | assigned, non-zero |
| `event.window` | resolves to the window |
| `frameView.hitTest(press)` | `TabStripSurface.SurfaceView` |
| `SurfaceView.mouseUp` ran | **0 times** |
| the strip's own closures, called directly | select the tab correctly |

That is exactly why 2f33fc6's two diagnostics stayed silent on CI: both of them hold in this
state. A window ordered front but truly offscreen at `(-8000, -8000)` delivers fine, so
"offscreen" was never the variable — being off the on-screen list is. On a desktop a titled
window's origin is constrained back onto the screen anyway, which is why this machine has
never failed.

**Reproduced rather than inferred:** holding every window in the file off the on-screen list
turns exactly the four CI tests red, with the same assertions and the same lines as run
`31480549761`, and leaves the other twelve green — including the hit-test test, the drag
region test, and the absence test.

## Fix

`send` routes a press the way the window routes one: the frame view hit-tests it, the view
that answers receives `mouseDown`, and that view keeps the drags and the release the way
AppKit's mouse capture hands them over. Both halves stay the shipped ones — the shipped view
tree answers the hit test and the shipped event overrides do the work — so what these tests
ask about the title-bar band is unchanged, and a press that resolves to nothing now fails
saying so instead of as "the tab order did not change".

## Criteria

- [x] The reason those four fail on a runner is established, not assumed — established by
      local reproduction of the runner's condition and a delivery measurement, which is
      stronger than the instrumented CI run this asked for
- [x] They assert the same behaviour without depending on an unowned race — the behaviour
      asserted is identical; the dependency removed is the window server's on-screen list,
      which is a property of the display and not of the product
- [ ] `TabStripReorderTests` passes on ten consecutive CI runs of an unchanged tree —
      **owed**; this session cannot run CI, and the change is not committed
- [x] The drag-region rule stays covered — the region test and
      `scripts/internal/drag-region-probe.swift` are untouched, and the region test is one
      of the twelve that stayed green under the reproduced condition

## Evidence

`swift test --filter TabStripReorderTests` → **17 / 0**, and **17 / 0** again with every
window in the file held off the on-screen list.
`testAPressLandsOnTheChipInAWindowTheServerNeverPutOnScreen` keeps the runner's condition
asserted on every machine, so putting delivery back through `NSWindow.sendEvent` goes red
here instead of only on CI.

`docs/prds/command-surfaces.prd.md` carries the decision row and the receipt;
`docs/prds/engineering-quality.prd.md` carries the `ENQ-FR-017` receipt.

## Owner / files (agent lock)

Released — done.
