# T-068: A file path in Agent Lens prose opens that file

> Agents write paths constantly. Today they render as dead monospace text, so returning
> from a claim to its evidence means retyping the path into the file explorer.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)

**Released 2026-08-06 14:2x by session `cbf0f2c6`. Every file below is FREE** — including
`AgentLensView.swift`, which T-069 was waiting on.

## Mechanism (interaction classification)

`docs/architecture-interaction-boundaries.md` decides this before the code does. Agent Lens
is host-native `TenonApp` UI and the file pane is host-owned `SlotContent.file(path:)`, so
this is **same-owner DIRECT**: the click calls the typed `WorkspaceStore.openContent` use
case, exactly as `ChangesPanelView` already does for a diff. `workspace.content.open.v1`
stays the public adapter over that same service for plugin/CLI/agent callers — one typed
semantic implementation, no second public path, and no app intent principal minted for
built-in UI (invariants 6 and 8).

## Criteria

- [x] A pure rule recovers a file reference (path + optional `:line`) from one inline span
      and rejects commands, flags, URLs, and ordinary prose — asserted without a window.
      `AgentFileReferenceRule` in `AgentLensFileLinks.swift`.
- [x] Resolution is evidence-linked: a span becomes a link only when it resolves to a file
      that exists under the workspace root (relative, absolute, and `~` all resolve). A
      relative path cannot walk out of the root, and a directory is not a file pane.
- [x] A resolved span renders as a link in prose, list items, and table cells; an
      unresolvable markdown link renders as plain text instead of a dead link.
- [x] Clicking a resolved path opens it as a file pane through `WorkspaceStore.openContent`;
      `http(s)` links keep their normal system behaviour. `InteractionBoundaryFitnessTests`
      now pins both the typed wiring and the absence of any intent path in Agent Lens.
- [x] Tests green for everything this task owns: `AgentLensFileLinkTests` 19/19,
      `InteractionBoundaryFitnessTests` 8/8, `AgentLensMarkdownTests` 16/16 (T-067's parser
      still passes through the new parameter).

## Evidence

Full suite at 14:2x: **1144 tests, 5 failures — none in this task's files.** Each failure
maps to a peer's in-flight edit: three hook tests
(`AgentHookLensProjectionTests`, two `AgentLensInputAndSurfaceTests` installer cases) to
T-069's `AgentSessionHooks.swift`/`AgentLensDecoders.swift`/`ClaudeToolFacts.swift`;
`PaletteIntentInvokerTests` to `AppIntentRuntime.swift`; `RestoredPluginPanesTests` to
`PluginHost.swift`/`PluginInventory.swift`. None touches markdown, file links, or slot
content.

**Not verified, left for a human at the app:** on macOS a `Text` that is both
`.textSelection(.enabled)` and link-bearing can swallow the click. The GUI cannot be
driven from a headless shell, so whether the link actually opens the pane is a live check.

## Deliberately not done

- The click does not jump to the cited line. `SlotContent.file(path:)` carries no line, so
  `AgentFileReference.line` is parsed (it has to be, to strip the suffix before resolving)
  and kept for whenever the editor can take one.
- Tool rows still render only the tool's name, never its paths, so there is nothing to
  click there. Changing what a tool row shows is a separate product decision.
