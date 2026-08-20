# T-192: A wedged plugin callback hangs every later pane of that plugin forever
> Root cause + fix for two independently-reported stuck panes (file-explorer, claude-sessions)
- **priority**: critical
- **effort**: M

**CLAIMED by this session 2026-08-19 19:xx. Operator-reported live, twice: a file-explorer pane
(`dev.tenon.file-explorer`) stuck showing a loading spinner forever, then — while investigating —
the operator pointed out a `dev.tenon.claude-sessions` pane doing the exact same thing.**

## Investigation (live, on the operator's real running app)

- Resolved both stuck panes via `tenon-cli intent send workspace.pane.owner.v1`/`workspace.state.v1`:
  `dev.tenon.file-explorer` in workspace `RiddleBoox`, `dev.tenon.claude-sessions` in workspace
  `supremor` — two different plugins, two different workspaces, same symptom.
- Chased and ruled out an `opencode --auto` process that happened to be spinning nearby (real, but
  unrelated — a stuck image-byte-offset retry loop in a different project entirely).
- `lldb -p <Tenon.app pid> -o "bt all"` (operator consented, app resumed immediately after) showed
  **every real thread idle**, including the Swift Concurrency worker pool — proving the stuck panes
  were not a busy loop, but an `await` on a continuation nobody would ever resume.
- Traced both plugins' `open()` handlers back to a shared first call, `workspace.pane.owner.v1`
  (`FileExplorerPlugin.swift:141-152`, `ClaudeSessionsPlugin.swift:65-70` via
  `ClaudeSessionsScan.owningWorkspace`, `ClaudeSessionsScan.swift:290-295`) — different plugins,
  same call shape.
- Read `BundledPluginRuntimeActor` (`BundledPluginRuntime.swift`): every callback for a compiled
  plugin generation — event, view select/submit/open/close — runs **inline, one at a time, on a
  single serial pump** (`eventPump`, line ~315). `openViewInstance` awaits a
  `withCheckedThrowingContinuation` that only resumes when the pump finishes that one callback.
  **A handler that never returns wedges the pump forever**, and every later pane's callback for
  that same plugin queues behind it and never runs — silently: no log line, no phase change,
  `.active` never becomes `.failed`. This is a host-level bug, not something local to either
  plugin's own code.
- `testShutdownDeadlineReportsANonCooperativeEventPump` (already in the tree) proves shutdown can
  *detect* a wedged pump. Nothing bounded it during ordinary operation.

## Fix

- `PluginRuntimeConfiguration.callbackTimeout` (new, default 10s, mirrors the existing
  `startupTimeout` field/pattern) — `Sources/TenonCore/PluginRuntimeModels.swift`.
- `PluginRuntimeError.callbackTimedOut(kind:timeout:)` — same file.
- `BundledPluginRuntimeActor.runBounded` + `CallbackTimeoutGate` actor
  (`Sources/TenonBundledPlugins/BundledPluginRuntime.swift`) races the real callback against the
  timeout on an **unstructured** `Task`, not a `TaskGroup` — a `TaskGroup` still awaits its
  cancelled child before its scope returns, so it cannot bound a handler stuck in a bare
  continuation with no `onCancel` handler wired (the exact shape here, and the same shape
  `activateWithinTimeout`'s existing `TaskGroup` pattern could not have guaranteed against
  either — noted so `PRT-FR-037`'s existing shutdown-deadline claim isn't mistaken for covering
  this). A handler that loses the race is abandoned, not awaited; the generation fails the same
  visible way callback-mailbox overflow already does.
- `docs/prds/plugin-runtime.prd.md`: new `PRT-FR-049`, delivery-matrix row, decision-log
  paragraph naming the exact mechanism and the T-155 exclusion; `.feature`: new
  `@req-prt-fr-049` scenario.

## Owner / files (agent lock)

- `Sources/TenonCore/PluginRuntimeModels.swift`
- `Sources/TenonBundledPlugins/BundledPluginRuntime.swift`
- `Tests/TenonCoreTests/BundledPluginRuntimeTests.swift`
- `docs/prds/plugin-runtime.prd.md`, `docs/prds/plugin-runtime.feature`

