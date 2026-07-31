# T-009: CLI support (agent-first remote control)

> A local socket + `tenon-cli` binary so a human or an AI agent can drive the running
> app: run commands, read workspace state, and send/read/wait on terminal panes.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
session 06fee824 — ACTIVE (user confirmed full scope Phase 0+1+2, 2026-07-24).

**Phase 0 (NOW — pure TenonCore, zero collision, `swift test`-able even while TenonApp is red):**
- poc/Sources/TenonCore/CLIProtocol.swift (envelope + newline-JSON framing + 1MB cap)
- poc/Sources/TenonCore/CLIAction.swift (verb vocabulary + parser)
- poc/Sources/TenonCore/CommandResolution.swift (command-id → PluginCommand, exact/bare/fuzzy)
- poc/Sources/TenonCore/PaneTarget.swift (pane selector → validated terminal slot UUID)
- poc/Tests/TenonCoreTests/{CLIProtocolTests,CLIActionParserTests,CommandResolutionTests,PaneTargetTests}.swift

**Phase 1 (after Phase 0 — new TenonApp files + additive edits to UNCLAIMED files):**
- NEW: poc/Sources/TenonApp/{CLISocketServer,CLICommandExecutor,TerminalIdleWatcher,CLIStateSnapshot}.swift
- NEW target: poc/Sources/TenonCLI/** + poc/Package.swift (add `tenon-cli` product/target)
- EDIT (currently unclaimed): poc/Sources/TenonApp/{TerminalSurface,SurfacePool,GhosttySurface}.swift
- EDIT (re-read board first — TenonApp.swift is hot): poc/Sources/TenonApp/TenonApp.swift (wire cliServer, pool closure)

**Phase 2 (COORDINATION-GATED — blocked on T-005 releasing these):**
- ⚠️ poc/Sources/TenonCore/PluginRuntime.swift — CLAIMED by T-005 (installAPI). Needs `workspace.control` +nextTab/prevTab/focusNextSlot/switchWorkspace. WAIT for release.
- ⚠️ poc/Sources/TenonCore/PluginHost.swift — CLAIMED by T-005. Needs WorkspaceCommand +4 cases.
- poc/Sources/TenonApp/TenonApp.swift — onWorkspaceCommand +4 arms.
- poc/plugins/core-commands/main.js — +next-tab/prev-tab/focus-next-slot + dynamic switch-workspace.<uuid>.
- Tests: CoreCommandsPluginTests, ShippedPluginsTests, PluginCapabilityTests (blocked+allowed pairs).

**Phase 3 (independent native spike):** `read --cursor` scrollback paging, push-idle, `wait --for command-finished` (OSC 133).

## Status
Phase 0 in progress. Design: docs/design-cli.md. References studied: supacode (Swift CLI/socket template),
muxy (wire framing + security model), orca (agent-first verb UX). Feasibility de-risked: ghostty
`read_cells`/`read_text`/`process_exited` + existing `GhosttySurface.renderedText` prove read/wait buildable.

## Criteria
- [x] Phase 0: CLIProtocol/CLIAction/CommandResolution/PaneTarget pure, headless tests green
- [x] Phase 1: socket server + tenon-cli + env injection; `run <cmd>`, `state`, `send`, `read`, `wait exit|tui-idle`, `focus` work end-to-end
- [x] Phase 2: core-commands extended (next-tab/prev-tab/focus-next-slot/switch-workspace) via one action surface; blocked+allowed capability pairs
- [x] TRUE SINGLETON: LSMultipleInstancesProhibited in Tenon-Info.plist (verified in built .app) + runtime socket-lock
- [x] Settings → CLI → Install: copies self-contained tenon-cli into ~/.local/bin (verified relocatable via otool)
- [x] Phase 3, `--for command-finished`: shipped and now asserted. The OSC 133
      semantic-prompt marker bumps a per-pane count (`GhosttySurface.swift:396-398`),
      `SurfacePool` carries it into the observation, and `terminal.wait.v1` is met when the
      count rises above the one read at wait time (`TerminalIntentProvider.swift:228-270`),
      with an immediate give-up when the process exits without ever finishing a command.
      It had **no test** until 2026-07-31 — see "The coverage this task quoted" below
- [x] Phase 3, remaining items handed to **[T-044](T-044-terminal-scrollback-paging.md)**:
      scrollback paging (`read --cursor`) and push-idle. Neither is built; `terminal.viewport.read.v1`
      still answers the visible screen only
- [x] Follow-up handed to **[T-045](T-045-bundle-tenon-cli-in-the-app.md)**: bundle a
      self-contained `tenon-cli` inside `Tenon.app` so Install works from the packaged app.
      The dev `swift run` flow already works via the sibling binary
- [x] `swift build` + `swift test` clean; no private API; TenonCore imports no AppKit —
      298 green when this task shipped, **756 / 0** at `17bf0a6` on 2026-07-31 after the
      terminal-verb tests were brought inside the suite

## The coverage this task quoted

This task recorded *"`swift build` + `swift test` clean (298 green)"*. That number never
included `TerminalIntentProviderTests` — the only tests of the CLI's terminal verbs — because
`poc/Tests/TenonAppTests/` was never declared in `Package.swift` and `swift test` therefore
never built it. Three of its four files no longer compile at all.

Fixed here: `TerminalIntentProviderTests.swift` moved to `TenonAppStateTests/`, where the
suite runs it, and extended with three `command-finished` cases — met on a rise, ignores
commands that finished before the wait began, and gives up immediately when the shell dies
mid-command. Each is mutation-proven (break the rule → that named assertion goes red →
restore). Full suite **756 / 0** at `17bf0a6`, up from 750: three tests that had never run,
plus the three new ones. The rot left behind in that directory is
**[T-043](T-043-tenonapptests-outside-the-evidence-bar.md)**.
