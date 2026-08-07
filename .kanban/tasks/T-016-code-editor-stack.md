# T-016: Code editor stack (kero parity) + `SlotContent.file`
> Clicking a file in the explorer opens it as a tab in a real editor: STTextView + tree-sitter syntax highlighting + save, the way kero does it.

- **priority**: high
- **effort**: XL

## Depends on
T-014 (the explorer needs somewhere to open a file into).

## Why

kero opens a file tab into `SourceTextEditor` — STTextView with `STPluginNeon` for
tree-sitter highlighting (`references/kero/kero/SourceTextEditor.swift`,
`SyntaxHighlighting.swift`, `SyntaxHighlightPlugin.swift`, `FileViewerView.swift`;
the STTextView fork itself is vendored at `references/kero/Vendor/STTextView` with
`KERO_PATCHES.md` describing the patches). Tenon has no editor stack at all, so a
click on a file currently does nothing but log.

## Notes
- Tenon already carries one remote SPM dependency (`PierreDiffsSwift`), so an SPM
  dependency is an accepted shape here. Check `Vendor/STTextView/KERO_PATCHES.md`
  first — if the patches matter, vendor the fork the same way kero does instead of
  depending on upstream.
- Image files get an image view, unreadable ones an explanatory state — kero models
  this as `FileTab.Content { text, image, unavailable }`.
- The editor is a host-native view driven through `newTab({type:"file", path})`,
  mirroring T-010's `DiffSlotView`. Plugins never touch the editor type (invariant 2).

## Notes from the build

