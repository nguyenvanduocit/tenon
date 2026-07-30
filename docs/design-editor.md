# The file editor

*Landed in T-016. The file explorer (T-014) opens into this.*

Interaction selection follows
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).

Clicking a file in the Files pane opens it **beside** the tree, in a host-native editor:
STTextView with a line-number gutter, tree-sitter colours, the system find bar, and ⌘S.
The next file clicked lands in that same editor, so browsing a tree costs one pane and no
tabs at all.

The pane is `SlotContent.file(path)` — a host content type, exactly like the diff view
T-010 added. Built-in SwiftUI opens it through the typed workspace service DIRECT. A plugin,
CLI, or agent sends `workspace.content.open.v1` with the canonical file-content value and
never touches a document/native editor type; the host resolves which pane takes it
(`docs/design-pane-slots.md`). A caller that wants a specific pane or a new tab instead
still has `workspace.pane.content.set.v1` and `workspace.tab.create.v1`. Every adapter
reaches the same typed workspace mutation.

## Why the dependencies look like this

| Package | Why |
|---|---|
| `Vendor/STTextView` (local) | The editor. Vendored, not pinned remotely — it carries three source patches that exist in no upstream release. |
| `STTextView-Plugin-Neon` (pinned revision) | tree-sitter grammars + query files + Neon's incremental highlighter. |
| `Neon`, `SwiftTreeSitter` | Used directly, because the highlighter glue is ours (below). |
| `Vendor/TreeSitterTSX` (local) | tree-sitter-typescript ships JSX as a *separate* grammar and the plugin builds only the typescript half, so `.tsx` needs its own. |

**The vendored fork is not optional.** `Vendor/STTextView/KERO_PATCHES.md` documents all
three patches; one is load-bearing for us: the Neon highlighter sets a rendering
attribute over zero-length tree-sitter tokens, and `NSTextLayoutManager` raises on an
empty range — several grammars emit such tokens, markdown reliably. Without the patch,
opening the first markdown file crashes the app. The other two fix gutter numbering
drifting off-by-one after a font/colour change, and no-wrap documents that cannot scroll
horizontally when the last line is shorter than the widest one.

A local package with the same *identity* also overrides the copy the Neon plugin depends
on, so exactly one STTextView is ever linked. SwiftPM warns about the conflicting
identity and will make it an error in a future tools version; the fix then is to vendor
the Neon plugin too and point its dependency at the local path.

## Why we don't use the stock `NeonPlugin`

`NeonPlugin(theme:language:)` is one line and it looks like enough. It is not: it loads a
single query file per language, and tree-sitter highlight queries use nvim-treesitter's
`; inherits:` convention. SwiftTreeSitter does not resolve inheritance, so with the stock
plugin **TypeScript loses every comment, string and base keyword** (they are defined only
in JavaScript's query), and C++ loses C's.

So `SyntaxHighlightPlugin` owns the glue and `SyntaxHighlighting.highlightsData(for:)`
concatenates the inherited query ahead of the language's own, letting the specific
captures win. Two consequences worth remembering:

- **JSX goes last, not first.** Its `@tag`/`@attribute` captures have to beat the generic
  `(identifier)` rules both parents apply to the same node.
- **Injections are a second query.** Markdown fences, HTML `<script>`/`<style>`, PHP's
  interleaved HTML and Rust macro bodies get sub-parsed with their own grammar, so a
  shell block inside a README is highlighted as shell.

Queries are compiled once per language and cached (`HighlightQueryCache`). Compiling is
O(grammar complexity), not O(query size) — ~190 ms for Swift's 12 MB parser — so the
first file of a language compiles off the main thread and every later file reuses it.

## Theme

The highlighter gets the plugin's bundled default **colours** (which ship light and dark
asset variants, so they follow the window appearance) paired with an **empty font table**.
The empty fonts are deliberate: otherwise every token is tagged with the theme's font and
the editor's own font is discarded. Colours change, typography does not.

Editor chrome colours come from `TenonTheme`: panel background, `amber` caret, muted
gutter.

## Not done yet

- **Editor state** (scroll offset, selection) does not survive a pane switch. kero hangs
  it off its `FileTab` object; `SlotContent.file` is a pure value with nowhere to put it,
  so this needs a per-slot store first — the same shape `SurfacePool` uses for terminals.
- **External changes** are not watched. Edit a file in another editor and the pane keeps
  the version it loaded.
- Files over 8 MB are truncated rather than paged.
