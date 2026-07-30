# T-015: `tenon.terminal.run` verb + Claude sessions panel polish
> Resume in the claude-sessions panel does nothing: `tenon.terminal.write` targets the ACTIVE slot, which is the panel itself. Give the host a verb that runs a command in a real terminal, and tighten the panel's visual design.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 3bf9127e

Free (mine, no overlap):
- `poc/plugins/claude-sessions/**`
- `poc/Sources/TenonCore/PaneTarget.swift`
- `poc/Sources/TenonApp/SurfacePool.swift`
- `poc/Tests/TenonCoreTests/PaneTargetTests.swift`
- `poc/Tests/TenonCoreTests/ShippedPluginsTests.swift`

Landed with @d7f580dd's explicit GO on the board (append-only, no line overlap):
- `poc/Sources/TenonCore/PluginHost.swift` — ONE new case at the END of `enum WorkspaceCommand`: `.runInTerminal(String)`
- `poc/Sources/TenonCore/PluginRuntime.swift` — ~12 lines appended to the `tenon.terminal` block: `run(command)`, gated behind the EXISTING `terminal.write` (no new permission, no change to your `shell.open` work)
- `poc/Sources/TenonApp/TenonApp.swift` — ONE new case in the existing `onWorkspaceCommand` switch
- `poc/Tests/TenonCoreTests/PluginCapabilityTests.swift` — one blocked+allowed pair appended at the end

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
- [ ] `swift build` clean + full `swift test` green

## Status
Sources build green with all of it. The full suite cannot run yet: @d7f580dd is mid-way
through deleting `SlotContent.files`, so WorkspaceTests / RecentStoreTests /
WorkspaceDefaultContentTests / AppPreferencesTests / CoreCommandsPluginTests /
WorkspaceContentCapabilityTests do not compile. **No compile error is in any file of mine**
(`swift build --build-tests` error list is entirely theirs). PaneTargetTests was already
moved off `.files` by me so they don't have to touch a file I hold. Waiting on a watcher for
the test target to build, then running the whole suite.

## Follow-up handed to T-014 (their file)
`BuiltInSlotViews.swift:63-69` titles a `.pluginView` pane with the raw viewID, so this panel's
tab reads `sessions` and git's reads `changes`. The registered title is available in
`host.pluginViews` and should be the last fallback instead of the id.