- STTextView is vendored at `Vendor/STTextView` (kero's patched 2.3.11). SwiftPM
  warns `Conflicting identity for sttextview` because STTextView-Plugin-Neon also
  depends on the upstream repo; the local package wins by identity, which is exactly
  what we want (one STTextView, ours, with the patches). SwiftPM says this will become
  an error in a future tools version — the fix then is to vendor the Neon plugin too and
  point its dependency at the local path.
- `TreeSitterTSX` is vendored alongside it (kero's copy) for `.tsx`, which the plugin's
  bundled TypeScript grammar cannot parse.

## Criteria
- [x] `SlotContent.file(path)` + `parseContentSpec` `"file"` branch, with tests — landed in T-014
- [x] STTextView-based editor view with tree-sitter highlighting (`SourceEditorView.swift`, `SyntaxHighlighting.swift`); grammar table covers Swift, JS/TS, JSON, Python, Ruby, Rust, Go, C/C++/C#, CSS, HTML, Java, PHP, shell, SQL, TOML, YAML, Markdown
- [x] Editing + save (⌘S), dirty dot in the pane header
- [x] Image and binary files degrade to a sensible view instead of garbage text
- [x] Inherited-query highlighting: the full `SyntaxHighlightPlugin` is ported, so TypeScript inherits JavaScript and C++ inherits C instead of losing every comment/string/base keyword. The internal query modules (`TreeSitterCQueries`, …) do import under SwiftPM.
- [x] Markdown/HTML/PHP/Rust **injections** — a fenced ```sh block is highlighted as shell
- [x] `.tsx` via the vendored `TreeSitterTSX` grammar (the plugin builds only the typescript half)
- [x] `swift build` clean, app launches and holds an open markdown file with no crash — the exact case the vendored zero-length-range patch exists for
- [x] Editor state (scroll + selection + unsaved buffer) survives pane switches — per-slot `EditorPaneStateStore` (`TenonApp/EditorPaneState.swift`), keyed by (slot UUID, path) so a pane whose content changed inherits nothing; owned by `ContentView`, recorded by `SourceEditorView`'s coordinator, restored via kero's first-layout pattern; asserted in `EditorPaneStateStoreTests` + the restore half of `FileDocumentExternalChangeTests`
- [x] External file changes are watched — the EXISTING `PathWatcher` per open text file (parent dir, non-recursive, name-filtered), token dies with the pane's `FileDocumentModel`; conflict rule: own-echo ignored / clean pane reloads keeping the user's place / dirty pane keeps the buffer + "Changed on disk — ⌘S keeps your version" badge; asserted in `FileDocumentExternalChangeTests` (see "Remainder design" below)

## Remainder design (criteria 9 + 10) — worker task_b8c77992663c

> Re-verification note on the 8 earlier ticks (2026-07-31): all substantively true in
> the current tree, with one naming drift — `parseContentSpec` no longer exists by
> that name; the `"file"` content branch now lives in the T-024 refactor
> (`WorkspaceIntentProvider.swift:477` maps kind `"file"` → `SlotContent.file`,
> schema in `CoreIntentCatalog.swift:1685`, exercised by `WorkspaceOpenContentTests`).

### Editor state survives a pane switch (criterion 9)

State lives in a NEW `EditorPaneStateStore` (`TenonApp/EditorPaneState.swift`), the
`SurfacePool.titles`/`directories` shape — per-slot state the workspace model must not
learn about — in a store this feature owns (`SurfacePool` itself is claimed by T-027).
It is owned by `ContentView` and threaded to `FileSlotView`/`SourceEditorView`.

**Identity of "the same pane": slot UUID AND path.** An entry is keyed by the slot but
handed back only when its recorded `path` matches what the pane shows now; recording
under a new path replaces the old file's entry outright. So a pane whose content
changed never inherits the previous file's scroll — restoring into the wrong file is
worse than not restoring. Slot UUIDs are never reused, so a closed pane's entry is
inert; an LRU cap (64) bounds the store (invariant 10) without needing the
catalog-prune hook in `TenonApp.swift` (claimed by T-027).

The state carries scroll + selection (the criterion) AND the unsaved buffer: SwiftUI
destroys the pane's view **and its model** on a tab switch, so without the buffer a
switch would silently discard unsaved edits — same data-loss class as criterion 10.
Restore clamps the selection to the loaded text and refuses everything on a path
mismatch.

### External file changes (criterion 10) — the conflict rule

Watcher: the EXISTING `PathWatcher` (T-018), one per open text file, watching the
file's **parent directory non-recursively** filtered to the file's name (FSEvents path
spellings — `/private` aliasing — make exact-path matching fragile; the content rule
below makes a spurious trigger harmless). Per-file rather than per-workspace because
the pane is the owner: the watch handle (`EditorFileWatchToken`) is held by the pane's
`FileDocumentModel`, so it provably dies when the pane closes or switches files —
asserted in `testTextFilesAreWatchedAndTheWatchDiesWithItsPane` /
`testSwitchingFilesReplacesTheWatch` (invariant 10). A hidden pane has no view, no
model, and therefore no watcher; it re-reads the disk on its next appearance, so it
can never show stale content.

**The rule** (`ExternalFileChange.action`, asserted in
`FileDocumentExternalChangeTests`):

1. Disk text == our last-known disk text → **ignore**. That is our own ⌘S echoing
   back through FSEvents (or a touch that changed nothing), never an external edit.
2. Pane clean → **reload silently**, preserving scroll/selection. No user work exists
   to lose; keeping stale text would mean editing a ghost.
3. Pane dirty → **keep the user's buffer, flag the conflict** ("Changed on disk — ⌘S
   keeps your version" in the pane's status corner). Silently reloading destroys the
   user's work — the one outcome that can actually hurt someone — so the user's
   buffer always outranks the disk, and ⌘S resolves the conflict their way,
   explicitly. The disk baseline still advances so repeated events stay quiet, and
   the conflict flag rides the per-slot state so a pane switch cannot silence the
   warning.

## Coordination takeover — T-020 (HISTORICAL — superseded)

An earlier T-020 slice took over `FileSlotView.swift` / `FileDocumentIO.swift` and landed
them; that session is gone and its locks are stale. The current T-020 slice (boundary
audit, worker task_78e0ddf7a663) explicitly does NOT touch these files.

## Owner / files (agent lock)

**RELEASED 2026-07-31 00:13** — worker task_b8c77992663c finished; every file listed
on the board's Done line is free. Uncommitted changes in the tree for this slice:
`FileSlotView.swift`, `SourceEditorView.swift`, `BuiltInSlotViews.swift`,
`ContentView.swift`, `WorkspaceStageView.swift`, `SpatialCanvasView.swift`,
NEW `EditorPaneState.swift`,
NEW `Tests/TenonAppStateTests/EditorPaneStateStoreTests.swift`,
NEW `Tests/TenonAppStateTests/FileDocumentExternalChangeTests.swift` — the
coordinator owns the commit.
