# T-162: A public documentation site Tenon can be learned from

> Tenon is a public repository with no homepage. Everything a newcomer needs is
> spread across `README.md` and 33 engineering documents written for agents, with
> a precedence hierarchy and normative/non-normative labels that mean nothing to
> someone who just wants to install the app and write a plugin.

- **priority**: medium
- **effort**: L

## Owner / files (agent lock)

**RELEASED 2026-08-14 17:1x.** Session `4d775ec5` held `website/**`, `README.md`,
`.kanban/board.md` and this file; all are free. No file under `Sources/`,
`Tests/` or `docs/` was touched — the site reads the tree, it does not change
it, so nothing collided with T-159, T-161, T-160, T-144, T-141, T-140 or T-135.
The site's own ignore rules live in `website/.gitignore`; the repository root's
was never edited.

## Why a separate site instead of publishing `docs/`

`docs/` is the engineering record and stays that way. It ranks documents by
precedence, marks research non-normative, and records superseded decisions —
all correct for the people and agents changing the code, all wrong for a person
deciding whether to install a terminal. The site is written for the second
reader and cites the first where a reader needs the full contract.

## Decisions

- **VitePress 1.6.4**, not 2.0.0-alpha.19 (`npm view vitepress`, checked
  2026-08-14: 2.0 has been in alpha since 2025-11 and the newest alpha is 12
  days old). A public site does not ship on an alpha.
- **Diátaxis**: guide / plugin authoring / reference / concepts as four separate
  top-level sections, each with one job.
- The **intent reference is generated**, never hand-typed: 51 canonical intents
  live in `Sources/TenonCore/CoreIntentCatalog.swift` and their schemas are built
  in Swift. A hand-written copy would be wrong within a week.

## Criteria

- [x] `website/` builds to static HTML with `bun run build` — 92 pages, clean
      under `ignoreDeadLinks: false`
- [x] Landing page states what Tenon is and who it is for, with install paths
- [x] Getting started carries a first-run walkthrough a newcomer can follow
- [x] Plugin authoring section has a plugin that runs when copied out
- [x] Intent reference is generated from the tree, with the generator committed
- [x] CLI reference covers every `tenon-cli` verb — the usage block is lifted
      from `main.swift`, so it cannot fall behind a new one
- [x] Concepts section explains workspace/tab/pane, the intent bus, and the
      plugin boundary without requiring the normative documents
- [x] Local search, dark mode, and mobile layout all work in the built output —
      measured, 0 overflow and 0 console errors over 14 renders
- [ ] Deploy is prepared for Cloudflare Pages and confirmed with the operator
      before anything is published — **settings recorded in `website/README.md`;
      awaiting the operator, deliberately not run**

## What the writing found in the tree

Documenting a thing reads it differently from changing it. Five things this
turned up, none of them the site's own bug:

1. `network.fetch.v1` and `workspace.identity.set.v1` declare `programmatic`
   (which includes `cli`) yet answer `intent_not_found` to the installed 0.1.0
   build. The generator labels them honestly rather than filing them with the
   genuinely plugin-only contracts.
2. `intent_not_found` is byte-identical for a hidden contract and a name that
   does not exist — confirmed against `totally.made.up.v1`. Correct, and worth
   documenting so nobody reads it as a bug.
3. `docs/plugin-author-guide.md:99` uses `result.value.stdout`; the contract
   returns `standardOutput.text`. Not corrected here — that file belongs to the
   engineering record and to whoever owns it.
4. `tenon-cli rename` exists in the tree and not in the published build. The CLI
   page says so and gives the `intent send` form that always works.
5. `workspace.state.v1` pages at 256 nodes, and reading one page returns a
   plausible wrong answer rather than an error. The bundled `git` plugin carries
   a comment about shipping exactly that bug; the quickstart now teaches the
   cursor walk.
