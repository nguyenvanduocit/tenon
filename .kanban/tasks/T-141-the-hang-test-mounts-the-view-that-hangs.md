# T-141: The hang test mounts the view that actually hangs
> `PaneUpdateTurnBoundTests` proves convergence against a hand-written imitation of Agent Lens, so the shape that froze the app for 1095 s cannot reach it.
- **priority**: critical
- **effort**: M

## Owner / files (agent lock)
Session `7e46371b` 2026-08-12 16:5x. **Third card in Doing, over the WIP limit, by explicit operator decision** — the operator reported a live hang and chose this route over two faster unproven ones. Files below are held by nobody else: T-140 holds workspace-close paths, T-135 holds the Ghostty smoke lane.
- `Sources/TenonApp/AgentLensView.swift`
- `Tests/TenonAppStateTests/PaneUpdateTurnBoundTests.swift`
- `Tests/TenonAppStateTests/LazyListSizingFitnessTests.swift`

Added once the incident sweep showed the freeze is not one defect (see below). `GhosttySurface.swift`
is on T-140's list with its own entry marked *G1, done*, and T-140 has released `SurfacePool.swift`;
this change is additive and in a different region, recorded here so the overlap is visible rather
than silent.
- `Sources/TenonApp/SurfacePool.swift`
- `Sources/TenonApp/TerminalSurface.swift`
- `Sources/TenonApp/GhosttySurface.swift` — additive: one computed property beside `renderedText`
- `Sources/TenonCore/PaneActivity.swift`
- `Sources/TenonCore/IdleDetector.swift`
- `Tests/TenonCoreTests/IdleDetectorTests.swift`
- `Tests/TenonCoreTests/PaneActivityTests.swift`
- `Tests/TenonAppStateTests/PaneAttentionTests.swift`

## Evidence (incident 0009-642b2192, run d4d62a2d, 2026-08-12 16:38)
- Main thread never returned from one runloop-observer call. `beatSequence` frozen at 3044316 for **1095 s**; footprint 534 → **1860 MB**; force quit was the only exit.
- 98.2% of main-thread samples under AttributeGraph. `LazyLayoutViewCache.updateItemPhases` 34.7%; **self time `AG::Graph::propagate_dirty` 17.5%** — the graph is dirtied while it is being measured. `LayoutEngineBox.sizeThatFits` nests 156 deep.
- Last transition before the freeze: `agent-lens-scroll-executed` paneOrdinal 18, `pinned:false` — the `.onAppear` branch (`AgentLensView.swift:613`), not the revision branch `AgentScrollTurnGate` guards. The gate behaved correctly on pane 20.
- The app's own sample, taken at the moment of onset, has the same shape as one taken 14 minutes later. Not a late steady state.
- Suspected loop closer (MEDIUM, unproven): `SelectionOverlay.updateNSView` — the representable backing `.textSelection(.enabled)` — runs `NSControl setFont:` → `_invalidateEffectiveFont` → `invalidateIntrinsicContentSize` → `setNeedsUpdateConstraints:`, dirtying the constraint pass from inside the pass measuring it. Same mechanism as T-121, different actor.

## Why the existing defence missed it
`LiveAgentSessionProbe` imitates `AgentSessionView` and omits exactly what the evidence names: no `.textSelection(.enabled)`, no `.onAppear` bottom scroll, `Text(row)` in place of `AgentTimelineRow`/`AgentMarkdownText`. A test named `testProductionShapedAgentSession…` that is not production-shaped is why repeated fixes kept passing while the app kept freezing.

## What the incident sweep changed about this task

Reading all eight incidents instead of the newest one turned the premise over: **the freeze is
not one defect**. Four different main-thread shapes in one run — a 5 Hz attention poll rendering
every pane to text (83%, `0005`), a SwiftUI layout loop (`0009`), `AttributedString`/`memmove`
churn (`0002`/`0008`), and one thread idle in `mach_msg2_trap` (`0003`). That is why each earlier
fix held and the app still froze: the next freeze was a different bug.

So this task shipped the cause that could be *proved*, and records the one that could not.

## Criteria
- [x] `AgentSessionView` is reachable from `TenonAppStateTests` and the convergence test mounts **it**, not an imitation
- [x] `LazyListSizingFitnessTests` textual probe updated for the access change
- [x] No fixture left that imitates a production view it could mount — `LiveAgentSessionProbe` deleted
- [x] `SP-NFR-013` red first (`("40") is not equal to ("0")`), then green; PRD, feature, decision log and receipt updated
- [ ] **Not met, deliberately**: the mounted Agent Lens test *passes*, so `0009`'s layout loop is not reproduced. The `.textSelection(.enabled)` + `.firstTextBaseline` mechanism read off its stack (`AgentLensMarkdownView.swift:142`+`152`, `:282`+`313`, `AgentLensView.swift:1111`+`1114`, `:1302`+`1309`) is **unconfirmed**, and is written down here rather than shipped as a finding.

## Follow-ups this task found and did not take
- `terminal.wait.v1` (`TerminalIntentProvider.swift:447`) still renders a pane to text every 200 ms while a caller waits. Same defect class, far smaller blast radius: one pane, only while waiting. Left minimal (`.hashValue`) so behaviour is unchanged.
- `0002`/`0008` have no named cause.
- The watchdog wrote **no `sample.txt` for 3 of 8 incidents**, and opened `0003` while the main thread was idle. The diagnostic this whole route depends on is both losing data and emitting noise.

## Reported to another lane, not touched
`DomainTagFitnessTests.testNoTagIsIsolatedFromTheCodeAroundIt` is red at 9 over a budget of 8.
The ninth is `PluginStreamProcess.swift: plugin-host`, an untracked new file in T-140's lane
(session `40b0d244`). None of the nine is in this task's file set.
