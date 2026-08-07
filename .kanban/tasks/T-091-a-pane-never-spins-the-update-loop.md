# T-091: A pane never spins the update loop
> Tenon hung at 100% CPU for hours and grew to 11 GB because a pane's SwiftUI update
> loop never converged. The runloop observer never returned, so the autorelease pool
> never drained. A pane must not be able to do this.

- **priority**: critical
- **effort**: M

## Owner / files (agent lock)

Session `efc4afbd` holds:
`poc/Sources/TenonApp/SpatialCanvasView.swift`,
`poc/Tests/TenonAppStateTests/PaneHostingSizingTests.swift` (new),
`docs/design-pane-hosting.md` (new).

NOT held: `AgentLensView.swift` (dirty from another agent's work — the fix must not
need it; if it turns out to, coordinate first).

## Evidence (from the live hung process, PID 58872, 2026-08-07)

`sample 58872` — main thread, 1938/2001 samples inside ONE runloop observer call:

```
__CFRunLoopDoObservers → NSRunLoop.flushObservers()
  → NSHostingView.beginTransaction() → GraphHost.flushTransactions()   1935
    → AG::Graph::UpdateStack::update()                                 1678
```

The self-feeding cycle, verbatim from the sample:

```
Update.end() → Update.dispatchActions()
  → LazyLayoutViewCache.signalPrefetch()
    → NSHostingView.requestUpdate(after:) → NSHostingView.setNeedsUpdate()
      → -[NSView setNeedsUpdateConstraints:]
```

What is being measured each turn — a ScrollView asked for its IDEAL size, which forces
the lazy content to be measured in full:

```
_ZStackLayout.sizeThatFits → ScrollViewLayoutComputer.Engine.sizeThatFits
  → LazyStack.measureEstimates → ForEachList.applyNodes → ForEachState.item(at:offset:)
    → destroy/initializeWithCopy for AgentTimelineItem   (in Tenon)
```

`AgentTimelineItem` names the list: `AgentLensView.swift:359-382`.

Because the observer never returns, the runloop never drains its autorelease pool.
`heap 58872` / `vmmap 58872`: 77.4M allocations, **physical footprint 11.0 GB, 10.4 GB
swapped out**.

```
812,479 × @autoreleasepool content   = 3.33 GB   ← never drained
157,879 × NSTimer                                ← one per loop turn
157,854 × _NSActivityAssertion                   ← same count, same rhythm
317,428 × NSAutoresizingMaskLayoutConstraint
  2.53M × NSCompositeAppearance / NSSystemAppearance
```

`NSTimer` ≈ `_NSActivityAssertion` ≈ turn count is the arithmetic proof that each turn
leaked exactly one set and no runloop turn ever completed. Two samples a minute apart
were near-identical (`flushObservers` 2001 → 2197), so the state was terminal, not slow.

Also present in the sample, confirming the hosting view was computing content-derived
constraints even though `SpatialCanvasView.swift:1844` sets `contentHost.frame` by hand:

```
NSHostingView.updateConstraints()   NSHostingView.SizeConstraints.update(from:)
NSHostingView.minSize()
```

## What the loop is made of (HIGH — measured, not inferred)

`dispatchActions` is ~100% `LazyLayoutViewCache.signalPrefetch()` in BOTH samples
(55/59 and 72/73). No focus action, no plugin action, no timer action appears. So this
is a **lazy-layout prefetch cycle inside SwiftUI**, and T-088's focus oscillation —
which looks similar from the outside — is NOT this bug.

Reproduction is still open. Five hypotheses were built as a standalone AppKit+SwiftUI
PoC and every one converged (~19-38 body evals over 4s, 0.11s CPU), so every one is
FALSIFIED. Do not spend time re-testing them:

1. Hand-framed `NSHostingView` + `ScrollView { LazyVStack { ForEach } }` + a live
   `ProgressView` spinner — converges.
2. \+ `ScrollViewReader` and a `ZStack` overlay button — converges.
3. \+ a bottom `Color.clear` sentinel whose `onAppear`/`onDisappear` writes `@State`
   (the `AgentLensView.swift:386-397` shape) — converges.
