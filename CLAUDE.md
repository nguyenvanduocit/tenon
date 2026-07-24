# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tenon — a native macOS terminal workspace where every feature is a plugin, even the bundled ones. Pre-alpha; Phase 0 (plugin-host spike) is complete. **VISION.md is the north-star document — consult it before any architectural decision.**

- `poc/` — Phase 0 spike: Swift package proving the plugin loop (host + manifest + hot reload + plugins driving UI).
- `docs/research-plugin-runtimes.md` — research base for all runtime/sandboxing/permission decisions. Written under the project's former name "Tessera"; it is about this project.
- `docs/naming.md` — naming decision record. If a new name is ever needed for anything public (packages, orgs, domains), run the sweep battery there before proposing.

## Commands

All commands run from `poc/`:

```bash
./scripts/setup-ghosttykit.sh   # once per clone: downloads the pinned GhosttyKit.xcframework (~130 MB)
swift run tenon-poc     # build + launch the app (opens a window; needs a GUI session)
swift test              # headless test suite, ~1s — the evidence bar for the PoC
swift test --filter testEditingTheClockPluginOnDiskHotReloadsIt   # single test by name
swift build             # compile check only
```

Environment variables: `TENON_STUB_TERMINAL=1` (stub terminal pane, no PTY — plugin loop unchanged), `TENON_PLUGINS_DIR=/path` (point the host at a different plugin folder).

No lint/format configuration exists yet.

## Architecture

**TDD is the working method here — read `docs/tdd.md` before adding a feature.** The loop: failing core test first, minimal core change to green, only then the shell, then a launch smoke check. The fitness test for any design: "can this rule be asserted in `TenonCoreTests` without a window?" If not, the rule is in the wrong layer.

Two Swift targets with a hard boundary:

