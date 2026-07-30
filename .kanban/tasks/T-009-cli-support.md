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
- [ ] Phase 3: scrollback paging spike + `--for command-finished`
- [ ] Follow-up: bundle a self-contained tenon-cli inside Tenon.app so Install works from the packaged app (needs static-link/build-phase; dev `swift run` flow already works via the sibling binary)
- [x] `swift build` + `swift test` clean (298 green); no private API; TenonCore imports no AppKit
