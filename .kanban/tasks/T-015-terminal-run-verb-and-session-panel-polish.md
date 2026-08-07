# T-015: `tenon.terminal.run` verb + Claude sessions panel polish
> Resume in the claude-sessions panel does nothing: `tenon.terminal.write` targets the ACTIVE slot, which is the panel itself. Give the host a verb that runs a command in a real terminal, and tighten the panel's visual design.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 3bf9127e

Free (mine, no overlap):
- `plugins/claude-sessions/**`
- `Sources/TenonCore/PaneTarget.swift`
- `Sources/TenonApp/SurfacePool.swift`
- `Tests/TenonCoreTests/PaneTargetTests.swift`
- `Tests/TenonCoreTests/ShippedPluginsTests.swift`

Landed with @d7f580dd's explicit GO on the board (append-only, no line overlap):
- `Sources/TenonCore/PluginHost.swift` — ONE new case at the END of `enum WorkspaceCommand`: `.runInTerminal(String)`
- `Sources/TenonCore/PluginRuntime.swift` — ~12 lines appended to the `tenon.terminal` block: `run(command)`, gated behind the EXISTING `terminal.write` (no new permission, no change to your `shell.open` work)
- `Sources/TenonApp/TenonApp.swift` — ONE new case in the existing `onWorkspaceCommand` switch
- `Tests/TenonCoreTests/PluginCapabilityTests.swift` — one blocked+allowed pair appended at the end

## Why
`TenonApp.swift:99` routes `tenon.terminal.write` to `catalog.activeSlotID`. When a plugin
panel is the active pane — exactly when its buttons get clicked — the text goes to a slot
with no terminal surface and is silently dropped. Every plugin that wants to run something
for the user hits this, not just claude-sessions.

## Design
- `PaneTarget.preferredTerminal(in:)` (pure, TenonCore): active slot if it is a terminal,
  else the first terminal in the active tab, else nil.
- `WorkspaceCommand.runInTerminal(String)`: shell resolves a terminal (opening a terminal
  tab when there is none), focuses it, and sends `command + "\n"`.
- `SurfacePool` queues the text when the surface does not exist yet (a just-opened tab
  builds its surface on the next SwiftUI render), flushing it on creation.
- Panel: one list card instead of a stack of heavy cards; title + one-line meta;
  short id; quieter Resume button.

## Criteria
- [x] `PaneTarget.preferredTerminal` covered for: active terminal, panel active + terminal in tab, no terminal, terminal in another tab
- [x] `terminal.run` blocked+allowed pair (invariant 5)
- [x] claude-sessions Resume emits `runInTerminal("claude --resume <id>")`
- [x] Command lands in a terminal opened in the same click (pending-text flush in SurfacePool)
- [x] `swift build` clean + full `swift test` green — measured on the committed tree at
      `17bf0a6` (2026-07-31 02:51): build exit 0 under warnings-as-errors, full suite
      **750 tests / 0 failures**

## Status
COMPLETE. The suite this task was waiting on now runs: @d7f580dd's `SlotContent.files`
deletion landed long ago and the test target compiles. Everything this task shipped
(`PaneTarget.preferredTerminal`, `WorkspaceCommand.runInTerminal`, the SurfacePool
pending-text flush, the claude-sessions panel) is committed and covered by that green run.

## Follow-up handed to T-014 (their file)
`BuiltInSlotViews.swift:63-69` titles a `.pluginView` pane with the raw viewID, so this panel's
tab reads `sessions` and git's reads `changes`. The registered title is available in
`host.pluginViews` and should be the last fallback instead of the id.
