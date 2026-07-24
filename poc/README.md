# Tenon native app

This directory contains the current macOS application. Its name is historical;
this is the product implementation, not a disposable browser prototype.

## What is running

- Native SwiftUI/AppKit shell on macOS 14+.
- One workspace list at the left, tabs and layout actions at the top, one
  tab-local spatial canvas in the center, and status items at the bottom.
- A 12 × 12 grid layout with add, split, close absorption, drag, complete-rect
  swap, coupled resize, stale-transaction rejection, and Escape rollback.
- Stable `TerminalSurface` ownership per slot UUID, backed by libghostty or a
  deterministic stub.
- Built-in terminal, files, changes, docs, web preview, plugin-view, and empty
  slot content.
- An embedded JavaScriptCore plugin host with isolated runtimes, hot reload,
  enable/disable, permissions, settings, storage, events, commands, status
  items, declarative views, and workspace APIs.

## Setup and build

The app consumes a pinned prebuilt Ghostty artifact. Setup downloads the
xcframework, shell integration, and terminfo, then syncs the public header into
the thin `GhosttyKit` C shim.

```bash
cd poc
./scripts/setup-ghosttykit.sh
xcodegen generate
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  build
```

Launch the real terminal build:

```bash
open .build/xcode/Build/Products/Debug/Tenon.app
```

Launch the same shell with deterministic terminal content:

```bash
TENON_STUB_TERMINAL=1 \
TENON_WORKSPACE_PATH=/path/to/project \
TENON_PLUGINS_DIR="$PWD/plugins" \
  .build/xcode/Build/Products/Debug/Tenon.app/Contents/MacOS/Tenon
```

Runtime overrides:

- `TENON_WORKSPACE_PATH` selects the initial workspace and each initial
  terminal's working directory. Resolution order is explicit override,
  meaningful process working directory, then the user's home directory when
  LaunchServices supplies `/`.
- `TENON_PLUGINS_DIR` points at a development plugin catalog. Installed builds
  copy bundled plugins to Application Support automatically.
- `TENON_STUB_TERMINAL=1` replaces the PTY-backed surface with deterministic
  content for UI tests and shell smoke runs.

XcodeGen is the source of truth for the app, bundled resources, and all hosted
test targets. Run `xcodegen generate` after adding or moving source files.

## Controls

| Action | Control |
|---|---|
| New tab | `⌘T` or `+` in the tab bar |
| Split active slot left/right | `⌘D` or **Split** |
| Split active slot top/bottom | `⇧⌘D` or **Stack** |
| Close active slot | `⌘W` |
| Next slot | `⌘]` |
| Next / previous tab | `⇧⌘]` / `⇧⌘[` |
| Move or swap | Drag a slot header |
| Resize | Drag any slot edge or corner |
| Cancel pointer transaction | `Esc` |

**Add slot** opens terminal, files, diff, docs, and local web-preview choices.
Closing the final slot keeps the tab alive and shows an **Add terminal** action.
Closing an active tab selects its previous neighbor.

## Test

Run the complete macOS scheme:

```bash
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  test
```

Focused suites:

```bash
# Pure workspace, layout, plugin, and permission behavior.
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TenonCoreTests \
  test

# Hosted AppKit pointer and card hit-testing.
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TenonAppTests/SpatialCanvasInteractionTests \
  test

# Black-box shortcuts, tab/slot counts, and pointer drag.
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TenonUITests \
  test

# Fast headless core path.
swift test
```

The current verified baseline is 159 non-UI tests: 138 core, 15 hosted spatial
interaction, and 6 terminal integration tests. The default scheme also runs 6
black-box XCUITest flows, for 165 tests total in a logged-in macOS GUI session.

## Spatial model

```text
WorkspaceCatalog
  Workspace (directory)
    Tab
      WorkspaceSlot { id, rect, content }
```

`GridRect` uses integer coordinates on a 12 × 12 canvas. Minimum slot size is
3 × 3. `SpatialLayout` is a pure functional core: it receives a complete slot
array and returns a transaction containing an exact baseline and complete
proposal.

