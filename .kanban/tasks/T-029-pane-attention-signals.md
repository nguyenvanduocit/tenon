# T-029: Attention signals — which pane needs a human, which can wait
> Every pane gets a derived activity state (working / idle / finished-unseen / exited).
> Tabs, pane headers, sidebar rows and the title bar project it; a pane that finishes
> while Tenon is in the background raises a system notification.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
UNCLAIMED — **app half DONE + VERIFIED 01:01, ALL LOCKS RELEASED** (worker
task_f3b0bcbc0314 / ctx_16c18958daa7). Every file below is free again:
`SurfacePool.swift`, `ShellTitleBar.swift`, `SpatialCanvasView.swift`,
`WorkspaceSidebarView.swift`, `WorkspaceStageView.swift`, `ContentView.swift`,
`TenonApp.swift`, NEW `PaneAttentionProjection.swift` + `PaneAttentionNotifier.swift`
+ `Tests/TenonAppStateTests/PaneAttentionTests.swift`, and the
`docs/architecture-interaction-boundaries.md` DIRECT-inventory note. Not committed.

Expected files:
- `Sources/TenonCore/PaneActivity.swift` — NEW pure state machine
- `Sources/TenonCore/IdleDetector.swift` — reuse as the idle rule
- `Sources/TenonApp/SurfacePool.swift` — feed `TerminalObservation` into the machine
- `Sources/TenonApp/ShellTitleBar.swift` — chip dot + count of panes needing attention
- `Sources/TenonApp/SpatialCanvasView.swift` — pane header dot
- `Sources/TenonApp/WorkspaceSidebarView.swift` — per-workspace rollup
- NEW notification adapter in `TenonApp` (host-native, typed)
- `Tests/TenonCoreTests/PaneActivityTests.swift` — NEW

## Why / evidence
- VISION's second product test is directing scarce human attention. Today nothing on
  screen answers "which of my agents needs me". `Sources/TenonCore/IdleDetector.swift`
  exists but serves only `terminal.wait.v1` with `tui-idle` — it feeds no surface. (HIGH)
- `SurfacePool.swift` already observes what the machine needs: `TerminalObservation` has
  `text`, `processExited`, `commandFinishedCount` (`SurfacePool.swift:6-12`). (HIGH)
- Orca 1.3.41: sidebar agent rows with colored status dots (yellow working, green done) +
  timestamps, **rows stay bold until viewed**. 1.1.21: working/idle in the titlebar plus
  completion notifications for Pi and OpenCode. 1.1.15: active agent count in the top bar.
- Kero ships desktop notifications for background processes. Tenon's only notification
  today is an intent described as *"Shows a bounded in-app notification"*
  (`CoreIntentCatalog.swift:1181`) — useless precisely when the user is in another app.
- Bold-until-viewed is the cheapest correct primitive here: it encodes "has a human looked
  at this yet", which is the actual supervision question.

## Handoff to the app half

The core half shipped the whole rule; the app half is adapters and projection only
(docs/tdd.md — the shell decides nothing). Everything below names the exact seam.

**What you feed in.** One `PaneActivity` per slot UUID, owned beside `titles`/
`directories` in the app shell and dropped when `retainOnly` drops the slot. Two
mutations, both taking the clock as a parameter — never call `Date()` inside the
machine's callers without passing it through:
- `pane.observe(PaneActivity.Observation(text:processExited:commandFinishedCount:), at: now)`
  — map `SurfacePool.TerminalObservation` onto it by dropping `columns`/`rows`. Feed it
  on a **fixed-interval poll per live pane** (the same cadence `terminal.wait.v1`'s loop
  uses): the embedded `IdleDetector(stableSamples: 3)` counts *consecutive identical
  polls*, so an event-driven feed would never see two identical samples and never go idle.
- `pane.setViewed(_:at:)` — the **viewed rule, decided here, implement exactly this**:
  a pane is viewed while (a) the app is active/frontmost, (b) its workspace is the
  selected workspace, and (c) the pane is actually displayed on the canvas (for a
  stacked pane: it is the active card). Window focus alone must NOT set it, workspace
  selection alone must NOT set it for panes hidden in stacks, and no timer ever sets
  it — `testAPaneTheHumanNeverViewedNeverSilentlyClears` is the assertion that backs
  this. Call `setViewed(true)` on every transition into that condition and
  `setViewed(false)` on every transition out (unviewing is asserted to change nothing).

