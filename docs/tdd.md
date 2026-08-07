# TDD Design — how Tenon stays testable

**Status:** current test architecture · **Reviewed:** 2026-08-06

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
4. **Smoke.** `swift build`, headless tests, then the smallest hosted/XCUITest path that
   crosses the changed native boundary. Visual polish still needs human inspection; native
   interaction wiring does not.

Worked example (the workspace, 2026-07-23): `WorkspaceTests` written first → red
(`cannot find type 'Workspace'`) → `Workspace.swift` + `WorkspaceStore.swift` → green
on first compile → `SurfacePool`/`ContentView`/`TenonApp` wired with zero new rules.

## Layer map — where a rule lives decides how it's tested

| Layer | Type | Test style | Suite |
|---|---|---|---|
| Workspace tree (tabs/splits/panes/focus) | pure `struct Workspace`, mutations return `[WorkspaceEvent]` | exhaustive unit | `WorkspaceTests` |
| Observable stores (`WorkspaceStore`) | thin class over the pure value | batch/no-op forwarding | `WorkspaceStoreTests` |
| Plugin host (load, reload, isolation, enable/disable) | `PluginHost` + one `JSContext`/plugin | unit vs throwaway plugin trees in temp dirs | `PluginHostTests`, `PluginCapabilityTests`, `PluginInventoryTests` |
| Intent contract/policy gate | canonical catalog + dispatcher/policy | declared-use/audience/capability/scope/provider pairs | `TenonIntentCoreTests`, `CoreIntentCatalogTests`, `PluginIntentManifestTests` |
| Event bridges (workspace/terminal/plugin facts) | value → `(name, payload)` mapping | end-to-end through real JS runtimes | `PluginBuiltinsTests`, `PluginPublishedEventTests`, `AutomationEventDeliveryTests` |
| Shipped plugins | the actual `plugins/` files | copied to temp dir, driven for real (incl. on-disk edits through FSEvents) | `ShippedPluginsTests` |
| Terminal, rendering, input | `GhosttySurface` behind the `TerminalSurface` seam | pure rules headless; real surface hosted; key/gesture wiring in XCUITest | `TenonAppStateTests`, `TenonIntegrationTests`, `TenonUITests` |
| SwiftUI/AppKit shell | projections and native adapters | state/interaction coordinators hosted without a window where possible; black-box UI for window-only wiring | `TenonAppStateTests`, `TenonUITests` |

## Which runner covers which directory

`swift test` is the evidence bar, so every directory it cannot reach has to earn the
exclusion out loud. `Tests/` holds five directories:

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

## Current coverage status

Implemented and covered across the layers above: workspace trees and spatial transactions,
fail-soft workspace catalog relaunch, lazy fresh-shell restoration, staged plugin hot
reload, durable installation identity/enablement, capability and consent policy, canonical
intent discovery/dispatch, command-palette and keybinding projections, declarative plugin
views/settings/automations/events, host-native editor state/external-change handling,
quick-command state, Agent Lens evidence reduction, and libghostty/UI smoke paths.

Open work is quality work, not an excuse for parallel APIs: stronger plugin process
isolation, broader release automation and measurements, large-file/resource protocols, and
new supervision experiments must enter through the same failing fitness/domain/adapter test
sequence.

The placement test remains: **can the rule be asserted without a window?** If yes, put it in
`TenonIntentCore`, `TenonCore`, or an app-state type and test it headlessly. If no because it
is truly native wiring, prove the pure policy below it first and keep the hosted/UI test as
the smallest adapter receipt.
