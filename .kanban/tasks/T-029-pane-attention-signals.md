# T-029: Attention signals — which pane needs a human, which can wait
> Every pane gets a derived activity state (working / idle / finished-unseen / exited).
> Tabs, pane headers, sidebar rows and the title bar project it; a pane that finishes
> while Tenon is in the background raises a system notification.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
UNCLAIMED. Touches the tab bar and canvas, which T-022 / T-025 / T-026 have all been in —
read `Doing` and take the released ones only.

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

## Criteria
- [ ] `PaneActivity` is a pure state machine over terminal observations + a clock: working
      → idle → finished-unseen → seen, plus exited. Every transition asserted in
      `TenonCoreTests` without a window, including the unseen flag clearing on view
- [ ] "Finished" is derived from real signals (`commandFinishedCount`, `processExited`,
      `IdleDetector` streak), never from parsing agent-specific output strings
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
