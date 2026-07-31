# T-048: Supervised agent fleets — prove and package the workflow shape
> Claude Code's dynamic workflows (`agent()`/`parallel()`/`pipeline()`) are already
> compositionally possible in Tenon automation JS as of 2026-07-31 (T-046 + T-040 +
> T-009 + T-044). This task turns "possible" into "proven and ergonomic": an
> end-to-end integration test, a shipped demo, and one packaging decision.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session f014e8e0 — **SLICE 1 DONE 09:5x, ALL LOCKS RELEASED** (every file below is free). This slice ships the platform function;
the real-provider e2e + shipped demo criteria stay open for a follow-up slice.
- `poc/Sources/TenonCore/PluginRuntimeBootstrap.swift` (the `tenon.agents` member)
- `poc/Tests/TenonCoreTests/PluginBuiltinsTests.swift` (surface pin list only)
- NEW `poc/Tests/TenonCoreTests/AgentsRunTests.swift`
- `docs/architecture-interaction-boundaries.md` (one inventory-table row)
- `CLAUDE.md` (vocabulary line) · `docs/design-automations.md` (§ Orchestration)

## Decisions landed 09:4x (user-directed)
- **Packaging RESOLVED by the user**: automation scripts are AI-authored, the platform
  provides the functions, and automations share the entire plugin machinery (T-046's
  design confirmed). `agent()` ships as **`tenon.agents.run` in the runtime bootstrap**
  — JavaScript composition over `tenon.intents.send`, running in the CALLER's
  generation under the CALLER's principal. Every underlying send is policy-checked
  against the calling plugin's own manifest (`terminal.open.v1`, `terminal.wait.v1`,
  `terminal.scrollback.read.v1` must be declared in its `uses`). The rejected
  alternative — a broker plugin providing `agent.run` as a plugin-owned intent — would
  execute under the BROKER's grants (nested sends use the provider's principal), i.e.
  authority laundering; rejected for exactly that reason.
- **The latch question is ANSWERED from the implementation**, not a guess:
  `terminal.wait.v1` snapshots `commandFinishedCount` as a baseline AT WAIT TIME and
  waits for `count > baseline` (`TerminalIntentProvider.swift:405,428`) — completions
  before the first wait are invisible. `tenon.agents.run` therefore issues its first
  wait immediately after `open` returns; the residual race is the gap between
  open-return and first-wait vs. pane materialization + shell spawn + command run
  (T-031 lazy materialization makes the command start strictly later in real panes).
  Documented in the design doc; a contract-level fix (optional client-held baseline on
  wait) stays a follow-up criterion below.

## Context (see docs/design-automations.md § Orchestration)
The mapping is complete: script = automation JS; `agent()` = `terminal.open.v1` →
`terminal.wait.v1` (`command-finished`, `{scope:{paneID}}`) → `terminal.scrollback.read.v1`;
headless structured variant = `process.exec.v1`; `parallel()` = `Promise.all` (256
in-flight outbound intents per generation, `PluginRuntime.swift:101,983`); supervision
is the differentiator — fleet agents run in visible PTY panes with T-029 attention
signals and scrollback evidence, and a human can take any pane over mid-run.

## Criteria
- [~] **The race question answered from the implementation** (baseline snapshot at wait
      time, `TerminalIntentProvider.swift:405,428` — no latch); `agents.run` arms its
      wait immediately after open and the residual window is documented. Remaining for
      a later slice: a provider-level test pinning the no-latch behavior + the optional
      client-held-baseline contract extension. Original text: **answered with a test, not a guess**: does
      `terminal.wait.v1` `command-finished` latch a completion that happened BEFORE the
      wait was issued (open → command finishes fast → wait)? If it does not, `agent()`
      as documented can hang and the doc snippet + demo must issue the wait before/
      concurrently with the command, or the provider gains latch semantics (its own
      classified change). Whatever the answer, `docs/design-automations.md`'s snippet
      must match measured behavior.
