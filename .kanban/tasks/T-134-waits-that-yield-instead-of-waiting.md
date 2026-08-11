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

Done in `Tests/TenonIntentCoreTests/CallerConsentTests.swift:861` and
`Tests/TenonIntentCoreTests/IntentMailboxTests.swift:757` (`reachedFullStrength`). A generous
deadline costs nothing when the condition is met — the loop returns as soon as it is true, and the
consent suite went from a hard failure to 21/0 in 0.873 s.

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
