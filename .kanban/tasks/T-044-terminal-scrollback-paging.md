# T-044: Reading a pane stops at the viewport
> `terminal.viewport.read.v1` returns the visible screen. An agent that needs the output of
> a command longer than the window has no way to reach the rest of the scrollback.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 247281cf — **DONE 03:5x, ALL LOCKS RELEASED.** Claimed 03:35 after the task sat
auto-dispatched in Doing since 03:20 with no owner and no file touched.

Files changed (all free again):
- NEW `poc/Sources/TenonCore/ScrollbackPaging.swift`
- `poc/Sources/TenonCore/CoreIntentCatalog.swift` — the canonical contract, its two bounds,
  and the new name in the audience and lane switches
- `poc/Sources/TenonApp/{TerminalSurface,GhosttySurface,SurfacePool,TerminalIntentProvider}.swift`
- NEW `poc/Tests/TenonCoreTests/ScrollbackPagingTests.swift`;
  `poc/Tests/TenonCoreTests/CoreIntentCatalogTests.swift`;
  `poc/Tests/TenonAppStateTests/{TerminalIntentProviderTests,PluginWebSurfacePoolTests}.swift`
- `docs/architecture-interaction-boundaries.md`

Never opened: `PluginHost.swift`, `PluginManifest.swift`, `TenonApp.swift` and the new
`Automation*.swift` — another session is mid-change in those.

Files this task will change (read the board before claiming — these are hot):
- `poc/Sources/TenonApp/TerminalIntentProvider.swift` (the read binding)
- `poc/Sources/TenonApp/{GhosttySurface,TerminalSurface,SurfacePool}.swift` (a scrollback
  accessor beside `renderedText`)
- `poc/Sources/TenonIntentCore/**` (the intent's canonical contract, if a new name is added)
- `poc/Tests/TenonAppStateTests/TerminalIntentProviderTests.swift`
- `docs/architecture-interaction-boundaries.md` (classify BEFORE writing code)

## Provenance
The remaining half of T-009's Phase 3. Phase 3 was written as *"`read --cursor` scrollback
paging, push-idle, `wait --for command-finished` (OSC 133)"*; the `command-finished` half
shipped and is now asserted (T-009 criteria). Paging never did.

## Evidence for the gap (2026-07-31, at `17bf0a6`)
- The only read intent is `terminal.viewport.read.v1`, and it answers
  `{paneID, text, exited, columns, rows}` from `TerminalSurface.renderedText` —
  documented at `TerminalSurface.swift:34` as *"the current visible screen as plain text"*.
- No parameter anywhere names a cursor, offset, page or limit; nothing in `poc/Sources`
  reads scrollback beyond the viewport.
- Ghostty exposes `read_cells` / `read_text` over a range, which is what T-009's
  feasibility note relied on — so the backend can answer this; only the Tenon-side contract
  is missing.

## Classification — written before the code (2026-07-31 03:40)

**Ordered decision law walk.** CONTRIBUTION? No — nothing durable is registered. EVENT? No
— this is a pull the caller initiates and requires an answer to, not a host-originated
notification with 0..n subscribers. RESOURCE / STREAM / TASK? No — a stream would model
*continuous* output the plugin subscribes to and the host pushes; `terminal.wait.v1`'s own
contract already reserves that as "a separate future resource stream". This is one bounded
answer per call, the caller creates and owns no producer, and there is nothing to cancel
beyond the call. **The cursor is a value, not a handle**: it holds no host state, nothing
leaks if the caller drops it, and it expires by invalidation rather than by release — which
is exactly what keeps this off the RESOURCE rung. Same-owner DIRECT? No — plugin, CLI and
agent are different principals from the pane's terminal. SCOPED FACILITY? The allowlist is
closed (settings, plugin-private storage, log). → **INTENT**, `terminal.scrollback.read.v1`.

**Required statements.** Semantic owner: the pane's terminal surface (`SurfacePool` over
`GhosttySurface`). Caller principals: programmatic `{plugin, cli, agent}`, the same profile
as `terminal.viewport.read.v1`. Result cardinality: exactly one page per call. Lifetime: the
call. Authority: the existing `terminal.read` capability — this reads what
`terminal.viewport.read.v1` already reads, only further back, so it earns no new gate.
Failure semantics: `dev.tenon.core.terminal-unavailable` when the pane has no surface, and a
typed `invalidated` result when the scrollback moved under the cursor. Backpressure: bounded
page size, bounded readable depth, and the existing `terminalImmediate` serial lane.