**What you get back.** Read `state` (`working / idle / finishedUnseen / seen /
exited`), `isUnseen` (the bold-until-viewed bit — orthogonal to `state`: a pane can be
`working` and still bold), `stateSince` and `lastFinishedAt` (for row timestamps).
Each mutation returns `[PaneActivityEvent]`; empty means nothing changed, so the
observation poll is cheap to run against an @Observable store without thrash.

**Where each surface reads it** (one machine, zero second computations of "busy"):
- Tab chip (`ShellTitleBar` tab strip): per-slot `state` dot; **bold title while
  `isUnseen`**.
- Pane header (`SpatialCanvasView`): the same per-slot `state` dot.
- Sidebar workspace row (`WorkspaceSidebarView`): rollup = bold + count of slots in
  that workspace with `isUnseen`.
- Title bar count (`ShellTitleBar`): total slots with `isUnseen` across the catalog.
- Notification adapter (NEW, host-native typed): trigger on the `.becameUnseen`
  event **only while the app is not frontmost** — it fires exactly once per
  needs-attention episode (a second finish while already bold emits nothing), which is
  the coalescing primitive; coalesce further across panes into one notification if
  several fire in a burst. Activation focuses the pane, which makes it viewed, which
  clears the bold — no separate clearing path.

**Boundary decisions already made, do not re-decide:** finished-unseen means "the
finish counter rose while unviewed" — quiet stability never bolds; an exit keeps its
unseen flag (crash still needs a human) and viewing an exited pane clears the bold but
the state stays `exited`; exited is terminal against every later observation; counter
resets/first observations rebaseline without bolding. Interaction classification:
pane activity is **host-native typed state, consumed same-owner DIRECT** by the shell
surfaces above; **no plugin EVENT ships with this task** — if a plugin ever needs
visibility, that is a new classified EVENT through the law, not a reuse of this state.
The app half should record that classification in
`docs/architecture-interaction-boundaries.md` before wiring (criterion 6).

## App-half verification (worker task_f3b0bcbc0314, 00:38–)

