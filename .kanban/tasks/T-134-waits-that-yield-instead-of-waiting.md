# T-134: Waits that yield instead of waiting

> Twelve test files spin `Task.yield()` a fixed number of times and call it a wait. Two of them
> turned red on a busy machine this week; the rest are the same bet with different odds.

- **priority**: medium
- **effort**: M
- **owning PRD**: `docs/prds/engineering-quality.prd.md`

## The defect

```swift
for _ in 0 ..< 2_000 {
    if await probe.requestCount() >= expected { return }
    await Task.yield()
}
XCTFail("confirmation authorizer never received 1 request(s)")
```

`Task.yield()` reschedules onto the **same** cooperative pool. It does not hand the pool back and
it does not sleep, so a fixed iteration count is not a bound on anything — it is a guess about how
the scheduler will interleave. When the machine is loaded, the work being waited for never runs,
the count runs out, and the test reports a concurrency failure the code never committed. The
failure message says the opposite of what happened: "never received 1 request" reads as a lost
prompt, when the prompt was simply still queued.

Measured 2026-08-12: with ~20 agents running on this machine,
`CallerConsentTests.testConcurrentPolicyApprovalsShareOnePromptAndPersistOneGrant` failed **in
isolation** in 0.161 s, while passing in two full-suite runs an hour earlier on the same tree.
Nothing about the code under test changed between those runs.

## The fix, already applied twice

Wait on a wall-clock deadline and **suspend** rather than yield, so the executor can actually run
the pending work:

```swift
let deadline = ContinuousClock.now + .seconds(10)
while ContinuousClock.now < deadline {
    if await probe.requestCount() >= expected { return }
    try? await Task.sleep(for: .milliseconds(5))
}
```

Done in `Tests/TenonIntentCoreTests/CallerConsentTests.swift:861`,
`Tests/TenonIntentCoreTests/IntentMailboxTests.swift:757` (`reachedFullStrength`) and
`:648` (`waitForRunning`). A generous deadline costs nothing when the condition is met — the loop
returns as soon as it is true, and the consent suite went from a hard failure to 21/0 in 0.873 s.

**Deferring the rest was a mistake, and CI charged for it.** This task was written listing the
remaining sites as future work. One run later, `waitForRunning` — item 6 on that list — turned CI
red (`testALaneIsSerialByDefault`, run 31531099048), having passed 2001/0 on the run before on the
same tree. A list of known-fragile waits is not a plan; each one is red the day the machine is
busy enough. Take the whole sweep in one change.

## A second failure this uncovered, which is not a wait at all

`AgentsRunTests.testAgentsRunUsesTheProvidingCallWhenGivenIt` asserted the exact arrival order of
the nested calls and flipped between runs: CI saw `open, write, wait, read` on 31531099048 and
`open, wait, write, read` the run before.

That order is not something the code promises. `agents.run` starts `terminal.wait.v1` **without
awaiting it** and only then writes the command — deliberately, because a wait armed after the
command runs loses every short run (`PluginRuntimeBootstrap.swift:553-565`). The two are therefore
in flight together, and which crosses into the test's `NestedSendRecorder` actor first is a
scheduling detail. The double is called straight through `nestedSend` and never passes the
per-pane lane that orders these for real, so asserting arrival order there asserts the harness.

The assertion now pins what is actually guaranteed — `open` first, `scrollback.read` last, and the
pair between them as a set. **This is worth revisiting properly**: whether the host guarantees that
a wait submitted before a write is armed first, through the pane lane, is a real question about
`agents.run`'s contract, and no test covers it today.

The same reasoning retired a fixed `Task.sleep(for: .milliseconds(140))` in
`IntentTelemetryTests` on the same day: the reporter promises the coalesced value arrives *after*
its interval, and how promptly a loaded machine runs that timer is not part of the promise.

## The remaining sites

`rg -l 'Task.yield\(\)' Tests/` finds twelve files. Not every one is wrong — a single
`await Task.yield()` to let one continuation resume is fine. What must go is the **counted spin
standing in for a wait**. Known instances:

| File | Line | Iterations |
|---|---|---|
| `Tests/TenonAppStateTests/PaneFocusSettlementTests.swift` | 189 | 50 |
| `Tests/TenonAppStateTests/FileDocumentIOTests.swift` | 422 | 20 |
| `Tests/TenonAppStateTests/AgentSessionTimelineTests.swift` | 1014 | 20 |
| `Tests/TenonAppStateTests/AgentLensTests.swift` | 1498, 2479 | 20 |
| `Tests/TenonIntentCoreTests/IntentMailboxTests.swift` | 65 | 200 |
| `Tests/TenonCoreTests/PaletteProviderTests.swift` | 244 | 50 |

Plus whatever the same `rg` turns up in `PluginWebSurfacePoolTests`, `PermissionBypassTests`,
`FileDocumentExternalChangeTests`, `AutomationScheduledDeliveryTests`,
`PluginModalPresentationTests`, `IntentPolicyTests` and `ProviderRegistryTests`.

## Criteria

- [ ] Every counted `Task.yield()` spin standing in for a wait is replaced by a deadline-bounded
      suspend; bare single yields may stay
- [ ] A shared helper carries the pattern once instead of each file re-deriving it
- [ ] Each converted test still fails when the behavior it asserts is broken — verify by mutation,
      not by watching it go green
- [ ] `swift test` green, run **while the machine is loaded**, since an idle run is what hid this
- [ ] `docs/prds/engineering-quality.prd.md` carries a requirement for the rule and a receipt

## Owner / files (agent lock)

_Unclaimed._ Claim by listing files here with your session id before the first edit.
⚠️ Spans many test files across three targets. Check every Doing task's file list first — this is
the kind of sweep that collides with everything.