4. SwiftUI → AppKit → SwiftUI nesting: an `NSViewRepresentable` whose `NSView` hand-frames
   a per-pane `NSHostingView`, i.e. the `SpatialCanvasView` → `SpatialCanvasNSView` →
   `contentHost` chain — converges.
5. The representable asked for its IDEAL size (wrapped in a `ScrollView`, and separately
   `.fixedSize`) — converges.

One fact the PoC did establish: `NSHostingView.sizingOptions` is **7**
(`.minSize | .intrinsicContentSize | .maxSize`) as constructed, so each pane's host does
derive size constraints from its content even though `layout()` frames it by hand. That
is a real defect of intent — a pane's size comes from the canvas — but on its own it does
not spin, so it is a cleanup, not the cause.

## What the app actually had open when it hung (evidence for the next attempt)

`log show` puts the hang between **19:11 and 19:18** (workspace state last written 19:11,
only XPC noise after 19:18). `state/workspace/.recent-views.json` at 19:11:

```
terminal · automation · pluginView dev.local.supremor-vault-sync/status · transient ×3
```

So the reproduction path involves the **Automation view** (`AutomationSlotView.swift:800`
and `:895` are both `ScrollView { LazyVStack … }`) and a user plugin's view, opened
together with three transient panes. The plugin itself is cleared: its `render()` is
guarded by `running` and fires once per 5-minute schedule, so it is not an update storm.

Next step is to reproduce against the real app with those views open, and bisect from
there — not to build a sixth synthetic PoC.

PoC lives at `scratchpad/panespin/main.swift` (session efc4afbd) if it helps.


## The receipt is now automatic (session 784166de, 2026-08-08)

The next spin samples itself. `DiagnosticsRuntime` takes `/usr/bin/sample` against its own
pid the first time `RunloopHealth` reports a stall — off the watchdog queue, because the main
thread is what is wedged — and writes it beside the journal:

```
~/Library/Application Support/…/diagnostics/health.jsonl        the stall record
~/Library/Application Support/…/diagnostics/stall-sample.txt    the stack, 5s in
```

Once per stall, and again if a stall ends and recurs (`StallSampleCaptureTests`). This is the
piece the first investigation could not get: its only sample was taken by hand two hours in,
after 10.4 GB had swapped, when every turn was slow for reasons unrelated to the cause.

### The shape the sample names is gone (session 784166de, 2026-08-08)

The stack trace's own first two frames were a `ZStack` asking a `ScrollView` for its ideal
size:

```
_ZStackLayout.sizeThatFits → ScrollViewLayoutComputer.Engine.sizeThatFits
  → LazyStack.measureEstimates → ForEachState.item(at:offset:) → AgentTimelineItem
```

Agent Lens had exactly that shape in two places, and `AgentTimelineItem` names the first:

- `timeline` — `ScrollViewReader { ZStack(.bottomTrailing) { ScrollView { LazyVStack … } ; jump
  button } }`. The jump button is now `.overlay(alignment: .bottomTrailing)` on the scroll view,
  which is sized by the view it sits on and never asks it what it wants.
- `inspector` — `ZStack(.topTrailing) { scrim ; AgentLensInspector }`, whose panel is another
  `ScrollView { LazyVStack }`. The scrim is now the base and the panel its overlay.

`LazyListSizingFitnessTests` pins the rule for every view in `TenonApp` and was proved to catch
the shape (red on a probe carrying it, green once removed).

**This is a candidate, not a proven fix.** The loop was never reproduced, so what can be said
is exactly this: the measured path no longer exists in the code, and it cannot come back
silently. Hypothesis 2 in the list above did test a ZStack-with-overlay PoC and it converged —
so if this were sufficient on its own, that PoC should have spun and did not. The reproduction
below is still what settles it.

### Runbook for the reproduction (needs a human at the GUI)

1. `cd poc && swift run tenon`
2. Open the 19:11 view set: a terminal pane, the **Automation** view, a plugin view
   (`dev.local.supremor-vault-sync/status` if installed, any plugin view otherwise), plus
   three transient panes.
3. Start a real agent in the terminal pane and let it stream for several minutes — the
   measured cycle is a lazy list being asked for its ideal size while its content changes.
4. When the app stops responding, **leave it alone**. The watchdog notices within 5 seconds
   and writes `stall-sample.txt` by itself. Killing it early is what costs the evidence.
