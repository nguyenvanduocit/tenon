# T-094: The shell can be read without colour, and off the main thread

> Batch B/C of the 2026-08-07 Swift architecture audit: the parts of the shell that spoke only
> in hue, spoke in UUIDs, or did filesystem work on the thread that draws.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)

Session `784166de` — RELEASED. Landed in:
`Sources/TenonApp/{PluginModalOverlay,SettingsView,CLICommandInstaller,GitCommand,`
`PaneAttentionProjection,ShellTitleBar,SpatialCanvasView,AgentSessionHooks,AgentLensSession,`
`WorkspaceSidebarView,WorkspaceStageView,QuickCommandViews,EmptyStateCard,AgentLensView}.swift`,
`Sources/TenonApp/ChangesPanelView.swift`, `Sources/TenonApp/DiffSlotView.swift`,
`Sources/TenonCore/PluginViewNode.swift`, `docs/designs.md`, `docs/domains.md`,
`.github/workflows/macos-ci.yml`, `Tests/TenonUITests/*`.

## Criteria

- [x] The plugin modal is modal to VoiceOver and to the keyboard: `isModal`, owned focus, a
      contained focus section, a labelled close control, a backdrop hidden from the tree.
- [x] A pane's spoken accessibility value describes where the pane is; the UUID and grid rect
      moved to the accessibility identifier, which is never spoken.
- [x] Attention state is spoken on every surface that draws the dot, and has a glyph vocabulary
      for Differentiate Without Color.
- [x] Icon-only shell controls carry an accessibility label; icons that sit beside their own
      label are hidden from the tree.
- [x] Settings assigns no decorative colour identity to a feature or a plugin.
- [x] `docs/designs.md` and the pane-header contract agree on the header height (34 pt).
- [x] Stateful plugin nodes keep their identity across a republish that inserts or reorders
      siblings.
- [x] One bounded `GitCommand`; the changed-file reader and the diff reader no longer carry two
      subprocess implementations with two different limits.
- [x] The CLI settings page reads and writes the filesystem off the main actor.
- [x] Hook events are admitted only when their declared provider and process group agree with
      the pane's live resolution.
- [x] CI runs the hosted integration suite on every PR, and a nightly GUI lane runs the UI smoke
      suite with its result bundle kept as an artifact.
- [x] Search folds case, diacritics and stroked letters, so `dong` finds `Đồng` and `cafe` finds
      `Café`, with the highlight ranges still pointing at the original characters.
- [x] The package declares a base language and ships a String Catalog, and the strings handed to
      AppKit — accessibility labels, spoken state, menu titles — go through it rather than being
      whatever was typed.
- [x] The git plugin's porcelain-v2 parser is three functions with six tests, written before the
      split; it had none.
