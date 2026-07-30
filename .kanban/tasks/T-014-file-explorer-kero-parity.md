# T-014: File explorer kero-parity + host capabilities for plugins
> Kill the built-in flat Files view; make the `file-explorer` plugin the only Files view, at kero's quality, through new public host capabilities (fs mutations, reveal/open, clipboard) and a declarative row context menu.

- **priority**: critical
- **effort**: L

## Owner / files (agent lock) — RELEASED

Was session d7f580dd; every file below is free again.

- `poc/Sources/TenonCore/PluginRuntime.swift`
- `poc/Sources/TenonCore/PluginHost.swift`
- `poc/Sources/TenonCore/PluginManifest.swift`
- `poc/Sources/TenonCore/Workspace.swift` (SlotContent.files removal)
- `poc/Sources/TenonApp/BuiltInSlotViews.swift`
- `poc/Sources/TenonApp/EmptyStateCard.swift`
- `poc/Sources/TenonApp/ShellTitleBar.swift`
- `poc/Sources/TenonApp/SpatialCanvasView.swift`
- `poc/Sources/TenonApp/TenonApp.swift` (host command wiring)
- `poc/plugins/file-explorer/**`
- `poc/plugins/core-commands/main.js` (Open Files verb moves to the plugin)
- `poc/Tests/TenonCoreTests/PluginCapabilityTests.swift`
- `poc/Tests/TenonCoreTests/PluginRowMenuTests.swift` (new)
- `poc/Tests/TenonCoreTests/FileExplorerPluginTests.swift` (new)
- `poc/Tests/TenonCoreTests/WorkspaceTests.swift` (`.files` → other content)
- `poc/Tests/TenonCoreTests/CoreCommandsPluginTests.swift`
- `poc/Tests/TenonCoreTests/WorkspaceContentCapabilityTests.swift`
- `poc/Tests/TenonAppTests/SpatialCanvasInteractionTests.swift`
- `docs/design-plugin-host-capabilities.md` (new)

## Why

The shipped Files pane is `FilesSlotView` — a flat `List` with a `‹ back` breadcrumb,
`.skipsHiddenFiles`, no context menu, no rename, no create, no drag, and a stunted
160px preview. kero's `FileTreePanel` (refrerences/kero/kero/RightSidebarView.swift:169)
is the bar: real tree, root header with reveal, full context menu, inline rename and
inline new-file/folder, drag-out, selection follows the open file.

T-005 already set the precedent: `SlotContent.browser` was deleted and the browser
became a plugin. Files gets the same treatment.

## Design

Host owns the dangerous/native verbs; plugins call them (user's call: "code nó trong
core, sau đó cho phép plugin call"):

- `tenon.fs.rename/trash/mkdir/createFile` — pure Foundation, live in `TenonCore`,
  gated behind the existing `filesystem.write`.
- `tenon.shell.reveal(path)` / `tenon.shell.open(path)` — need AppKit, so they follow
  the `WebCommand` pattern: core validates + emits a `HostCommand`, the shell executes
  it. New permission `shell.open` (8th).
- `tenon.clipboard.write(text)` — same command channel, free tier (write-only, reads
  nothing).
- Row context menus are declarative on the row itself: `menu: [{id,label,destructive,
  separatorBefore}]`, and a click routes through the existing `onSelect(itemID, value)`
  with the menu id as the value. One event shape, no new callback surface.
- Inline editing is a row flag: `editing: true` + `placeholder`, committed through
  `tenon.views.onSubmit(viewID, fn(itemID, text))`.

## Criteria
- [x] `fs.rename` / `fs.trash` / `fs.mkdir` / `fs.createFile` each ship a blocked+allowed test pair (invariant 5) — plus a path-escape refusal test on `rename`
- [x] `shell.open` permission added to the known list; `tenon.shell.reveal/open` blocked+allowed pair; `HostCommand` delivered to the shell
- [x] `tenon.clipboard.write` works permission-free and emits a `HostCommand`
- [x] Rows carry a declarative `menu`; selecting a menu entry routes to `onSelect(itemID, menuID)`
- [x] Rows support `editing`/`placeholder`; `views.onSubmit` receives the typed text
- [x] Plugin tree view renders kero-quality: root header (name + path + reveal), context menu, inline rename, inline new file/folder, drag row out as a file URL, selected row highlight — `PluginRowsView.swift`
- [x] `file-explorer` implements the full kero menu: Open, Open to the Side, Open in Default App, Reveal in Finder, Copy Path, cd Here, New File…, New Folder…, Rename, Move to Trash
- [x] `SlotContent.files` and `FilesSlotView` are gone; every call site (EmptyStateCard, ShellTitleBar, SpatialCanvasView, core-commands, AppPreferences, RecentStore, tests) moved off it
- [x] `swift build` clean, full `swift test` green, app launches (verified live: `tenon-cli run file-explorer.open` fills a pane with `plugin-view:file-explorer:tree`, zero permission violations in the app log)

## Extra scope that landed here
- `SlotContent.file(path)` + `FileSlotView` (read-only viewer: text with a line gutter,
  images, an explicit "not UTF-8" state). Needed so clicking a file goes somewhere;
  T-016 replaces the body with the real editor behind the same slot content.
- `core-commands` lost its `open-files` row — the file-explorer plugin registers its own
  "Files: Open", the same rule the browser already followed.

## Found on the way — worth its own task
`tenon.sidebar.*` is now a dead API: no shipped plugin calls it (file-explorer was the
last one) and `TenonApp` never renders `PluginHost.sidebarSections` at all. Either the
shell grows a real sidebar surface or the API should be deleted. Not touched here —
deleting a public API is the user's call, not a side effect of this task.
