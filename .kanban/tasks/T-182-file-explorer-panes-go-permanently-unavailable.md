# T-182: File Explorer panes go permanently "Plugin view unavailable" after normal use
> Operator report: restart the app, open a few File Explorer panes normally — after a while every
> File Explorer pane (new ones included) freezes on "Plugin view unavailable" until the app restarts.
- **priority**: high
- **effort**: S

## Owner / files (agent lock)
**Released 2026-08-18 17:4x, this session — operator confirmed live, closing.** Files touched
across all four rounds: `Sources/TenonBundledPlugins/FileExplorerPlugin.swift`,
`Sources/TenonBundledPlugins/BundledPluginRuntime.swift`, `Sources/TenonBundledPlugins/BundledPluginProgram.swift`,
`Sources/TenonBundledPlugins/GitPlugin.swift`, `Sources/TenonBundledPlugins/ClaudeSessionsPlugin.swift`,
`Sources/TenonBundledPlugins/KanbanPlugin.swift`, `Sources/TenonBundledPlugins/WorkspaceStatusPlugin.swift`,
`Sources/TenonApp/TenonApp.swift`, `Sources/TenonApp/WorkspaceEventBroadcastPump.swift` (new),
`Tests/TenonCoreTests/FileExplorerPluginTests.swift`, `Tests/TenonAppStateTests/WorkspaceEventBroadcastPumpTests.swift` (new).
All now FREE.

## Root cause (verified live by test, 2026-08-18 15:0x)
- "Plugin view unavailable" = `PluginSlotView` (`BuiltInSlotViews.swift:362-374`) not finding a
  matching `PluginViewSection` in `host.pluginViews`.
- Operator confirmed via AskUserQuestion: not one stuck pane — "chỉ work một vài lần, sau đó lỗi
  hoàn toàn" (works a few times, then breaks completely, every pane including new ones) —
  matching `BundledPluginRuntimeActor.phase` flipping to `.failed` permanently. Once `.failed`,
  every future `openViewInstance` throws `runtimeStopped` immediately (`BundledPluginRuntime.swift:588`)
  — bundled-swift plugins have no hot-reload path to self-heal, so it's stuck until app restart.
