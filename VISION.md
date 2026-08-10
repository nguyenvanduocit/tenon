# Tenon vision

Tenon is the human supervision layer for parallel CLI-agent work.

It preserves shared context, directs scarce human attention, and makes parallel
work understandable, verifiable, and steerable. Coding agents continue to run
in their native CLI harnesses and real PTYs. Tenon gives their human operator
one coherent place to understand and intervene without taking ownership of
agent planning, spawning, scheduling, or execution.

Agents scale execution. Tenon scales human judgment.

## Product purpose

Tenon should answer five questions without requiring the operator to reopen
every transcript:

1. What materially changed since I last looked?
2. What requires my judgment now?
3. What is the agent claiming, and what evidence supports it?
4. Which work is blocked, drifting, stale, or in conflict?
5. What can I safely ignore for now?

The terminal, transcript, diff, command result, and test receipt remain source
evidence. Context capsules and attention signals help the operator navigate
that evidence; they do not replace it.

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
8. Files, changes, and a web preview can open as slots, keeping common
   coding-session navigation inside Tenon.

The structural reference is
[`prototypes/spatial-layout/index.html`](prototypes/spatial-layout/index.html).
It defines components, hierarchy, relative regions, and interactions. The
native app owns its macOS materials, typography, colors, radii, and motion.

## What Tenon optimizes

### Human situation awareness

Parallel workstreams are organized by goal, material delta, requested decision,
blocker, evidence, freshness, and next action. Tenon prioritizes changes that
need judgment and keeps completed or safely progressing work out of the
operator's immediate attention.

### Practical human fan-out

The useful limit is not the number of agents that can execute. It is the number
of workstreams a person can supervise and then accurately re-enter. Tenon aims
to increase that limit by surfacing explicit attention states promptly and
reducing reorientation time with evidence-linked context.

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

The workspace catalog persists workspace, tab, slot, content, geometry,
selection, terminal title, and working-directory placeholders across app
relaunch. A restored terminal is materialized lazily as a fresh shell; Tenon
does not serialize or resurrect a process.

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

The plugin platform is enabling architecture for agent adapters, supervision
experiments, provenance, and public-contract governance. The customer value is
faster, safer human judgment across changing CLI-agent tools.

## Current architecture

```text
TenonCore
  WorkspaceCatalog -> Workspace -> Tab -> WorkspaceSlot
  SpatialLayout     -> split, add, close, move, swap, coupled resize
  PluginHost        -> isolated JavaScriptCore runtimes, permissions, events

TenonApp
  ContentView       -> workspace sidebar, tab controls, canvas, status strip
  SpatialCanvasView -> AppKit cards and pure pointer transaction coordinator
  BuiltInSlotViews  -> terminal, files, changes, web, plugin, empty
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
- keep persisted workspaces, tabs, slot content, grid rectangles, and selections
  fail-soft across schema and filesystem drift;
- expose built-in and plugin slot types through one coherent content picker;
- preserve fail-closed plugin consent and harden runtime isolation/auditability;
- verify complete user interactions in the hosted macOS test target.

## First supervision experiment

The initial wedge is an Attention Inbox for three to five independently running
Claude Code or Codex PTYs:

- explicit states such as `needs_input`, `approval`, `failed`,
  `ready_for_review`, and `completed`;
- a “since you last looked” capsule containing goal, material delta, current
  claim or blocker, next action, freshness, and links to raw evidence;
- exact return to the originating workspace, slot, process, and evidence.

This is a product target, not current runtime support. Its implementation must
use the interaction classifications and governed public surfaces defined in
[`docs/architecture-interaction-boundaries.md`](docs/architecture-interaction-boundaries.md).
The research basis and falsifiable experiment are documented in
[`docs/research-human-agent-supervision.md`](docs/research-human-agent-supervision.md).

## Measure of success

Tenon succeeds when one person can supervise more concurrent CLI-agent work
without losing correctness or trust. The first experiment must reduce median
context-reorientation time by at least 30%, preserve or improve explicit-blocker
detection, and keep false-attention items below 10%. Every material capsule
claim must resolve to an exact source identity, immutable location and hash,
capture time, freshness, and authority level. Traceability errors and claims
unsupported by their cited evidence are measured separately, with zero accepted
in the reviewed experiment sample.

Tenon implements the native terminal workspace, spatial canvas, catalog
persistence, libghostty integration, built-in slot surfaces, governed
plugin/intent runtime, CLI adapter, command palette, automations, and a
host-internal Agent Lens. Agent Lens can bind supported provider evidence to one
live terminal-surface incarnation and render one chronological Session timeline;
when authoritative identity is unavailable it degrades explicitly and Terminal
remains the exact evidence path. It is not the cross-session Attention Inbox.

The Attention Inbox, context capsules, cross-workstream prioritization, and
fan-out measurements remain to be implemented and validated. Current document
authority and implementation status are indexed in
[`docs/README.md`](docs/README.md).
