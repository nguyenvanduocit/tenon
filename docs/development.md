# Tenon development

Tenon is a native macOS application. This document covers what it runs today, how
to build, launch, and test it from the repository root, and where its source
lives.

## What is running

- Native SwiftUI/AppKit shell on macOS 14+.
- One workspace list at the left, tabs and layout actions at the top, one
  tab-local spatial canvas in the center, and status items at the bottom.
- A 12 × 12 grid layout with add, split, close absorption, drag, complete-rect
  swap, coupled resize, stale-transaction rejection, and Escape rollback.
- Stable `TerminalSurface` ownership per slot UUID, backed by libghostty or a
  deterministic stub.
- Built-in terminal, files, changes, automation, web preview, plugin-view, and empty
  slot content.
- An embedded JavaScriptCore plugin host with isolated runtimes, hot reload,
  durable enable/disable, capability policy and consent, intent invocation and
  handling, events, bounded resources, scoped settings/storage/logging, status
  items, declarative views, and palette contributions.
- Fail-soft workspace catalog persistence. Layout/content/selection and terminal
  title/working-directory placeholders restore across relaunch; restored
  terminals start a fresh shell only when materialized.
- A host-internal Agent Lens Session/Terminal projection for supported,
  authoritatively bound agent evidence.

## Setup and build

The app consumes a pinned prebuilt Ghostty artifact. Setup downloads the
xcframework and shell integration, syncs the public header into the thin
`GhosttyKit` C shim, and compiles `scripts/internal/ghostty.terminfo` into
`Resources/terminfo` with `tic`. The terminfo entry is compiled rather than
downloaded because the pinned release carries no terminfo asset — upstream holds
it as Zig source and builds it with a toolchain this repository deliberately
never runs. Setup rebuilds it on every run, including when the downloaded
artifact is already present and verified, since it is the one build input a
verified GhosttyKit says nothing about.

`./tenon dev` and `./tenon install` run setup themselves. Driving `xcodebuild`
directly goes around the verbs, so it runs setup by hand:

