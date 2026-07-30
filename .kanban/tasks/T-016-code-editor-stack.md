# T-016: Code editor stack (kero parity) + `SlotContent.file`
> Clicking a file in the explorer opens it as a tab in a real editor: STTextView + tree-sitter syntax highlighting + save, the way kero does it.

- **priority**: high
- **effort**: XL

## Depends on
T-014 (the explorer needs somewhere to open a file into).

## Why

kero opens a file tab into `SourceTextEditor` — STTextView with `STPluginNeon` for
tree-sitter highlighting (`refrerences/kero/kero/SourceTextEditor.swift`,
`SyntaxHighlighting.swift`, `SyntaxHighlightPlugin.swift`, `FileViewerView.swift`;
the STTextView fork itself is vendored at `refrerences/kero/Vendor/STTextView` with
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

- STTextView is vendored at `poc/Vendor/STTextView` (kero's patched 2.3.11). SwiftPM
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
- [ ] Editor state (scroll + selection) survives pane switches — kero keeps it on `FileTab`; Tenon has nowhere to hang it yet (`SlotContent.file` is a pure value), so it needs a per-slot store first
- [ ] External file changes are not watched — edit elsewhere and the pane keeps its loaded copy

## Coordination takeover — T-020

T-016's editor is marked landed above, and `FileSlotView.swift` has had no recent
writes. T-020 is taking over only:

- `poc/Sources/TenonApp/FileSlotView.swift`
- NEW `poc/Sources/TenonApp/FileDocumentIO.swift`
- focused `FileDocumentModel` / `FileDocumentIO` tests

T-020 will not touch `poc/Package.swift` or the editor/highlighting dependency stack.