- [x] End-to-end integration test — `AgentFleetIntegrationTests`: one handler, `Promise.all` over two `tenon.agents.run`, both transcripts paged and aggregated, against a real kernel + real `PluginHost` + real `TerminalIntentProvider`; only the surface is stubbed. Writing it found all three defects.
- [x] Scrollback `invalidated: true` (pane resized mid-read) handled in the documented
      `agent()` (restart the page walk once, then fail typed) and asserted.
- [x] Packaging decision recorded and implemented: `agent()` as (a) documented
      copy-paste snippet only, or (b) a bundled plugin providing a plugin-owned intent
      (e.g. `dev.tenon.workflow.agent.run.v1`) so an automation declares ONE `uses`.
      (b) crosses plugin↔plugin policy per call — walk the boundary law before choosing;
      "library via intent" must not become authority laundering (the caller still needs
      its own terminal.write? — answer explicitly).
- [x] Prompt/shell-quoting guidance (shipped stronger than guidance: `tenon.agents.run`
      takes `arguments: [string]` and POSIX-single-quotes every token itself —
      mutation-proven by the `$(rm -rf /)` fixture) for `terminal.open.v1` commands (a prompt containing
      `'` or `$(...)` must not become shell injection into the user's PTY) — documented,
      with a helper if warranted.
- [x] Shipped demo — `poc/examples/fleet-review/`, three reviewers in their own panes aggregated to one status line, loaded and run by `FleetReviewExampleTests` so it cannot rot. Visual half is checklist item 14.
- [x] `swift build` exit 0 + full `swift test` **869 / 0** (claim-time bar 838). RED-first on the kernel slice, red for the right reason, with mutation proofs recorded per slice.

## Notes
- Do NOT hardcode an agent list (Orca's mistake — 25 hardcoded TUI agents). `agent()`
  takes a command string; which CLI it runs is the caller's business.
- `terminal.wait.v1` timeout caps at 55 s/call — deadline loops belong in JS, not in a
  widened contract.
- Related: T-042 (two-way comms decision), T-047 (single-file scripts).


## Verification — slice 1 (`tenon.agents.run`), 2026-07-31 09:5x
- RED first 09:50: 9 tests / 15 assertion failures, 0 unexpected — fixture published
  `{"threw":"undefined is not an object (evaluating 'tenon.agents.run')"}` and the
  surface pin rejected the missing member (the T-020 fence observed working again).
- GREEN 09:52: `AgentsRunTests` 8/8 + `PluginBuiltinsTests` 13/13 (pin updated
  in-change: `tenon.agents.run` is the only new member).
- Mutation table (each: break → named red → `cmp`-verified byte-identical restore):
  | mutation | red test | observed |
  |---|---|---|
  | quoting deleted (raw join) | `testRunQuotesEveryArgumentForTheShell` | unquoted `claude -p it's; $(rm -rf /) \`x\`` visible in the diff |
  | invalidation handling deleted | restart + fail-closed tests | `"STALEfresh"` leaked into the transcript |
  | deadline check deleted | `testRunTimesOutWhenTheDeadlinePasses` | starved queue surfaced `tenon.provider-unavailable` instead of the typed timeout |
  | pane scope dropped from wait | `testRunComposesOpenWaitAndPagedReadInOrderWithScope` | wait arrived unscoped (`nil` paneScope) |
- Full suite 09:5x: `swift build` exit 0 (warnings-as-errors), `swift test`
  **860/860, 0 failures** (bar 843 after T-040).
- Docs in-change: boundary-doc runtime inventory row, CLAUDE.md vocabulary line,
  design-automations.md § Orchestration rewritten around the shipped function.

## Remaining for slice 2 (unclaimed)
- Real-provider end-to-end test (real PluginHost + stub terminal surfaces) fanning out
  ≥2 `agents.run` with `Promise.all` from one `automation.fired` handler.
- Provider-level no-latch pin + optional client-held baseline on `terminal.wait.v1`.
- Shipped fleet demo + `ShippedPluginsTests` literal-send rule evolution (a shipped
  plugin using `agents.run` declares 3 uses with 0 literal sends — the grep-based
  drift test must learn the composition).

## Slice 2 (session 247281cf, 10:1x–10:3x) — two defects found, one fixed, slice NOT complete

Building the e2e criterion against the real kernel, a real `PluginHost` and the real
`TerminalIntentProvider` immediately refused every terminal read. Two separate defects came
out of it; neither was visible to slice 1, because a stubbed intent bridge never runs the
policy path.

**Defect 1 — `terminal.read` was ungrantable. FIXED, mutation-proven.**
`PluginHost.capabilityGrants` filtered `terminal.read` out of the grant set, so the
capability that `terminal.viewport.read.v1`, `terminal.scrollback.read.v1` and
`terminal.wait.v1` all name could never be granted to anybody: a plugin could declare the
permission and the use, pass every other check, and still be refused `missing-capability`.
`tenon.agents.run` was therefore unusable by any real plugin.

The exclusion was correct when written — `terminal.read` began as a gate on delivery of
`terminal.*` EVENTs, with no capability behind it (`PluginHost.swift:1448,1485` still read
`manifest.permissions` directly and are untouched). It stopped being correct when the read
intents bound it as their capability, and nothing noticed. New regression:
`Tests/TenonAppStateTests/TerminalReadCapabilityTests.swift` — a real plugin, real policy
path, only the surface stubbed. Restoring the exclusion reddens it.

**Defect 2 — `agents.run` lost every short run. FIXED.**
`run` opens the pane *with* the command, then arms the wait. `terminal.wait.v1` snapshots
its completion baseline when issued, so a command that finishes in the gap is already
counted and the wait sits out its entire timeout. Measured against the real provider:
`dev.tenon.agents.timeout` on a command that had already succeeded. This is exactly the
latch race this task file predicted.

The fix needs no host change and no new semantics: open the pane **empty**, arm the wait,
*then* send the command with `terminal.write.v1` (`terminal.open.v1` takes an optional
command precisely so this is expressible). Nothing can finish before the baseline is taken.
Applied 10:4x. Callers add `terminal.write.v1` to `intents.uses`; slice 1's eight tests
moved the command assertion from the open input to the write input, their bridge answers
`terminal.write.v1` by default (plumbing, not a rule those tests pin), and the ordering
assertion now states the reason. All eight pass. A single supervised run now completes
against the real provider, which it never did before.

**Defect 3 — concurrent supervision was impossible. FIXED (kernel slice, 11:0x).**

With defect 2 fixed, a fleet of two still fails, and asymmetrically: the first agent
succeeds and the second returns `dev.tenon.agents.timeout`. The cause is structural, not a
bug in `agents.run`.

`terminal.wait.v1` lives alone in the `terminalWait` execution lane, and the boundary law
says every lane owns *one bounded serial mailbox*. So the second agent's wait queues behind
the first agent's, which by design does not return until its condition is met. Meanwhile the
second agent's `terminal.write.v1` runs on the `terminalImmediate` lane, which is not
blocked — so its command runs and finishes while its wait is still queued. When the wait
finally starts, it snapshots a baseline that already counts the finish, and waits forever
for a second one.

Serial lane + baseline-relative wait = at most one supervised agent at a time. Measured:
`fleet: alpha=OK-ALPHA beta=ERR:dev.tenon.agents.timeout`.

Recorded 2026-07-31 in `docs/architecture-interaction-boundaries.md` under **Falsification**,
as an open counterexample against the core-execution-lane law, carrying the measurement and
the two candidate revisions. The change protocol wants the counterexample where the law
lives, so the next slice starts from evidence instead of rediscovering it.

This cannot be fixed inside `agents.run`. The options are a classified change to the lane
(concurrent waits, since a wait holds no resource and its whole job is to block), or a
latch on the wait condition so a finish that happened before the wait armed still counts.
The first looks right — `terminalWait` was split out precisely so long waits would not
block the immediate lane, and serialising them defeats that purpose — but it is a change to
the execution-lane law and belongs in its own slice with its own walk.

**Scoped 2026-07-31 so that slice can be planned rather than explored.** The serialization
is neither in the dispatcher nor in the law's prose: `IntentMailbox` holds
`private var running: Running?` — a single optional job — and
`AppIntentRuntime.makeCoreExecutionLanes` gives every lane exactly one mailbox. That one
slot is the whole mechanism.

Option 1 means giving `IntentMailbox` a bounded concurrency limit defaulting to 1, so every
lane keeps today's behaviour and only `terminalWait` is built above it. Measured cost:
`running` is touched at **31 sites** in a 691-line actor, and those sites are the
cancellation, expiry, deadline-task and completion paths — exactly the machinery invariant
10 rests on. That is a kernel slice with its own RED-first cycle, mutation proofs and the
separate reviewer pass the change protocol demands, not an appendix to this card.

### Slice 2 criteria status
- **e2e fan-out test: DONE.** `AgentFleetIntegrationTests` — one event handler, `Promise.all`
  over two `tenon.agents.run`, both transcripts paged and aggregated to the status bar,
  through a real kernel, real `PluginHost` and the real `TerminalIntentProvider`. Both agents
  complete in under a second. Only the terminal surface is stubbed. `TerminalReadCapabilityTests`
  guards defect 1 separately.
- **Shipped demo: DONE.** `poc/examples/fleet-review/` — one palette command, three
  reviewers, each in its own pane, all supervised concurrently, aggregated to one status
  line. In `examples/` rather than `plugins/` on purpose: a demo that runs an agent CLI does
  not belong in every user's palette by default. `FleetReviewExampleTests` loads that exact
  directory through a real `PluginHost` and runs the command, so it cannot rot the way the
  four files in T-043 did. Documented in `docs/design-automations.md`; the visual half is
  item 14 of the human-verification checklist.

  🐞 Writing the test found a wart in the example's own contract: the command declared
  `confirmation: "policy"`, so one click would have asked the human **four** times — once
  for the command, once per `terminal.open.v1` — which trains people to click through the
  prompt that matters. It performs nothing itself; every external effect goes through
  intents that are already gated. Now `confirmation: "never"`, and the test that surfaced it
  (it hung, waiting on a confirmation nothing could answer) is the regression.
- **Shipped demo: NOT DONE.** A demo that times out is worse than none.
- **Evidence: DONE for what landed** — `swift build` exit 0, full `swift test` **865 / 0**.


## The kernel slice (11:0x) — lanes gained a concurrency bound

Defect 3's fix, done as its own RED-first slice under the change protocol.

`IntentMailbox` held `private var running: Running?` — one slot — and `drain()` awaited each
operation inline, which is what made every lane serial. Now `IntentMailboxLimits` carries
`maxConcurrentRequests` (default **1**, validated `1 ... maxRequests`), the mailbox holds its
running requests in a bounded dictionary, and `drain` starts up to the limit and lets each
request finish itself through a new `complete`. Retirement settles **every** running request
rather than one. `IntentMailboxSnapshot.runningRequestID` became `runningRequestIDs`.

`CoreIntentExecutionLane.maxConcurrentRequests` is the single place a lane states it: 8 for
`terminalWait`, 1 for every other lane, so nothing else changed behaviour.

**Evidence.** RED first, and red for the right reason — exactly one failure, with
`testALaneIsSerialByDefault` passing beside it so the harness could not be vacuous. Then:

| # | Mutation | Test red |
|---|---|---|
| M24 | `terminalWait` concurrency 8 → 1 | `testOneEventHandlerFansOutTwoSupervisedAgents…` |
| M25 | drain gate back to one-at-a-time | `testALaneRunsConcurrentlyWhenItsConcurrencyLimitAllows`, the fan-out test |

`cmp`-verified byte-identical restores. Full `swift test` **868 / 0**.

**Law updated in-change**, per protocol §3: the normative lane sentence no longer says
"serial" — it says bounded queue *and* bounded concurrency, serial by default, raised only
where serialization does no work, with a table naming `terminalWait` as the only exception
and why. The Falsification entry is rewritten from open to **resolved**, keeping the
measurement, the rejected alternative (latch semantics — cheaper, and it would change what
the contract means), and the fitness tests.

⚠️ **Change-protocol §7 reviewer pass owed**: this was authored and self-verified in one
session. An independent review of the mailbox's cancellation, expiry and retirement paths
under concurrency is the right next check — those are the paths invariant 10 rests on.