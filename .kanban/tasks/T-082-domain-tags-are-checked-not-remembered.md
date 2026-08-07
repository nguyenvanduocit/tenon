# T-082: Domain tags the suite checks, not agents remember

> A product-ontology layer code cannot derive — `@domain:` tags backed by a controlled
> vocabulary and a fitness test, so the map rots red instead of rotting silently.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)

Session e8690053 released everything it held at 14:5x. **FREE**: `docs/domains.md`,
`Sources/TenonCore/PluginHost.swift`, `Tests/TenonCoreTests/DomainTagFitnessTests.swift`,
`CLAUDE.md`, `AGENTS.md`.

`docs/domains.md` and the budget constant are shared surfaces by design — every agent that
tags a batch edits them. Take them, do not claim them.

## Why

Retrieval by grep is lexical and one-hop. Two measurements decided the shape:

- `rg '^import ' Sources/TenonCore` names only *external* modules. Swift gives files in one
  module free visibility, so `PluginHost.swift → Workspace.swift` has **no textual edge**.
  155 files expose exactly one inter-module edge. Structure does not narrate itself here.
- Which domain a file serves is a **product** judgement, not a code fact. No AST derives it.

So a hand-written layer is justified. The failure mode it must survive is measured, in this
repo: **31 of ~35 populated `## Owner / files` blocks were stale** against 2 tasks actually
in `Doing` — ~89% rot for metadata whose only enforcement was a sentence in CLAUDE.md.
Hence the rule: the tag layer ships with the test, or it does not ship.

## Shape

- `docs/domains.md` — controlled vocabulary. Every entry carries an **Excludes** line; without
  a stated boundary a tag is a guess at write time.
- File tag on every source file; `// MARK:` sections additionally tagged in files > 400 lines
  (55 of 155 today, max 3134). MARK is Swift's own convention and is **enumerable**, which is
  what makes block-level tags checkable at all.
- `DomainTagFitnessTests` — three decidable assertions plus a coverage ratchet.

## Known limit — state it, do not sell past it

Nothing catches *"this file is tagged `plugin-host` but should also carry `plugin-events`"*.
That omission is exactly the original complaint (edit login, miss the database). Tags improve
the **starting set**; they do not certify completeness, so the traversal step stays mandatory.

## Verification

`swift test --filter DomainTagFitnessTests` in the real tree: **5 tests, 0 failures**. That
run compiled TenonCore with the `PluginHost.swift` edits, so the build is clean with them.

Green is not evidence a fitness test works, so each assertion was falsified against a mutated
copy of `Sources/` — every one fired on its own mutation and only on it:

| Mutation | Expected red | Result |
|---|---|---|
| budget 154 → 153 | ratchet | FAIL `untagged=154 budget=153` |
| drop `## plugin-events` from the vocabulary | used-but-undeclared | FAIL `PluginHost.swift: plugin-events` |
| add `## ghost-domain` | declared-but-unused | FAIL `unused=["ghost-domain"]` |
| strip `@domain:` off one MARK | MARK coverage | FAIL `PluginHost.swift:2288` |
| tag written `Plugin_Host` | slug shape (+ undeclared) | FAIL both |
| baseline, unmutated | — | 5 PASS |

The first run of the real XCTest found a defect in the test itself: pointed at a source tree
it could not read, **four of five assertions passed on nothing**. Exactly the vacuous green
this layer exists to prevent, inside the thing meant to prevent it. `sourceFiles()` now
throws `SourceScanFoundNothing` instead of returning `[]`, and an empty scan fails all five
loudly — verified by running against an empty directory.

## Criteria

- [x] `docs/domains.md` exists with 5 domains, each with an Excludes line
- [x] `PluginHost.swift` carries a file tag and a tag on every `// MARK:` section
- [x] Fitness test: every used domain is declared; every declared domain matches ≥1 file;
      every MARK in a tagged >400-line file carries a tag; untagged count cannot grow
- [x] Rule written into `CLAUDE.md` and `AGENTS.md`, including the traversal step
- [x] `swift build` clean, `swift test` green on the scope touched