- **`TenonCore`** (`poc/Sources/TenonCore/`) — every rule, deliberately free of AppKit/SwiftUI so everything is testable without a window server. The workspace: `Workspace` (tabs/splits/panes as pure values; every mutation returns `[WorkspaceEvent]`, empty means nothing changed) + `WorkspaceStore` (observable shell + the workspace→plugin event bridge). The plugin host: `PluginManifest` (parsing, discovery, known-permission list, settings schema) → `PluginRuntime` (one JavaScriptCore `JSContext` per plugin; builds the `tenon` API object — v0.2: statusBar/commands/events/log/sidebar/settings/storage/workspace free tier + gated fs/process/terminal.write/workspace.control; the permission gate) → `PluginHost` (owns all runtimes, enable/disable, settings + storage stores, aggregation incl. sidebar sections, reload) → `PluginWatcher` (recursive FSEvents watch, debounced). `SettingsStore`/`PluginStorage` persist to dot-prefixed JSON files in the plugins root.
- **`TenonApp`** (`poc/Sources/TenonApp/`) — the SwiftUI shell: projections of core state, no rules of its own. `SurfacePool` maps pane IDs to terminal surfaces (the core only ever sees UUIDs) and owns per-pane titles; `ContentView` renders tab bar + split tree + sidebar; `TenonApp` does all the wiring and menu shortcuts. `TerminalSurface` (`TerminalSurface.swift`) is the protocol seam hiding the terminal backend: `GhosttySurface` (libghostty) is the live backend, `StubTerminalSurface` covers PTY-less runs. ghostty's own keybindings (super+t, super+d, goto_split) are routed back into the workspace via the action callback in `GhosttySurface.swift` — they cannot be handled as menu shortcuts because `performKeyEquivalent` hands them to the surface first.
- **`GhosttyKit`** (`poc/GhosttyKit/`) — thin C shim over the prebuilt `GhosttyKit.xcframework`, consumed exactly the way Muxy consumes it (research doc §1.1): `scripts/setup-ghosttykit.sh` downloads a pinned dated release of the `muxy-app/ghostty` soft fork (Tenon's own fork pipeline is the Phase 0.5 deliverable), syncs `ghostty.h` out of it, and `Package.swift` links `ghostty-internal.a` via `.unsafeFlags`. Zig never runs in this repo. The xcframework, header, and resources are gitignored — only the script and the modulemap are committed. The embedding itself lives in `GhosttySurface.swift`: one process-wide `ghostty_app_t`, one `ghostty_surface_t` per view, `GHOSTTY_ACTION_SET_TITLE` bridged to `onTitleChange`.

A plugin is a directory under `poc/plugins/`: `manifest.json` (name, version, permissions) + `main.js`. Hot reload is deliberately whole-plugin: any file change drops that plugin's `PluginRuntime` (destroying its `JSContext` and every JSValue it handed the host), then rebuilds from disk. State loss across reload is intentional and asserted by tests. Plugins can be disabled/enabled per-plugin via `PluginHost.setEnabled(_:pluginNamed:)`: disable destroys the runtime but keeps the plugin listed for re-enabling, and the choice persists in `.disabled.json` inside the plugins root (dot-prefixed, so discovery and the watcher ignore it) across restarts.

## Invariants — tests enforce these; do not weaken them

1. **Plugins see only the `tenon` global.** `console` is explicitly deleted; `require`, `setTimeout`, `fetch` were never there. `testPluginsSeeOnlyTheTenonGlobal` fails if anything else leaks into plugin scope. A new capability means a new member on `tenon`, never a new global.
2. **Plugins never touch a terminal type.** Terminal state reaches plugins only as `tenon` events (`terminal.title-changed` today). New terminal-visible surface goes into both `TerminalSurface` and the `tenon` API — never by handing plugins the terminal object.
3. **`TenonCore` imports no AppKit or SwiftUI.** UI concerns live in `TenonApp` only.
4. **A broken plugin never takes down the host** (`testBrokenPluginIsReportedAndDoesNotKillHost`). It is logged, marked failed, and reloads itself when fixed.
5. **The permission gate has exactly one home: `PluginRuntime.installAPI`.** The policy is VISION principle 5: UI contribution (statusBar, commands, sidebar), generic event subscription, logging, settings, and storage are permission-free; permissions exist only for sensitive capabilities — exactly six: `terminal.read` (terminal.* event topics), `terminal.write`, `filesystem.read`, `filesystem.write`, `process.exec`, `workspace.control`. Every gated call goes through `requirePermission(_:api:)`; blocked calls no-op with `{ok: false, error}` plus a ⛔ log naming the manifest fix and surface as `permissionViolations` on the plugin's snapshot — they never throw, so one undeclared capability can't kill the rest of the plugin. Every capability keeps a blocked+allowed test pair (`PluginCapabilityTests`, `PluginPlatformTests`). Future capabilities (network allowlists, path scoping, consent, audit) land in the same function.
6. **No private API — ever.** Bundled plugins compile against the same public surface third-party plugins get. This is the founding principle (VISION.md): any host↔plugin channel that a shipped plugin uses but the public API doesn't expose is the one architectural sin in this project.

## Design tenets that shape API review

From VISION.md, the two that most often decide whether a change is right:

- **AI-writable.** Every plugin API decision passes the test: can a language model read the docs and write a working plugin on the first try? One async API shape on every surface; load-time errors with suggestions, never silent `undefined`.
- **Replaceable everything.** Any bundled plugin can be disabled or replaced and the app keeps working. The empty shell must remain a valid state.

## Verification

The GUI cannot be screenshotted from a headless shell, so `swift build` + `swift test` are the evidence bar. `ShippedPluginsTests` copies the real `plugins/` directory into a temp dir and exercises the actual shipped `clock` and `hello-palette` JS — including a genuine on-disk edit that must propagate through FSEvents into host state. When you change plugin-host behavior, extend those tests rather than relying on manual app runs.

<!-- kanban:start -->
## Task Board

!`bash .kanban/status.sh 2>/dev/null`

Board: `.kanban/board.md` (index) | Tasks: `.kanban/tasks/T-NNN-slug.md` | Archive: `.kanban/archive/`

**Session start:** Read `.kanban/board.md`. For Doing tasks, open their task files.
**Session end:** Update `.kanban/board.md` — move completed task lines to Done, note blockers, update timestamp.

**Board line format** (one per task):
```
- [T-NNN](tasks/T-NNN-slug.md) Title — priority/effort
```

**Task file format** (`.kanban/tasks/T-NNN-slug.md`):
```
# T-NNN: Title
> One-line description
- **priority**: critical|high|medium|low
- **effort**: XS|S|M|L

## Criteria
- [ ] Acceptance criterion
```

**Rules:** WIP limit = 2 in Doing. Pick highest-priority from Todo. Never skip criteria checkboxes. Slug is kebab-case from title, ≤40 chars.
<!-- kanban:end -->