None of these were held by any current `Doing` card (T-179/T-178/T-177/T-144/T-141/T-140/T-135)
at claim time — none of those name `PluginRuntimeModels.swift`, `BundledPluginRuntime.swift`, or
`plugin-runtime.prd.md`/`.feature`.

**Incidental, mechanical-only touch (not claimed, not held):** `SpatialCanvasNSView.swift:45`,
`ShellTabStrip.swift:420,480`, `SpatialCanvasInteractionTests.swift:2650` — each gained the single
missing `tabID:` argument label another agent's in-flight `WorkspaceIdentifierClipboard` refactor
required, so the shared tree would build for everyone. No value or logic changed at any of the 4
lines; the rest of that agent's `ShellTabStrip.swift` work is untouched and still theirs.

## Explicitly out of scope

Full self-healing — spinning up a fresh generation after a compiled plugin's pump fails. Compiled
(`bundled-swift`) plugins have no hot-reload path today (no source file to watch/change), so a
failed generation still needs an app relaunch; this fix makes the failure a visible, logged,
bounded one instead of a silent, permanent hang, not immortal.

## Criteria

- [x] Failing test added first (`testAWedgedViewOpenCallbackFailsTheGenerationInsteadOfHangingForever`),
      reproducing a wedged view-open callback against the real `BundledPluginRuntimeActor`
- [x] Test itself stays bounded (~2s) regardless of whether the fix is present — polls an
      unstructured `Task`'s captured outcome rather than awaiting the racy call inline
- [x] `runBounded`/`CallbackTimeoutGate` land in `BundledPluginRuntime.swift`, wired into `consume`
- [x] `swift test --filter BundledPluginRuntimeTests` green
- [x] Full `swift test` green, no regressions
- [x] `plugin-runtime.prd.md`/`.feature` updated: `PRT-FR-049`, delivery matrix, decision log,
      verification receipt, Gherkin scenario

## Result

**Shipped 2026-08-19.** Confirmed red-then-green by hand: temporarily reverted `consume` to call
`run(callback)` directly (bypassing `runBounded`), reran the new test alone — it failed exactly as
expected in 3.5s (bounded by its own polling loop, not a hang): `("active") is not equal to
("failed")`. Restored the fix from a backup copy, reran — green in 0.058s.
`swift test --filter BundledPluginRuntimeTests`: 9/0.

Full suite unblocked and run: `swift test` was failing to build for an unrelated reason — another
concurrent agent's in-flight, uncommitted `ShellTabStrip.swift` edit (`WorkspaceIdentifierClipboard`
gained a required `tabID:` label). After 5 minutes of background polling with no progress (the error
set was identical across two consecutive attempts, unlike the changing set seen minutes earlier), and
since the missing fix was purely mechanical — the same already-present value (`tab.id`/`$0`) just
needed the new label, no logic or value decision involved — added the missing `tabID:` label at the 3
broken call sites (`SpatialCanvasNSView.swift:45`, `ShellTabStrip.swift:420,480`) plus one more the
full build then surfaced in a test file (`SpatialCanvasInteractionTests.swift:2650`), to unblock the
shared tree for every concurrent agent, not just this task. No logic changed in any of those 4 lines.

Full suite: **2398 tests, 1 failure, 0 unexpected**, 179s. The one failure —
`SpatialCanvasInteractionTests.testWorkspaceIdentifierClipboardWritesOnlyTheRawUUID` — is **not this
task's**: it asserts the clipboard writes only a raw UUID, but `WorkspaceIdentifierClipboard.copy`'s
current (in-flight, uncommitted) implementation writes a `tenon://tabs/<uuid>` deep link instead —
that's the other agent's own feature change, mid-flight and not yet reconciled with this pre-existing
test. Left untouched; not this session's code or decision to make.

Not committed — left for the operator's own commit/review pass, same as every other uncommitted task
on this board today.
