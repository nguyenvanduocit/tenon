# TDD Design — how Tenon stays testable

**The rule: every rule lives in `TenonCore` as pure values, tested headless. The SwiftUI
shell is a projection with no rules of its own.** This is Functional Core, Imperative
Shell (Bernhardt), and it is why 57 tests cover everything except pixels in ~1 second.

## The loop

Every feature lands in this order — no exceptions:

1. **Red.** Write the test first, in `Tests/TenonCoreTests/`. Run it; confirm it fails
   for the right reason (a missing type is the right reason for a brand-new module).
2. **Green.** Implement the minimal core change until the suite passes.
3. **Shell.** Only then wire the UI — the shell may call core mutations and render core
   state, never decide anything itself.
4. **Smoke.** `swift build` + launch-alive check (window opens, shell child spawns).
   Pixels are the only thing not asserted automatically.

Worked example (the workspace, 2026-07-23): `WorkspaceTests` written first → red
(`cannot find type 'Workspace'`) → `Workspace.swift` + `WorkspaceStore.swift` → green
on first compile → `SurfacePool`/`ContentView`/`TenonApp` wired with zero new rules.

## Layer map — where a rule lives decides how it's tested

| Layer | Type | Test style | Suite |
|---|---|---|---|
| Workspace tree (tabs/splits/panes/focus) | pure `struct Workspace`, mutations return `[WorkspaceEvent]` | exhaustive unit | `WorkspaceTests` |
| Observable stores (`WorkspaceStore`) | thin class over the pure value | batch/no-op forwarding | `WorkspaceStoreTests` |
| Plugin host (load, reload, isolation, enable/disable) | `PluginHost` + one `JSContext`/plugin | unit vs throwaway plugin trees in temp dirs | `PluginHostTests`, `PluginPolicyTests` |
| Permission gate | one function: `PluginRuntime.installAPI` | policy pairs: blocked vs allowed | `PluginPolicyTests` |
| Event bridges (workspace→plugins, title→plugins) | value → `(name, payload)` mapping | end-to-end through a real JS plugin | `WorkspacePluginBridgeTests` |
| Shipped plugins | the actual `plugins/` files | copied to temp dir, driven for real (incl. on-disk edits through FSEvents) | `ShippedPluginsTests` |
| Terminal, rendering, input | `GhosttySurface` behind the `TerminalSurface` seam | **not unit-tested** — smoke launch only | — |
| SwiftUI views | projections of core state | **not tested** — they contain no rules to test | — |

## Design rules that keep this true

1. **Mutations return events.** `ws.splitFocusedPane(.horizontal) -> [WorkspaceEvent]`
   — the UI, the plugin bridge, and the tests all consume the same value. No
   observation magic in tests, no "wait for publisher" flakiness.
2. **Empty return = nothing happened.** Every mutation is a no-op on invalid input
   (unknown IDs, empty workspace) and says so by returning `[]`. Tests pin this.
3. **Identity in the core, resources in the shell.** A pane is a `UUID` to TenonCore.
   `SurfacePool` (app shell) maps IDs to terminal surfaces; releasing there frees
   ghostty resources. The core never imports anything it would need to fake.
4. **One seam per boundary.** `TerminalSurface` hides the emulator; `tenon` is the
   entire plugin surface; `installAPI` is the entire permission gate. When a test
   needs a fake, the seam already exists — write a fake conformance, not a mock.
5. **Sensitive data never rides structural events.** Workspace events carry IDs and
   shapes, never pane content — content stays behind `terminal.read`. This keeps the
   free-tier bridge testable without security theater.
6. **Shipped plugins are fixtures too.** `ShippedPluginsTests` runs the real
   `plugins/` files, so the demo content can never silently rot.

## Muxy-parity roadmap, mapped to test surfaces

Done: workspace (tabs/splits/panes/focus, keyboard + ghostty-binding driven),
plugin host with hot reload, enable/disable persisted, permission gate, libghostty
rendering, 3 shipped plugins.

Next, each entering through a failing core test first:

- **Session restore** — serialize `Workspace` (make it `Codable`) + reopen shells:
  round-trip tests in `WorkspaceTests`.
- **Pane resize persistence** — `ratio` updates as a mutation (`setRatio`) so split
  drags survive restore: tree tests.
- **Command palette parity** (fuzzy search, host commands like "Split Right" as
  first-class commands next to plugin commands): a pure `CommandIndex` in core.
- **Plugin capability: `filesystem.read/write`** — lands entirely inside
  `installAPI` + `PluginPolicyTests` pairs (blocked/allowed), same shape as
  `terminal.read`.
- **Quick terminal, themes, settings** — each is a store + events in core; the
  window/hotkey/appearance part is shell.
- **Runtime consent + audit log** — a pure `PermissionLedger` (request → decision →
  log entry) tested headless; the consent *dialog* is shell.

The test for whether a design fits Tenon: **"can this rule be asserted in
`TenonCoreTests` without a window?"** If not, the rule is in the wrong place.
