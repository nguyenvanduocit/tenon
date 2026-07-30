# TreeSitterTSX

The tree-sitter **TSX** grammar — TypeScript *with* JSX — exposed as a local
SwiftPM package so Tenon can link `tree_sitter_tsx()`. Its library product
remains `TreeSitterTSX`, backed by the uniquely named
`TenonTreeSitterTSX` module.

## Why this is vendored

tree-sitter-typescript ships **two separate grammars**: `typescript` and `tsx`.
They aren't dialects of one parser — `typescript` has no JSX node types at all
(`jsx_opening_element` appears 0 times in its `parser.c`, 508 times in the TSX
one), because JSX's `<tag>` is ambiguous with TypeScript's `<T>x` type
assertion and the grammar has to pick one. So parsing a `.tsx` file with the
`typescript` grammar turns every element into a parse error and the whole JSX
body of the file renders miscolored.

Tenon's other grammars come from `STTextView-Plugin-Neon`. Its public product
exposes the plugin and its registered languages, while the package's
`TreeSitterTSX` target sits outside that product graph. Tenon therefore exports
the same grammar sources through the standalone `TreeSitterTSX` product and
the uniquely named `TenonTreeSitterTSX` target. This gives SwiftPM and Xcode an
addressable TSX module while both packages coexist in one graph.

The package vendors the parser. TSX's `highlights.scm` is byte-identical to
TypeScript's, which Tenon already reaches through
`TreeSitterTypeScriptQueries`. The JSX captures come from JavaScript's
`highlights-jsx.scm`; `SyntaxHighlighting.highlightsData(for:)` merges the
three.

## Provenance

Copied verbatim from `STTextView-Plugin-Neon` 0.8.1 (commit `5a30db4`),
`Sources/TreeSitterTSX/` — the same revision Tenon pins for the plugin, so the
grammar matches the queries and the tree-sitter runtime the rest of the
highlighting stack uses (grammar ABI `LANGUAGE_VERSION 13`). `Package.swift`
keeps that source layout and header search path, adds the unique
`TenonTreeSitterTSX` module name, and exports it through the `TreeSitterTSX`
library product.

To update, re-copy `include/` and `src/` from the plugin checkout at the
revision Tenon pins:

```sh
cp -R "$CHECKOUTS/STTextView-Plugin-Neon/Sources/TreeSitterTSX/"{include,src} \
  Vendor/TreeSitterTSX/Sources/TreeSitterTSX/
```