```bash
./scripts/internal/setup-ghostty.sh
./scripts/internal/setup-xcodegen.sh
.build/tools/xcodegen/bin/xcodegen generate
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
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
  read the sealed bundled inventory alongside a writable user inventory. Plugins
  loaded from an arbitrary writable catalog are untrusted. A newly discovered
  plugin starts disabled and executes only after a human enables it.
- `TENON_TRUST_PLUGIN_INVENTORY=1` stands a `TENON_PLUGINS_DIR` catalog in for
  the app bundle for a controlled development fixture, so new plugins auto-enable
  and carry bundled standing intent consent. The value is matched exactly — `1`
  grants it, every other value including `true` leaves the catalog untrusted.
  The separate user-authored inventory is always untrusted.
- `TENON_STUB_TERMINAL=1` replaces the PTY-backed surface with deterministic
  content for UI tests and shell smoke runs.

XcodeGen is the source of truth for the app, bundled resources, and all hosted
test targets. Run `.build/tools/xcodegen/bin/xcodegen generate` after adding or
moving source files.

Use that pinned copy rather than one on `PATH`. The version is a build input:
2.46.0 orders targets by declaration where 2.45.4 sorted them alphabetically, and
it embeds `TenonIntentCore.framework` although nothing loads it dynamically. Either
difference makes a generated project disagree with the committed one on a tree
nobody edited, which is how CI failed for a day. `scripts/internal/setup-xcodegen.sh` pins
the version and checksum, `scripts/internal/setup-xcodegen.test.sh` asserts the pin still
matches the published release, and `project.yml`'s `minimumXcodeGenVersion` names
the same version.

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

**Add slot** opens terminal, files, diff, automation, and local web-preview choices.
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
  -clonedSourcePackagesDirPath .build \
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
  -only-testing:TenonAppStateTests/SpatialCanvasInteractionTests \
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

Do not copy test counts into durable documentation: they drift on every feature.
The command output is the verification receipt and should identify the
commit/worktree, destination, exit code, and failing tests. See
[`operations.md`](operations.md) for the runner matrix and release checklist.

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

## Plugin runtime

Finite cross-owner operations use one canonical request/reply API:

```js
const result = await tenon.intents.send("workspace.state.v1", {});
if (!result.ok) tenon.log(result.error.code);
```

Every sent name is declared in `manifest.intents.uses`. Plugin-owned operations
are declared as versioned contracts in `manifest.intents.provides` and bound once
with `tenon.intents.handle`. Palette rows and registered product keybindings are
metadata on those same contracts, not another command API.

Immutable facts use declared `tenon.events.emit/on`; timers,
`tenon.process.stream`, and `tenon.fs.watch` own bounded resource lifetimes;
views, status, and dynamic palette results are declarative contributions. The
only scoped plugin-private facilities are settings, storage, and log. Pure
`tenon.path.*` helpers perform no I/O.

The complete authoring guide is
[`plugin-author-guide.md`](plugin-author-guide.md). Existing v0.2 plugins must
follow [`plugin-migration-v0.2.md`](plugin-migration-v0.2.md); the old helper,
runtime-command, sidebar, and imperative workspace APIs have no compatibility
shim. The exhaustive normative inventory is
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).

JavaScriptCore runtimes are isolated by context/executor but remain in Tenon's
process. This is not a hard sandbox: enabling an untrusted plugin grants
process-level code execution trust. Capability, scope, audience, and consent
checks still gate its access to host operations.

## Source map

```text
Sources/
  TenonIntentCore/
    IntentContract.swift  canonical schemas, effects, audiences, errors
    IntentDispatcher.swift policy, admission, provider lifecycle, settlement
    IntentMailbox.swift   closed bounded execution lanes
  TenonCore/
    SpatialLayout.swift    pure grid operations and transactions
    Workspace.swift        catalog/workspace/tab/slot state and events
    WorkspaceStore.swift   observable mutation shell and plugin event bridge
    CoreIntentCatalog.swift closed core intent inventory and lane map
    PluginRuntime.swift    JavaScriptCore adapter and resource boundary
    PluginHost.swift       inventories, installation lifecycle, hot reload
  TenonApp/
    TenonApp.swift         composition root, persistence, plugin/surface lifecycle
    ContentView.swift      sidebar, tab bar, canvas stage, status strip
    Canvas/
      SpatialCanvasNSView.swift  AppKit cards and pointer coordinator
      SpatialCanvasRepresentable.swift SwiftUI bridge onto that view
      SpatialCanvasOverlays.swift drag, resize and selection overlays
      SpatialSlotCardView.swift  one slot's card chrome
      SpatialInteraction.swift   pointer gesture state machine
      PaneContentHost.swift      hosts a slot's content without publishing size
    BuiltInSlotViews.swift async/cancel-aware files, Git, web, plugin UI
    SurfacePool.swift      slot UUID to stable terminal surface
    GhosttySurface.swift   libghostty/AppKit integration
    TerminalSurface.swift protocol and deterministic stub
  TenonCLI/
    main.swift             ping/focus and intent list/describe/send adapter
GhosttyKit/                thin C module shim
GhosttyKit.xcframework/    downloaded prebuilt static artifact
Resources/                 downloaded Ghostty shell integration, compiled terminfo
plugins/                   bundled JavaScript plugins
Tests/                     core, hosted app, and terminal integration suites
project.yml                XcodeGen source of truth
```

## Current boundaries

- The application currently owns one window.
- Workspace structure restores, but terminal processes do not; restored terminal
  panes lazily create fresh shells.
- Capability policy, interactive consent, installation identity, and durable
  enablement are implemented. JavaScriptCore still lacks hard process isolation,
  safe preemption of runaway synchronous code, and per-plugin memory limits.
- Built-in slot surfaces are native application features. The plugin content
  picker and public SDK are still evolving toward the same polished opening
  flow as built-in content.
- Status items are aggregated by plugin name; ordering and alignment policies
  are intentionally small at this stage.

See [`README.md`](README.md) for canonical document precedence and the current
feature-status inventory.