**Cursor coherence, and its stated cost.** Ghostty addresses scrollback by absolute row in
`GHOSTTY_POINT_SCREEN` space and exposes no stable per-row identity, so "this index still
means the row it meant" is not directly observable — when the buffer evicts from the top,
every earlier index shifts. The cursor therefore carries the row count observed when it was
issued, and **any change to that count invalidates it**. That is deliberately strict: it is
the only claim the emulator lets us actually verify, and a silent skip in the middle of a
command's output is worse for an agent than being told to start again. Paging is therefore
reliable over a pane whose output has stopped — the case that matters, reading back what a
finished command printed — and reports invalidation rather than lying over a live one.

## Design constraints this must respect
- **Classify first.** A finite plugin/CLI→host read is INTENT by the boundary law's default;
  a long-lived push of new output would be a STREAM and is a different decision. Record the
  rung in `docs/architecture-interaction-boundaries.md` before the code, not after.
- **Bounded.** Invariant 10: every payload is bounded. A page has a maximum size, the pane
  has a maximum readable depth, and both are stated in the contract rather than implied by
  whatever the terminal happens to hold.
- **A cursor is not a line number.** Scrollback shifts under the reader as the shell writes.
  The cursor has to survive that or say plainly that it did not — an agent that pages
  through output must not silently skip or repeat a region.

## push-idle: the poll is the decision

`terminal.wait.v1` samples the pane every 200 ms with a 20 ms tolerance
(`TerminalIntentProvider.swift`), and `tui-idle` needs three quiet samples from
`IdleDetector(stableSamples: 3)`. The observable cost: `exit` and `command-finished` are
learned up to one interval late (~200 ms), `tui-idle` up to three (~600 ms).

Ghostty does expose a push seam — `ghostty_surface_set_data_callback` — so a pushed signal
is buildable. It is deliberately not built, for three reasons:

1. **`tui-idle` is a quiescence predicate, and quiescence has no edge to push.** "Nothing
   changed for a while" needs a clock whatever wakes it; a push path would still own a
   debounce timer, so the timer does not go away, it just moves and multiplies.
2. **This cadence is already shared.** T-029's `SurfacePool.pollActivity(at:)` observes the
   same panes on the same 200 ms tick for the attention dots. Adding a push path for the
   wait verbs alone would leave two mechanisms observing one thing — the second typed
   implementation invariant 6 forbids — and the honest version of the change is to move
   *both*, which is a larger piece of work than this task.
3. **The latency is under the human threshold the product is built around.** These are
   supervision signals for a person deciding where to look, not a control loop.

If it is revisited, the shape to reach for is one pushed pane-observation feed that both
the wait verbs and the attention machine consume — one mechanism, not a second one.

## Criteria
- [x] The rung is classified before implementation — the walk is above, written 03:40
      before any code; `docs/architecture-interaction-boundaries.md` gains
      `terminal.scrollback.read.v1` in the INTENT inventory and the `terminalImmediate`
      lane, plus the reusable rule the decision turned on: **a continuation token is not a
      handle**, so a paging cursor does not move an interaction onto the RESOURCE rung
- [x] Paging is expressible — `terminal.scrollback.read.v1` reads the whole retained
      buffer, viewport and scrollback, in bounded pages;
      `testPagingWalksTheEntireScrollbackAndThenReportsTheEnd` walks 10 rows in 3 pages of
      4 and asserts every row arrives exactly once, in order, ending on a null cursor
