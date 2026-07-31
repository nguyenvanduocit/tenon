# TDD Design — how Tenon stays testable

**The rule: domain and boundary rules live in `TenonIntentCore`/`TenonCore` as typed,
headlessly tested values and services. The SwiftUI shell contains native adapters and
projection only.** This is Functional Core, Imperative Shell (Bernhardt). Interaction
classification itself is enforced by
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).

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
| Intent contract/policy gate | canonical catalog + dispatcher/policy | declared-use/audience/capability/scope/provider pairs | `TenonIntentCoreTests`, `PluginPolicyTests` |
| Event bridges (workspace→plugins, title→plugins) | value → `(name, payload)` mapping | end-to-end through a real JS plugin | `WorkspacePluginBridgeTests` |
| Shipped plugins | the actual `plugins/` files | copied to temp dir, driven for real (incl. on-disk edits through FSEvents) | `ShippedPluginsTests` |
| Terminal, rendering, input | `GhosttySurface` behind the `TerminalSurface` seam | **not unit-tested** — smoke launch only | — |
| SwiftUI views | projections of core state | **not tested** — they contain no rules to test | — |

## Which runner covers which directory

`swift test` is the evidence bar, so every directory it cannot reach has to earn the
exclusion out loud. `poc/Tests/` holds five directories:

| Directory | `swift test` | `xcodebuild test` | Why |
|---|---|---|---|
| `TenonIntentCoreTests` | yes | yes | pure kernel |
| `TenonCoreTests` | yes | yes | headless domain + plugin host |
| `TenonAppStateTests` | yes | yes | headless app layer: intent providers, AppKit/SwiftUI state types |
| `TenonIntegrationTests` | no | yes | launches a real Ghostty surface; needs a GPU and a PTY |
| `TenonUITests` | no | yes | XCUITest drives the built `.app`; needs a logged-in GUI session |

`Package.swift` and `project.yml` name the same three headless targets on purpose. When
they disagreed, the directory only Xcode knew about (`TenonAppTests`) stopped compiling and
nobody noticed, because no runner ever built it — its four files sat in the tree reading as
coverage while asserting nothing. If you add a test directory, add it to **both** manifests,
or add a row here saying which runner skips it and why.

## Design rules that keep this true

1. **Mutations return events.** `ws.splitFocusedPane(.horizontal) -> [WorkspaceEvent]`
   — the UI, the plugin bridge, and the tests all consume the same value. No
   observation magic in tests, no "wait for publisher" flakiness.
2. **Empty return = nothing happened.** Every mutation is a no-op on invalid input
   (unknown IDs, empty workspace) and says so by returning `[]`. Tests pin this.
3. **Identity in the core, resources in the shell.** A pane is a `UUID` to TenonCore.
   `SurfacePool` (app shell) maps IDs to terminal surfaces; releasing there frees
   ghostty resources. The core never imports anything it would need to fake.
4. **One seam per boundary.** `TerminalSurface` hides the emulator; the exact `tenon`
   vocabulary is the entire plugin surface; the intent catalog/policy/dispatcher is the
   finite public capability path. When a test needs a fake, the seam already exists —
   write a fake conformance, not a parallel protocol.
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
- **Command palette evolution** — rank a policy-filtered projection of plugin-owned intent
  metadata with a pure index; selection/keybindings dispatch the same canonical intent.
- **Plugin capability evolution** — add canonical intent/resource authority bindings and
  blocked/allowed policy tests; no handwritten finite plugin API.
- **Quick terminal, themes, settings** — each is a store + events in core; the
  window/hotkey/appearance part is shell.
- **Runtime consent + audit log** — a pure `PermissionLedger` (request → decision →
  log entry) tested headless; the consent *dialog* is shell.

The test for whether a design fits Tenon: **"can this rule be asserted in
`TenonCoreTests` without a window?"** If not, the rule is in the wrong place.
