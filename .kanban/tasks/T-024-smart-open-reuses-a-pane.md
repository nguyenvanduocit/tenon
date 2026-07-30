# T-024: Opening a file reuses the tab's editor pane instead of spawning tabs
> Clicking a file in the Files tree lands in the file pane already open in this tab; with no such pane it opens beside the tree. It never opens a tab.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session `fd5aa92f` — **LOCKS RELEASED**, every file below is free again. The list stays as
the record of what this task changed. Note for anyone in `Tests/TenonAppTests/`: that
directory is Xcode-only, so the provider test landed in `Tests/TenonAppStateTests/`, which
is the SwiftPM target that links `TenonApp` and therefore the one `swift test` runs.

Files changed:
- `poc/Sources/TenonCore/Workspace.swift` — `SlotContent` pane-sharing rule (additive)
- `poc/Sources/TenonCore/WorkspaceStore.swift` — `openContent` replaces `showDiff`
- `poc/Sources/TenonCore/CoreIntentCatalog.swift` — new `workspace.content.open.v1`
- `poc/Sources/TenonApp/WorkspaceIntentProvider.swift` — binding + provider method
- `poc/Sources/TenonApp/ChangesPanelView.swift` — one call site (`showDiff` → `openContent`)
- `poc/plugins/file-explorer/{main.js,manifest.json}` — click-to-open path
- `poc/plugins/git/{main.js,manifest.json}` — diff open, so both adapters behave alike
- `poc/Tests/TenonCoreTests/WorkspaceOpenContentTests.swift` — NEW, replaces
  `WorkspaceDiffReuseTests.swift` (deleted)
- `poc/Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift` — NEW
- `poc/Tests/TenonCoreTests/CoreIntentCatalogTests.swift` — inventory 38 → 39
- `poc/Tests/TenonCoreTests/FileExplorerPluginTests.swift` — routed-intent assertion
- `docs/architecture-interaction-boundaries.md`, `docs/design-pane-slots.md` — inventory

## Why

`file-explorer` sends `workspace.tab.create.v1` on every click, so browsing a tree buries
the workspace in tabs. `docs/design-editor.md` already specifies the opposite ("Clicking a
file in the Files pane opens it **beside** the tree"), and `WorkspaceStore.showDiff` already
implements exactly this reuse rule for diffs — the native Changes panel reuses one pane
while the git plugin spawns tabs for the same operation. One behaviour, two public results,
which the interaction boundary law forbids.

A plugin cannot fix this itself: `workspace.pane.content.set.v1` writes only the pane in its
invocation scope, so no plugin can address the editor pane next door. Placement is host
policy, like `terminal.run.v1` resolving a terminal pane.

## Mechanism (ordered decision law)

INTENT. Finite unicast request/reply, one terminal result, crossing the plugin → host
principal boundary; semantic owner is the workspace domain; authority is the existing
`workspace.control` capability; failure is a declared domain error; no lifetime handle.
`showDiff` is deleted in the same slice so one typed service (`WorkspaceStore.openContent`)
backs both the native panel (DIRECT) and the public intent.

## Criteria
- [x] Clicking a file reuses the file pane already open in the active tab
- [x] With no file pane, it splits the active pane — never a new tab
- [x] An empty pane is filled in place; a terminal or plugin-view pane is never hijacked
- [x] The focused pane wins when several panes qualify
- [x] Diff reuse behaviour is preserved, and the git plugin now shares it
- [x] `workspace.content.open.v1` is declared in the doc inventory, the source inventory,
      and every manifest that sends it
- [x] `swift build` clean, `swift test` green

## Evidence

- `swift build` exit 0. `swift test` 574 tests / 3 failures — all three are T-021's
  standing-consent provenance reds (`AppStatePathsTests:84`, `:110`,
  `BundledPluginConsentTests:81`, all `["process.exec.v1"]` vs `[]`), already failing at
  15:12 today before this task's first edit and in files this task never touched.
- 14 new tests, all green: `WorkspaceOpenContentTests` (10, store placement policy) and
  `WorkspaceIntentProviderTests` (4, the public adapter — including that the scope
  pane's tab takes the content, not whatever tab is active, and that a stale pane scope
  fails closed on `dev.tenon.core.pane-not-found`).
- `FileExplorerPluginTests` drives the real shipped `main.js`: clicking a file row routes
  `workspace.content.open.v1` with that path, "Open to the Side" still routes
  `workspace.pane.split.v1` + `workspace.pane.content.set.v1`.
- `ShippedPluginsTests` holds every manifest's `intents.uses` exactly equal to the literal
  sends in its JS, so the file-explorer and git declarations cannot drift from the code.
- **Live app, driven through the CLI adapter** (`tenon-cli`, pid 44500): a workspace holding
  only the tree pane `BF46FB43`. Opening `README.md` added pane `338951AA` in the SAME tab
  `E1209FAB`; opening `CLAUDE.md` next left the pane count at 2 and the tab count at 1,
  with `338951AA` now showing `CLAUDE.md`. Reuse, not a tab, on the real binary.
- Not verified: a literal mouse click in the tree (no assistive access in this shell). The
  JS→intent half is covered headlessly, the intent→pane half on the live app.