- [x] The contract states its bounds — `maximumScrollbackPageLines` (2 000 rows) and the
      inherited `maximumInlineTextCharacters`, whichever ends the page first; a caller
      asking for more gets a typed refusal
      (`testScrollbackPageSizeIsBoundedByTheContract`), never a silent truncation
- [x] Behaviour under a moving scrollback is asserted, not assumed —
      `testACursorIsRefusedOnceTheScrollbackHasChangedSize` writes two more lines between
      page one and page two and requires `invalidated: true` with no rows
- [x] `terminal.viewport.read.v1`'s shape is unchanged — its schema, its handler and
      `testViewportReadReturnsOneTypedLiveObservation` are untouched
- [x] **push-idle**, the third Phase 3 item: **the poll stays, as a decision.** Recorded
      below with its cost, so it is a chosen cadence rather than an unexamined loop
- [x] Each rule is mutation-proven — table below, five mutations, each red on its own
      named assertion, every source restored byte-identical afterwards
- [x] `swift build` exit 0 + full `swift test` **838 / 0** (792 before this task)

## What landed

`ScrollbackPaging` (`poc/Sources/TenonCore/ScrollbackPaging.swift`) is the whole rule, and
it is pure: `(totalRows, maxLines, cursor) -> .rows(Range, next:) | .invalidated`. It needs
no terminal, no window and no run loop, which is the repo's fitness test for whether a rule
is in the right layer. Everything else is edge work — `GhosttySurface.scrollbackLines` asks
the emulator what it holds, `SurfacePool` distinguishes *no surface* from *no rows*, and
`TerminalIntentProvider.readScrollback` parses, resolves and formats.

**Reading the whole buffer to answer one page** is deliberate, and the comment at the
Ghostty call site says why: `GHOSTTY_POINT_SCREEN` with the `TOP_LEFT`/`BOTTOM_RIGHT` coord
modes is the only way to name the ends of a buffer whose size the emulator never publishes,
and the cursor's coherence check needs that size. The bound the contract promises is on
what leaves the host, and that bound is enforced.

**No new `tenon` member.** A plugin reaches this through `tenon.intents.send` with
`terminal.scrollback.read.v1` declared in its manifest, exactly as invariant 7 requires of
finite work. The public JS vocabulary in `CLAUDE.md` is unchanged.

## Mutation proofs

| # | Mutation | Named assertion that went red |
|---|---|---|
| M9 | cursor's `totalRows` check dropped — nothing ever invalidates | `testACursorIssuedAgainstADifferentScrollbackSizeIsRefused`, `testACursorIsRefusedOnceTheScrollbackHasChangedSize` |
| M10 | page size no longer clamped to ≥ 1 row | `testAPageSizeBelowOneStillMakesProgress` |
| M11 | next cursor always `nil` — paging stops after one page | 7 tests across both suites, including both walk tests |
| M12 | `Cursor.decode` drops its `nextRow <= totalRows` check | `testDecodeRejectsAnythingItDidNotWrite` |
| M13 | contract page bound not enforced in the provider | `testScrollbackPageSizeIsBoundedByTheContract` |

Not mutation-covered: `GhosttySurface.scrollbackLines` itself, which needs a live PTY and a
GPU. Its seam is asserted through the stub; the C call is the untested edge, in the same
band as `renderedText` beside it.

## Fixed in passing

`PluginWebSurfacePoolTests.testLifecycleCallbackRetiresSurfacesWithoutASpatialCanvas`
(revived in T-043) was **flaky**: it waited on data-store retirement with a
`Task.yield()` loop, which offers the scheduler a turn without passing wall-clock time, so
a thousand iterations can burn through in microseconds. It passed alone 3/3 and failed
inside the full suite. Now a bounded sleep-based wait, green in both.
