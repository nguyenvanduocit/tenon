# Tenon vision

Tenon is a fast native terminal workspace for CLI-first software development.
It is designed for developers who run coding agents in the terminal and want
to stay in one working context.

## Product contract

Tenon opens and behaves like a terminal.

1. A workspace represents a directory and appears in the left sidebar.
2. Each workspace contains tabs.
3. A new tab contains one terminal filling the complete canvas.
4. `⌘D` splits the active slot left/right; `⇧⌘D` splits it top/bottom.
5. Slot headers can be dragged. Dropping over another slot swaps their complete
   rectangles. Dropping elsewhere moves the slot on the grid.
6. Every edge and corner is an invisible resize target. Shared edges resize
   coupled neighbors where the layout permits it.
7. Escape restores the exact layout captured at pointer-down. Invalid or stale
   transactions never partially mutate the workspace.
8. Files, changes, docs, and a web preview can open as slots, keeping common
   coding-session navigation inside Tenon.

The structural reference is
[`prototypes/spatial-layout/index.html`](prototypes/spatial-layout/index.html).
It defines components, hierarchy, relative regions, and interactions. The
native app owns its macOS materials, typography, colors, radii, and motion.

## What Tenon optimizes

### Terminal fidelity

The terminal is a real libghostty surface with native keyboard, mouse,
clipboard, focus, scale, and resize integration. Tenon consumes a pinned,
prebuilt `GhosttyKit.xcframework`; the application build never compiles Ghostty
with Zig.

### Low context-switching cost

Workspace navigation, tabs, terminals, file browsing, working-tree changes,
documentation, and local web previews share one window. These surfaces support
the terminal workflow instead of turning Tenon into an editor-centric IDE.

### Session continuity

A slot UUID owns its terminal surface. Moving, resizing, switching tabs, or
switching workspaces preserves that identity and its live process. A surface is
released only after its slot leaves the complete workspace catalog.

### Changeable architecture

Layout rules are pure values in `TenonCore`; AppKit paints and interacts with
them. Slot content, geometry, and live terminal resources are separate concerns.
This keeps layout iteration local and makes high-frequency pointer movement free
of process, filesystem, and view-host reconstruction work.

### Extensibility

The embedded JavaScript runtime exposes intent invocation and handling, event
subscription, scoped settings/storage/logging, timers, long-lived process and
filesystem resources, and declarative status/view contributions. Finite
cross-owner operations enter the host through capability-gated intents;
same-owner native app behavior remains direct typed Swift. Palette commands are
plugin-owned intent contributions rather than a second execution API. Plugins
extend the terminal workspace; the terminal workspace remains useful on its own.

## Current architecture

```text
TenonCore
  WorkspaceCatalog -> Workspace -> Tab -> WorkspaceSlot
  SpatialLayout     -> split, add, close, move, swap, coupled resize
  PluginHost        -> isolated JavaScriptCore runtimes, permissions, events

TenonApp
  ContentView       -> workspace sidebar, tab controls, canvas, status strip
  SpatialCanvasView -> AppKit cards and pure pointer transaction coordinator
  BuiltInSlotViews  -> terminal, files, changes, docs, web, plugin, empty
  SurfacePool       -> stable UUID-to-TerminalSurface ownership
  GhosttySurface    -> libghostty/AppKit boundary
```

The canvas is a fixed 12 × 12 logical grid. Transactions carry their operation
kind, exact baseline, complete proposal, and ordered affected IDs. The catalog
accepts only a transaction whose baseline still equals the active tab, whose
proposal is valid, and whose claimed affected IDs equal the actual changes.

## Near-term quality bar

- preserve terminal state through every workspace, tab, and layout transition;
- keep pointer interaction responsive with several live terminal surfaces;
- persist workspaces, tabs, slot content, and grid rectangles;
- expose built-in and plugin slot types through one coherent content picker;
- harden plugin consent, isolation, and auditability;
- verify complete user interactions in the hosted macOS test target.

The measure of Tenon is simple: a developer can open it as their terminal,
remain there for the whole coding loop, and rearrange the workspace without
interrupting the processes doing the work.