- Confirmed mechanism by log capture in a test harness: `dev.tenon.file-explorer: compiled
  callback mailbox exceeded 256 entries` — `failForCallbackOverflow`
  (`BundledPluginRuntime.swift:513-522`), not a thrown error (traced every `throw` reachable from
  `FileExplorerPlugin`'s own callback code — none fire under normal conditions).
- Root of the overflow: `"workspace.changed"` fires on *every* workspace mutation anywhere in the
  app (`WorkspaceStore.swift:424-439`), and the old handler paid one `owningWorkspace` intent
  round trip per open File Explorer pane on every single firing, unconditionally — a
  pre-existing characteristic inherited unchanged from the JS predecessor (`git show
  1a958bf~1:plugins/file-explorer/main.js`, comment: "Owners that did not change cause no work
  and no render" — true for the render, not for the round trip itself). With several panes open
  and a sustained burst of workspace churn, that unbroken run of round trips was slow enough to
  let the mailbox's 256-slot buffer fill faster than the pump could drain it.
- Verified NOT reproducible from pane-open volume alone (60 concurrent opens, zero latency) or
  from realistic pacing at 6 panes (100 events/2ms-stagger, 3ms latency); reproducible at
  20 panes / 5ms simulated intent latency / 300 `"workspace.changed"` firings spread over
  ~300ms (~1/ms) — a plausible "several panes open, sustained active-workspace churn for a
  third of a second" scenario, not a synthetic instantaneous hammer. A single fully-simultaneous
  300-way burst (all enqueued before the pump can dequeue even one) still overflows regardless of
  fix, matching the JS runtime's identical bounded-mailbox design (`PluginRuntime.swift:181-190`)
  — not the trigger this task targets.

## Fix, round 1 (session `6ce82b`/`tenon-33`, kept — real, still needed)
`FileExplorerPlugin.swift`'s `"workspace.changed"` case now calls
`scheduleWorkspaceOwnershipRecheck(context:)`, which debounces (250 ms, same shape as the
existing `KanbanPlugin.debouncedRefresh` precedent) instead of doing the full per-pane
`owningWorkspace` pass on every firing. A burst of any size collapses into at most one deferred
pass; the deferred pass (`recheckWorkspaceOwnership`) still re-verifies every pane, fanning the
independent round trips out concurrently via `withTaskGroup` rather than sequentially, and
publishes its own contribution (`context.publishContribution`) since a timer-fired callback
doesn't auto-publish. Correctness preserved: a pane's owner still gets re-verified and its root
still retargets exactly as before, just deferred up to 250 ms instead of immediate. This bounds
how *often* the expensive pass runs — it does not, on its own, bound how many mailbox slots a
burst of raw firings consumes before the pump gets a single turn to dequeue and debounce the
first one (see round 2).

## Addendum — round 1 was verified incomplete, this session, 2026-08-18 15:2x
Independent re-verification: `swift test --filter FileExplorerPluginTests`, run before this
session touched anything, showed `testBurstOfWorkspaceEventsAgainstSeveralOpenPanesNeverFailsTheRuntime`
(300 concurrent `deliverEvent` calls via `withTaskGroup`, no stagger — the test as actually
committed, not the staggered "20 panes / 5 ms / spread over 300 ms" scenario round 1's notes
above describe) still **red** at `("failed") is not equal to ("active")` against round 1's fix
alone. Diagnosed with `tenon-33` (round 1's author) live over cross-session messages before
landing round 2; they independently confirmed the diagnosis and reviewed round 2's diff after
the fact (see round 3).

## Fix, round 2 — mailbox-level coalescing (this session)
`BundledPluginCallbackMailbox` (`BundledPluginRuntime.swift`) gained the same coalescing shape
`PluginRuntimeCallbackMailbox` (`PluginRuntimeBridge.swift:336`, the JS-plugin mailbox) already
had for repeating timer ticks — widened from one timer handle to a program-declared event name.
`BundledPluginProgram.coalescableEvents` (new field, default `[]`) lets a compiled program name
subscribed events whose payload it never needs more than the newest firing of. While an instance
of a coalescable event is enqueued-but-not-yet-consumed, every repeat firing coalesces into it
instead of taking its own slot — a burst of `N` firings of that event costs one mailbox slot, not
`N`. All five bundled plugins subscribed to `"workspace.changed"` now declare it coalescable —
`FileExplorerPlugin`, `ClaudeSessionsPlugin` (the operator's "session agent" report), `GitPlugin`,
`KanbanPlugin`, `WorkspaceStatusPlugin` — confirmed by `grep '"workspace.changed"' Sources/`, all
five discard or don't need the specific payload of a given firing (`WorkspaceStatusPlugin` may
render a status-bar count one burst stale — never permanently). Deliberately **not** applied to
`pane.cwd-changed`/`workspace.slot-focused`: their handlers read a specific `slotId` from the
payload, so coalescing by name would silently drop a different pane's real update.

## Fix, round 3 — the actual amplification source (this session, after an operator regression report)
After round 2 shipped, the operator restarted the app (a fresh install, rebuilt with round 2) and
reported the *same* "Plugin view unavailable" now appearing on **more** plugins at once (git,
kanban, claude-sessions) — a restart's tab/pane restore is a bigger simultaneous burst than the
gradual "open a few panes" the original report described, and round 2 only closes the hole for
one named event. Root cause of the amplification itself, traced live: `TenonApp.swift:1233`
spawned an unawaited `Task { await host.emit(workspaceEvents: events, in: snapshot) }` on *every*
firing of `WorkspaceStore.onEvents`, with an explicit comment accepting "sibling mutation tasks
are not ordered" as a known tradeoff. `PluginHost.emit` (`PluginHost.swift:1575-1597`) is
reentrant at its own internal `await session.runtime.handles(event:)`, so when `onEvents` fires
in a burst, many concurrent `emit` calls interleave their iterations and race synchronous
`acceptEvent`/mailbox writes into *every* subscribed plugin's own bounded pump at once — for
*any* event type, not only `"workspace.changed"` — fast enough to outrun a plugin's
single-consumer drain regardless of how cheap that plugin's own handling is.

Fixed at that source: `Sources/TenonApp/WorkspaceEventBroadcastPump.swift` (new) is a FIFO queue
with exactly one consumer. `onEvents` now calls `broadcastPump.enqueue(...)` — never suspends,
so the mutation caller is not blocked, matching the original design intent — and the pump's own
`Task` calls `host.emit`/`host.reconcileViewInstances` for one queued item at a time, in order.
No two broadcasts are ever in flight together, so the interleaving that produced the
amplification cannot occur, for any plugin or event. `WorkspaceEventBroadcastPumpTests`
(`Tests/TenonAppStateTests/`) pins both properties directly against the pump type: never more
than one broadcast concurrently (`testNeverRunsTwoBroadcastsConcurrently`), and firing order
preserved under a burst (`testPreservesEnqueueOrderUnderABurst`).

Reviewed live by `tenon-33` after landing (cross-session messages): they read the new file and
flagged its queue as the one place in today's fix that didn't carry an explicit bound — invariant
10 ("every queue... is bounded") and `BundledPluginCallbackMailbox`'s own explicit 256 cap, added
by this same fix, were the standard to match. Addressed: the pump's `AsyncStream` now takes
`.bufferingNewest(1024)` instead of the implicit `.unbounded` default, and a drop logs through
`TenonLog.diagnostics` (`os_log`, fault level) rather than failing silently — 1024 is generous
relative to `PluginHost.emit`'s actual per-item cost (a `Set.contains` check per plugin plus a
synchronous mailbox write, low milliseconds for ~10 plugins), so hitting it in practice would
mean the drain side is genuinely stuck, a different bug this backstop makes visible rather than
silently exhausting memory over.

## Fix, round 4 — decoupling reconcile from the broadcast queue (this session, after a live regression report)
After round 3 installed, the operator reported "Plugin view unavailable" still showing on a
freshly opened File Explorer pane, self-resolving after some time rather than staying stuck —
screenshot showed a Kanban pane in the same window had already resolved to its own content in
the same moment. That pattern (self-resolving, other plugins ahead of it) doesn't match `.failed`
(permanent, no self-heal) — it matches ordinary view-activation latency, but round 3 itself had
just made that latency worse: `broadcastPump`'s handler called `host.emit` **and then**
`host.reconcileViewInstances` for each queued item, so a newly opened pane's `openViewInstance`
call (issued from `reconcileViewInstances`) now had to wait behind every other pending broadcast
in the same strict FIFO queue before it could even start. `reconcileViewInstances` never needed
that protection — it already coalesces concurrent callers itself
(`isReconcilingViews`/`needsViewReconcile`, `PluginHost.swift`), so an overlapping call folds
into the pass already running instead of racing writes the way `emit`'s reentrant internal
`await` did. Decoupled: `broadcastPump`'s handler now only calls `host.emit`; `onEvents` fires
`reconcileViewInstances` in its own independent `Task`, same as before round 3, so it starts
immediately regardless of the broadcast queue's depth.

Separately, still true and not a bug: `FileExplorerPlugin.open(instanceID:context:)` pays three
sequential intent round trips per pane (`owningWorkspace`, `installedAgents`, then `render`'s
directory listing) through that plugin's own single-consumer pump — opening several panes close
together means later ones wait out earlier ones' full sequence. That's inherent to the
single-pump-per-generation design (invariant 5/10), pre-existing, and not part of this task's
scope. Operator confirmed after round 4: resolves in **under 1-2 seconds**, "like normal
loading" — within that inherent cost, not the reported bug.

## Fix, round 5 — loading and failure look identical, and that is its own bug (this session, after operator pushback)
Round 4 closed with "resolves in under 1-2 seconds, operator confirmed" treated as good enough.
Operator pushed back, correctly: a plugin view showing an *error-styled* "Plugin view
unavailable" screen (broken-puzzle-piece icon) every single time it opens — even for 1-2
seconds — is not acceptable UX, and is the reason nobody in this thread, including the
operator, could tell a normal load apart from the permanent failure this task started from. The
real defect was never the latency; it was that `PluginSlotView` had exactly one signal — whether
`host.pluginViews` already contained this pane's section — and used it to mean two different
things: "still activating" and "genuinely failed," rendered identically.

Fixed by giving the view a second signal it already had available but wasn't reading:
`host.plugins` (`[PluginSnapshot]`, `PluginHost.swift`) already carries `isLoaded`, `isEnabled`,
and `error` per plugin, computed independently of whether any specific view section has
published yet. `PluginViewAvailability.resolve(pluginID:hasSection:plugins:)`
(`BuiltInSlotViews.swift`, new, pure, TDD red-then-green — `PluginViewAvailabilityTests` 6/6)
turns that into three states: `.ready` (render normally), `.activating` (loaded, enabled, no
error, section just not published yet — show a small `ProgressView` spinner, not an error),
`.unavailable(reason:)` (not loaded / disabled / missing / carries an error — the existing error
UI, now also surfacing the actual diagnostic string instead of only the plugin/view id when one
exists). `PluginSlotView`'s `else` branch switches on this instead of unconditionally showing
the error state.

## Fix, round 6 — a genuinely different startup race (this session, after operator pushback led to reading the live app log directly)
Operator reported the spinner-vs-error split (round 5) didn't remove the error state itself:
"cứ một vài lần xong lại lỗi" (recurring across restarts, not permanent). Read
`log show --predicate 'process == "Tenon"'` directly against the running app instead of
theorizing further, and found the actual mechanism: `host: open view failed for
dev.tenon.claude-sessions: plugin runtime is stopped` / `git: polling timer unavailable: plugin
runtime is stopped`, logged right before each launch's `host: activated ...` sequence. Across
four consecutive launches, `dev.tenon.file-explorer`'s session number was consistently **one
higher** than its sibling bundled plugins' (62 vs. 61, 61 vs. 60, ...) — a real, repeatable
pattern, not noise, meaning something re-activates file-explorer specifically shortly after the
main batch commits (root cause of *that* not fully traced — `rootPath`'s per-installation
setting write on the restored pane is the leading suspect, not confirmed).

`TenonApp.swift:1133-1136` already documented the resulting gap in a comment: "reconcile
otherwise runs only from workspace mutations, and a launch that restores panes performs none —
every restored plugin pane would sit on 'Plugin view unavailable' until the first unrelated
workspace change." A plugin activating a beat after `performStart`'s one startup reconcile has
already run falls in exactly that gap — nothing retried its pane's `openViewInstance`.
`host.onPluginLifecycleChanged` (`PluginHost.swift`) already fires on every phase transition
`publish()` observes, including a late activation, but its handler (`TenonApp.swift`) only
reconciled web surfaces and automation schedules, never plugin view instances. Fixed: it now
also calls `host.reconcileViewInstances(from: store.catalog)`, matching the existing pattern
already used for `store.onEvents`. `reconcileViewInstances` self-coalesces concurrent callers
(`isReconcilingViews`/`needsViewReconcile`), so this costs nothing extra when nothing is
pending.

Live-verified against the rebuilt app across multiple restarts (operator): no more error-icon
state at all, only the round-5 loading spinner resolving to content. Confidence: **the retry
mechanism is verified working; the exact reason file-explorer activates a beat late is not
fully traced** — the fix closes the class of bug (late activation + no retry) regardless of
which plugin or setting triggers the lateness, so it should hold even if the specific trigger
turns out to be something other than the `rootPath` write.

## Deliberately out of scope (not silently dropped)
- **Self-heal for a `.failed` generation.** `PluginHost.accept()` (`PluginHost.swift:2146-2163`)
  tears a failed session down completely (`retireFailedSession`) on *any* cause of `.failed`, not
  only overflow, and never restages it — true for JS runtimes too, but JS plugins get a manual
  escape hatch (re-saving `main.js` triggers a fresh hot-reload via `PluginWatcher`) that
  bundled-swift plugins structurally cannot have (no file to re-save; every shipped plugin is
  bundled-swift since T-167). Round 3 prevents the amplification that was causing overflow in the
  first place, which is more complete than self-heal alone would have been (prevention vs.
  recovery-after-the-fact) — but it does not make overflow (from some other future cause) safe to
  hit. A real fix would restage a fresh generation on overflow specifically (transient, safe to
  retry) while never auto-retrying a thrown-handler failure (a deterministic bug, where retrying
  loops forever) — needs a structured failure-reason signal on `PluginRuntimeSnapshot` plumbed
  through `PluginHost.accept()`, reusing the existing single-plugin `activate(_:replacingManifestInventory: false)`
  reload pathway (`PluginHost.swift:888`), with a bounded retry count. Deferred: touches
  `PluginHost.swift`'s reload orchestration, a file this repo's own docs already flag as carrying
  five domain tags and needing decomposition, not more complexity, without the operator's
  explicit go-ahead on that scope.
- No dedicated test was added for `ClaudeSessionsPlugin`/`GitPlugin`/`KanbanPlugin`/
  `WorkspaceStatusPlugin` (`GitPluginParseTests.swift` covers git-output parsing only, not
  runtime lifecycle; the other three have zero test files). Round 2's mechanism is exercised
  end-to-end by `FileExplorerPluginTests`' burst test — every bundled plugin shares the identical
  `BundledPluginRuntimeActor`/`BundledPluginCallbackMailbox` machinery, only the declared
  `coalescableEvents` differ per plugin — but a plugin-specific regression in one of these four
  would not be caught by `swift test` today. Flagged, not fixed here.

## Criteria
- [x] Failing test reproduces the permanent `.failed` phase — red first, per TDD
      (`testBurstOfWorkspaceEventsAgainstSeveralOpenPanesNeverFailsTheRuntime`, confirmed red
      against round 1's fix alone before round 2 landed)
- [x] Root cause fixed at its source, not patched around — round 2 fixed the per-plugin mailbox's
      exposure to one coalescable event; round 3 fixed the actual concurrent-amplification source
      the operator's regression report proved round 2 alone didn't reach; no cap was raised as a
      substitute for either
- [x] `swift test` green: scope `FileExplorerPluginTests` 8/8, `WorkspaceEventBroadcastPumpTests`
      2/2, `PluginViewAvailabilityTests` 6/6, full suite **2379 / 0**
- [x] Task file updated with the actual verified root cause, all five rounds, before moving to
      Done
- [x] Operator confirmed live, 2026-08-18 17:4x, against the round-4 build: no more
      indefinite/permanent stuck state, resolves within the inherent pane-open latency.
      **Operator then correctly rejected "latency is fine" as the closing bar** — an
      error-styled screen on every normal load is itself the defect this task should close on,
      not a tolerable side effect. Round 5 addresses that.
- [ ] **Owed**: operator to confirm the round-5 build (rebuilt and installed, `open
      "/Applications/Tenon.app"`) shows a loading spinner — not the error screen — while a
      newly opened plugin pane activates.