**Seam decisions taken (inside the handoff's frame, nothing re-decided):**
- **Feed cadence**: fixed 200 ms / 20 ms tolerance — the exact numbers from
  `terminal.wait.v1`'s loop (`TerminalIntentProvider.swift:281,287`) — driven by
  `AppComposition.startAttentionPolling()` (a `ContinuousClock` task started in
  `performStart`, cancelled in `stop`). `Date()` is supplied only at that imperative
  edge; `SurfacePool.pollActivity(at:)` and `applyViewed(_:at:)` take time as a
  parameter and are fully deterministic in tests.
- **Displayed set** (condition c): the selected workspace's ACTIVE TAB renders all of
  its panes at once (`WorkspaceStageView` renders exactly `catalog.activeTab`), so
  "displayed on the canvas" = `catalog.activeTab.slots`. A pane in a background tab of
  the selected workspace is the "hidden in a stack" case and is NOT viewed.
- **Viewed projection**: pure `PaneAttentionProjection.viewedSlots(appFrontmost:catalog:)`;
  recomputed on exactly two signals — `NSApplication.did{Become,Resign}ActiveNotification`
  and `store.onEvents` (catalog changes). No timer path exists. The pool diffs the set
  and calls `setViewed` only on enter/leave transitions.
- **Never-materialised pane**: has NO activity entry (`paneAttention[slot] == nil`) —
  no surface means nothing to observe; no observation is invented, no dot renders, and
  it counts zero everywhere. Membership in the viewed set is remembered so the machine
  is born viewed when the surface materialises mid-display.
- **Anti-thrash**: machines live in an `@ObservationIgnored` dict; the observable
  `paneAttention` projection is rewritten only when a machine is born or reports
  events, so the 200 ms poll does not re-render SwiftUI.
- **Notification**: one batch per poll pass (the coalescing unit) →
  `PaneAttentionNotifier` fires only while the app is NOT frontmost, one alert per
  burst. System half `SystemNotificationDelivery` is bundle-gated
  (`UNUserNotificationCenter` needs a real bundle; bare `swift run` degrades to no-op).
  Click → `NSApp.activate` + `store.focusSlot` (cross-workspace, `Workspace.swift:684`)
  → pane becomes viewed → bold clears. No second clearing path.

**Mutation proofs — every rule seen RED then restored (10 tests, 28 red assertions at
the stub stage first, then green 10/10):**
| Mutation | Red assertion |
|---|---|
| viewedSlots drops app-frontmost condition | `testViewed…:48` (background app viewed nothing) |
| viewedSlots returns whole workspace (drops condition c) | `testViewed…:56` (hidden-tab pane included) |
| applyViewed skips both enter/leave transitions | `testAFinishWhileUnviewedBolds…:132,137`, `…Rearms:167`, `testAnExit…:191` |
| retainOnly keeps attention state | `testRetainOnly…:291,296` |
| notifier drops not-frontmost guard | `testNotifier…:249` |
| notifier fires one alert per pane | `testNotifier…:256,267,272` |
| poll feeds event-shaped (always-changing) text | `testPollFeeds…:83` (idle unreachable — the exact silent-failure trap) |
| poll invents observations for surface-less panes | `testANeverMaterialisedPane…:99` (this test proven non-vacuous) |
| becameUnseen delivered per-slot instead of per-pass | `testBecameUnseen…:223,230` |

**Human-verify-only remainder:** the pixels — chip dot + bold, pane-header dot,
sidebar bold+count, title-bar count badge — and the real system notification banner
(needs the installed .app bundle; `swift run` cannot deliver one). Method: long
`sleep 5` in one pane of a background workspace, watch bold appear, view it, watch it
clear; `kill` a shell for the red-dot/exit case.

## Criteria
- [x] `PaneActivity` is a pure state machine over terminal observations + a clock: working
      → idle → finished-unseen → seen, plus exited. Every transition asserted in
      `TenonCoreTests` without a window, including the unseen flag clearing on view
      — `PaneActivityTests` 24/24 (00:15), forbidden transitions asserted too:
      never-viewed never clears, idle never bolds without a finish, exited is
      terminal, new activity does not launder an unseen finish, resets/baselines
      never invent attention
- [x] "Finished" is derived from real signals (`commandFinishedCount`, `processExited`,
      `IdleDetector` streak), never from parsing agent-specific output strings
      — the machine embeds the one `IdleDetector` (`terminal.wait.v1`'s rule, now
      `Sendable`) and reads only the three observation fields; no string parsing exists
- [x] Tab chip, pane header, sidebar workspace row and title bar all project the same one
      state — no second computation of "is this busy" anywhere in the shell
      — every surface reads `SurfacePool.paneAttention` through pure
      `PaneAttentionProjection` rollups (tabState/tabIsUnseen/unseenCount/totalUnseen);
      the only "busy" computation is the core machine itself
- [x] The sidebar/tab row stays bold until the pane is actually viewed, and viewing is what
      clears it (not focus of the window, not a timer)
      — three-condition viewed rule (`viewedSlots`), recomputed only on app-activation
      transitions and catalog events; mutation-proven: dropping condition (a) or (c),
      or the enter/leave transitions, each turned a named assertion red
- [x] A pane reaching finished-unseen while the app is not frontmost raises one system
      notification; activating it focuses that pane. Notifications are coalesced, never one
      per finished command
      — one batch per poll pass → `PaneAttentionNotifier` (not-frontmost gate + one
      alert per burst, both mutation-proven); click → `NSApp.activate` +
      `store.focusSlot` → viewed → bold clears (no second clearing path). CAVEAT: the
      visible banner needs the installed .app — `UNUserNotificationCenter` requires a
      bundle identifier, so bare `swift run` deliberately no-ops delivery
- [x] Interaction classification is written down before the code
      (`docs/architecture-interaction-boundaries.md`): pane activity is host-native typed
      state; any plugin visibility is an EVENT, and this task either ships that EVENT or
      states that it does not
      — recorded in the DIRECT inventory (~line 198) BEFORE wiring: same-owner DIRECT,
      NO plugin EVENT ships with this task; future plugin visibility = new classified
      EVENT through the law
- [x] `swift build` + `swift test` green; launch smoke — build exit 0 (warnings-as-errors
      ON), full suite **750/750, 0 failures**, re-measured on the committed tree at
      `17bf0a6` (2026-07-31 02:51) after the app half landed at `1af0192`; launch smoke
      alive 8 s on a private socket, empty log; `PaneAttentionTests` 10/10
- [ ] **Human-verify-only** — run a long command in one pane and a finished one in another,
      then look at the dots / bold / badge; and the system banner from the installed `.app`
      (`UNUserNotificationCenter` needs a bundle id, so bare `swift run` no-ops by design).
      Tracked as item 12 of `.kanban/reports/human-verification-checklist.md`
