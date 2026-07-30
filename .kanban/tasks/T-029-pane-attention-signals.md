# T-029: Attention signals — which pane needs a human, which can wait
> Every pane gets a derived activity state (working / idle / finished-unseen / exited).
> Tabs, pane headers, sidebar rows and the title bar project it; a pane that finishes
> while Tenon is in the background raises a system notification.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
UNCLAIMED — **core half DONE + VERIFIED 00:15, its locks RELEASED** (worker
task_f698353650f8 / ctx_d67bb5e3a191). `PaneActivity.swift`,
`PaneActivityTests.swift` and `IdleDetector.swift` (one additive `Sendable`
conformance) are free. The app half — `SurfacePool.swift`, `ShellTitleBar.swift`,
`SpatialCanvasView.swift`, `WorkspaceSidebarView.swift`, the notification adapter —
remains undone and unclaimed; start from `## Handoff to the app half` below.

Expected files:
- `poc/Sources/TenonCore/PaneActivity.swift` — NEW pure state machine
- `poc/Sources/TenonCore/IdleDetector.swift` — reuse as the idle rule
- `poc/Sources/TenonApp/SurfacePool.swift` — feed `TerminalObservation` into the machine
- `poc/Sources/TenonApp/ShellTitleBar.swift` — chip dot + count of panes needing attention
- `poc/Sources/TenonApp/SpatialCanvasView.swift` — pane header dot
- `poc/Sources/TenonApp/WorkspaceSidebarView.swift` — per-workspace rollup
- NEW notification adapter in `TenonApp` (host-native, typed)
- `poc/Tests/TenonCoreTests/PaneActivityTests.swift` — NEW

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
- [ ] Tab chip, pane header, sidebar workspace row and title bar all project the same one
      state — no second computation of "is this busy" anywhere in the shell
- [ ] The sidebar/tab row stays bold until the pane is actually viewed, and viewing is what
      clears it (not focus of the window, not a timer)
- [ ] A pane reaching finished-unseen while the app is not frontmost raises one system
      notification; activating it focuses that pane. Notifications are coalesced, never one
      per finished command
- [ ] Interaction classification is written down before the code
      (`docs/architecture-interaction-boundaries.md`): pane activity is host-native typed
      state; any plugin visibility is an EVENT, and this task either ships that EVENT or
      states that it does not
- [ ] `swift build` + `swift test` green; launch smoke with a long-running command in one
      pane and a finished one in another, and one human look at the dots
