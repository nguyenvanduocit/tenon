# T-106: The domain tags say what is true, and the vocabulary earns its size
> Measure the `@domain:` layer against real session ground truth, then repair what the
> measurement finds wrong: tags contradicted by their own callers, and domains so small
> that a filename grep would have found the file faster.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)

Released 2026-08-10 15:1x by session `36faa18c`. No files are held.

## Why

The layer was measured, not assumed. Two ground truths, both from data already on disk:

**How it is actually used.** Across every Claude Code and Codex session in this repo ending
on or after 2026-08-07 (the day the tags landed): Claude ran 1 766 searches, **21** of which
mentioned `@domain` and **1** of which used a tag to find code. Codex ran 1 228 searches,
24 mentioning a tag, **11** of them real retrieval — and Codex is the one that followed the
two-step recipe in `docs/domains.md` (`rg -l '@domain:.*row-list'` then a symbol grep).
Classifying all 74 tag-touching commands: 16 % locate code, 84 % maintain the tag layer
itself.

**How well it locates code.** Ground truth is the set of source files one session actually
edited (76 sessions, ≥2 tagged files each). Starting from the first file's domains:

| starting set | recall | precision | F2 |
|---|---|---|---|
| `@domain` tags, 22 domains | 53,6 % | 19,0 % | **39,3** |
| split into 25 narrower domains | 35,4 % | 22,5 % | 31,8 |
| merged into 7 broad domains | 64,7 % | 9,8 % | 30,5 |
| same directory (free) | 60,9 % | 4,7 % | 18,1 |
| filename first word (free) | 27,5 % | 41,6 % | 29,5 |

The vocabulary is at a better operating point than either direction from it, and beats both
free heuristics. So the size is not the problem and this task does not change it — an
earlier plan to split `intent-bus` and `workspace-model` was written, scored, and abandoned
because splitting cost 18 points of recall to buy 3 of precision.

What the measurement does find: tags that name a domain none of the file's callers live in,
and four domains covering ≤2 files, where the tag narrows nothing a filename would not.

## What the small domains turned out to be

The plan above said to retire `field-draft`, `terminal-teardown` and `row-list` because each
covers one or two files. Reading their entries in `docs/domains.md` retired that plan
instead. Each states a product rule a person would recognise — who owns the characters in a
field while someone types, what a closing pane owes the processes it started, one row
vocabulary so a list of files is the same list everywhere — and each is named in the
`Excludes` line of other domains: `terminal-teardown` in four, `row-list` in two. "One file"
is a code fact, and `docs/domains.md` opens by saying a domain is deliberately not one.
Folding them would have deleted a product boundary to improve a grep.

`ChangesPanelView` carrying `row-list` looked like a contradiction of that domain's own
Excludes until the exclusion was read properly: it names the **git plugin's** panel, a form
with a commit box and a verb on every row. The native changed-file list is exactly what
`repository-read` and `editor-and-diff` both point *at* `row-list` for. Tag correct, left
alone.

## Criteria

- [x] `EmptyStateCard` carries the domain its callers live in, not `agent-lens` — no
      `agent-lens` file references it; `WorkspaceStageView` and `BuiltInSlotViews` do, and
      `command-surface` is defined as "the palette and its providers, the launcher…".
- [x] `AppStatePaths` names what it resolves — plugin inventory trust, writability and
      standing consent, plus the app and workspace state roots — rather than `diagnostics`,
      a domain about "what the app records about its own health", which it records none of.
- [x] The ≤2-file domains are kept, with the reasoning above recorded rather than the fold.
- [x] `CLAUDE.md` and `docs/domains.md` state the counts the tree actually has (200 files,
      65 over 400 lines, longest 2,545) and name the MARK rule's blind spot: 49 of those 65
      long files declare no MARK at all, so the assertion passes on 41,879 lines — more than
      half the tree, including its five longest files — without checking anything.
- [x] `DomainTagFitnessTests` 5/5 green.
- [x] Full `swift test` green: **1841 tests, 0 failures** (2026-08-10 15:07, shared tree with
      T-071/T-100/T-105 work in it).