5. Attach `health.jsonl` + `stall-sample.txt` to this task. The `dispatchActions` frames in
   that sample name the cycle at its start rather than at 11 GB.

Still open after that: the root cause read from those frames, and the bound regression test.

### The runbook was attempted, and it found two blockers (session 784166de, 2026-08-08)

Not "could not try" — tried, in an Aqua session, and stopped by two facts worth writing down:

1. **Only one Tenon can hold the control channel.** Launching a second instance to drive by
   `tenon-cli` does not work by design: `tenon-cli ping` answered from pid 44385
   (`/Applications/Tenon.app`, up 2h07m), because the single-instance claim gives the socket to
   whoever holds `tenon.lock`. So an automated reproduction can only run *inside the instance
   the person is already using* — which means opening panes in their live workspace. That is
   the human step, and it is a design consequence rather than a missing tool. The second
   instance was stopped immediately; the running app was not touched.

2. **The running app predates the diagnostics.** No `health.jsonl` exists under Application
   Support, so a hang in that process right now would leave no receipt at all. **Restart Tenon
   from the current build before attempting the reproduction**, or the stall sampler is not in
   the process that stalls.

A stand-in agent is ready at `scratchpad/t091/claude` (session 784166de): a script named
`claude` that streams tool-call-shaped output at ~8 lines/second. Agent Lens resolves a provider
from the foreground executable's path, so putting that directory first on `PATH` inside a pane
attaches the lens and churns the timeline without spending real agent quota.

### A permanent bound now exists, and it converges

`PaneUpdateTurnBoundTests` mounts the real pane hierarchy — `PaneContentHost` framed by hand
around `ScrollView { LazyVStack }`, in an off-screen window — and asserts the body-evaluation
count stops climbing. It passes.

It also passes with `sizingOptions` mutated back to the platform default, which **independently
reproduces the earlier PoC result**: the sizing options alone do not spin. So the trigger needs
something none of these probes have — live content churn, the AppKit-hosted nesting, and the
19:11 view set together. That narrows the search rather than settling it.

## Criteria — landed (the measured part)

- [x] A pane's host publishes no sizing options, so `layout()` is the only thing that
      sizes a pane: `PaneContentHost.make` in `SpatialCanvasView.swift`
- [x] `PaneHostingSizingTests` went red on the old behavior (`It carried 7`) and green on
      the new one, and also pins the platform default it is answering
- [x] `docs/design-pane-hosting.md` states the arrangement, and states plainly that it is
      NOT a proven fix for the hang
- [x] `swift test` green across the suite

## Criteria — open (the hang itself)

- [x] The steps are written down (runbook above), and the next stall samples itself five
      seconds in instead of two hours in
- [ ] The loop is reproduced by running those steps against the real app
- [ ] Root cause identified from that reproduction, with the falsification that supports it
- [~] A regression test that bounds update turns exists and passes (`PaneUpdateTurnBoundTests`).
      The "red before the fix" half cannot be honoured while there is no reproduction to be red
      against — that is stated rather than papered over.

A watchdog script (`scratchpad/watch-tenon.sh`, session efc4afbd) samples the process on
the first sustained spin — the earlier sample was taken after 10 GB had swapped, which
made every turn slow and hid whatever the first turns looked like.

## Dogfooding attempt, 2026-08-07 21:30–21:50 — did NOT reproduce

Drove the running app hard through `tenon-cli`: 12 panes covering all eight content kinds
(terminal, changes, docs, automation, empty, file, plugin, diff) across four tabs, several
live PTYs, the automation view and two plugin views open together — i.e. a superset of the
19:11 view set. The app stayed at **2-4% CPU / 238 MB** throughout. No spin.

So the trigger needs something this exercise did not supply. The obvious remaining
difference from the hang: an **Agent Lens** session was live then (the sample carries
`AgentTimelineItem` frames), and there is no public intent that opens Agent Lens — it is a
mode of a terminal pane that engages when an agent is detected in the PTY. Next attempt
should run a real agent in a pane and leave it producing output.

Everything the CLI exercised behaved correctly, including fail-closed refusals; the
`deadline-exceeded` results were consent prompts awaiting a human, confirmed by the user.