Move and swap transactions also carry an explicit operation kind. Catalog apply
methods reject cross-operation use, stale baselines, invalid geometry, no-ops,
foreign IDs, duplicate affected IDs, and affected-ID mismatches. Swap events
preserve the requested dragged-slot then target-slot order.

`SpatialCanvasInteractionCoordinator` freezes the canvas metrics and slot
snapshot at pointer-down. During drag it performs only grid math and frame
updates. Content hosts and terminal surfaces are stable; filesystem, Git,
documentation, and web work never runs in the pointer loop.

## Plugin API v0.2

Free surfaces:

```js
tenon.statusBar.set(text)
tenon.commands.register(id, title, handler)
tenon.events.on(event, handler)
tenon.sidebar.set({ title, items })
tenon.sidebar.onSelect(handler)
tenon.views.register(viewId, { title })
tenon.views.set(viewId, { title, items })
tenon.views.onSelect(viewId, handler)
tenon.settings.get(key)
tenon.storage.get(key)
tenon.storage.set(key, jsonValue)
tenon.workspace.get()
tenon.log(text)
```

Permission-gated surfaces:

```js
tenon.fs.readDir(path)                         // filesystem.read
tenon.fs.readFile(path)                        // filesystem.read
tenon.fs.exists(path)                          // filesystem.read
tenon.fs.writeFile(path, content)              // filesystem.write
tenon.process.exec(command, args, callback)    // process.exec
tenon.terminal.write(text)                     // terminal.write
tenon.workspace.newTab()                       // workspace.control
tenon.workspace.split("horizontal"|"vertical") // workspace.control
tenon.workspace.focusSlot(slotId)              // workspace.control
tenon.workspace.closeSlot(slotId)              // workspace.control
```

`tenon.workspace.get()` returns workspace/tab/slot structure with
`activeWorkspaceId`, `activeTabId`, `activeSlotId`, `slotIds`, slot content, and
grid rectangles. Terminal-title events use `{ title, slotId }`. Workspace events
use `workspace.slot-*` and `workspace.slots-*`; `workspace.changed` reports
workspace, tab, and slot totals.

The permission names currently enforced are `terminal.read`, `terminal.write`,
`filesystem.read`, `filesystem.write`, `process.exec`, and
`workspace.control`. A blocked API call returns `{ ok: false, error }`, records
one deduplicated violation, and leaves the runtime loaded.

## Source map

```text
Sources/
  TenonCore/
    SpatialLayout.swift    pure grid operations and transactions
    Workspace.swift        catalog/workspace/tab/slot state and events
    WorkspaceStore.swift   observable mutation shell and plugin event bridge
    PluginRuntime.swift    JavaScriptCore API and permission boundary
    PluginHost.swift       runtime aggregation, lifecycle, and hot reload
  TenonApp/
    TenonApp.swift         app wiring, commands, plugin and surface lifecycle
    ContentView.swift      sidebar, tab bar, canvas stage, status strip
    SpatialCanvasView.swift
                            AppKit cards and pointer coordinator
    BuiltInSlotViews.swift async/cancel-aware files, Git, docs, web, plugin UI
    SurfacePool.swift      slot UUID to stable terminal surface
    GhosttySurface.swift   libghostty/AppKit integration
    TerminalSurface.swift protocol and deterministic stub
GhosttyKit/                thin C module shim
GhosttyKit.xcframework/    downloaded prebuilt static artifact
Resources/                 downloaded Ghostty shell integration and terminfo
plugins/                   bundled JavaScript plugins
Tests/                     core, hosted app, and terminal integration suites
project.yml                XcodeGen source of truth
```

## Current boundaries

- Workspace and slot layout are in-memory; session restore is not implemented.
- The application currently owns one window.
- The JavaScriptCore capability gate is implemented, while runtime consent,
  audit history, and stronger process isolation remain future hardening work.
- Built-in slot surfaces are native application features. The plugin content
  picker and public SDK are still evolving toward the same polished opening
  flow as built-in content.
- Status items are aggregated by plugin name; ordering and alignment policies
  are intentionally small at this stage.
