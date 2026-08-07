# T-028: The diff view renders only the rows on screen
> `DiffSlotView` builds every hunk and every line of a diff eagerly, so a large diff
> blocks the window. Flatten the diff to an indexed row list and render it lazily.

- **priority**: high
- **effort**: S

## Owner / files (agent lock)
session `a65c2304` — **LOCKS RELEASED**; every file below is free again. The list stays as
the record of what this task changed.

Files changed:
- NEW `Sources/TenonCore/DiffRows.swift` — the pure flattening: `DiffRowID`, `DiffRow`,
  `unified`/`split`, `paired`, `widestTexts`/`displayWidth`, `maxLineNumber`
- `Sources/TenonApp/DiffSlotView.swift` — `LazyVStack` + stable row identity, measured
  column widths, and the two redundant diff passes removed
- `Sources/TenonCore/LineDiff.swift` — `stat(old:new:)` → `stat(_ hunks:)` only
- NEW `Tests/TenonCoreTests/DiffRowsTests.swift` — 20 tests
- `Tests/TenonCoreTests/LineDiffTests.swift` — the `stat` test follows the new
  signature, plus one multi-hunk case
- `Sources/TenonApp/DiffSnapshot.swift` — the measurement instrument: the diff sides
  become overridable by file path (`TENON_DIFF_SNAPSHOT_OLD`/`_NEW`/`_SPLIT`) and the
  offscreen render reports its layout and capture time, which is how the before/after below
  was taken on the real view from a headless shell

## Why / evidence
- `Sources/TenonApp/DiffSlotView.swift:269` is a plain `ScrollView` wrapping
  `ForEach(Array(model.hunks.enumerated()), …)` at `:287` and `:302`, which itself walks
  every line at `:304` and `:330`. Nothing is lazy: opening a big diff materializes the
  whole view tree. (HIGH — read the file)
- The same repo already knows better: `ChangesPanelView.swift:357` uses `LazyVStack`. So
  this is an inconsistency inside our own codebase, not a considered trade-off.
- Kero v0.1.26 shipped exactly this fix: *"Opening a large diff no longer freezes the
  window: diffs render only the rows on screen."*
- Row identity today is `enumerated().offset`, which is stable enough for an eager tree but
  is the classic cause of full rebuilds once the container is lazy.

## Criteria
- [x] A pure rule in `TenonCore` flattens (hunks × lines) into one indexed row list —
      unified and split/side-by-side — with stable ids, asserted in `TenonCoreTests`
      without a window (hunk headers, context, add, remove, pairing gaps)
- [x] Both diff bodies render through a lazy container; the number of built rows is bounded
      by the viewport, not by the diff size
- [x] `ForEach` keys on the flattened row's stable id, never on `enumerated().offset`
- [x] Measured before/after for a diff of ≥5k changed lines, recorded in this file:
      time to first paint, and that the main thread is not blocked
- [x] Existing diff behaviour unchanged: style picker (`DiffStyle`), per-hunk layout,
      horizontal scrolling, non-ASCII rendering
- [x] `swift build` + `swift test` green (pre-existing reds excepted)
- [ ] One human look at a real large diff, since a headless shell cannot screenshot.
      The offscreen renders below are the closest a headless run gets: they are the real
      `DiffSlotView` through `NSHostingView`, not a mock.

## What landed

`DiffRows` (`Sources/TenonCore/DiffRows.swift:65`) is the pure rule: `unified(_:)` and
`split(_:)` flatten `[DiffHunk]` into one `[DiffRow]` — hunk header, unified line, or
side-by-side pair — and `paired(_:)` moved out of the view so the run-alignment and its
gaps are asserted without a window.

**Identity comes from line numbers, not list position.** `DiffRowID` is
`(kind, old, new)`: `LineDiff` gives every old line at most one row and every new line at
most one row, so the triple cannot repeat inside a diff, and an edit elsewhere in the file
leaves a row's id alone. That is the property `enumerated().offset` lacks and the reason a
lazy container could otherwise rebuild the whole list on each reload —
`testRowIDsComeFromLineNumbersNotFromPositionInTheList` pins it by diffing the same late
edit twice, once with an unrelated early edit inserted above it, and asserting every id
from the first run survives into the second.

**The width laziness gives up is bought back from the content.** An eager stack was as
wide as its widest child for free; a lazy one has never built the row a thousand lines
down. So `DiffRows.widestTexts(_:column:limit:)` names the widest candidates per column by
`displayWidth` (East Asian wide and emoji graphemes count two cells, so a CJK line is not
ranked behind a longer ASCII one), and `DiffContentModel` measures just those few with the
row's `NSFont`. Verified against a fixture whose longest line is row 1: it ends exactly one
trailing pad before the divider, unclipped.

## Two redundant diff passes, found while measuring

Instrumenting `recompute()` showed a 5130-changed-line diff running **Myers four times**
to open once:

1. `DiffSlotView` called `model.reload()` from `onAppear` although `DiffContentModel.init`
   had already resolved — every opened diff was computed twice.
2. `LineDiff.stat(old:new:)` re-ran the whole edit-script search to count `+N -M`.

`stat` now summarises the hunks it is given (`LineDiff.swift:47`) — every changed line is
in exactly one hunk, so the counts are identical without a second search — and the pane
diffs on construction and on a new request, nothing else. Both are in the before/after
below; laziness alone would have left three quarters of the block in place.

## Measured — 2700-line file, 2565 lines rewritten (5130 changed lines)

Real `DiffSlotView` in an offscreen `NSHostingView` at 900×560, `swift build` debug
(unoptimised — treat the ratio, not the absolute, as the result). `layout` is the first
`layoutSubtreeIfNeeded`, which is where a non-lazy container builds every row.

| | before | after | |
|---|---|---|---|
| unified, first layout | 65 772 ms | 63–114 ms | ~600× |
| unified, capture | 1 654 ms | 39–172 ms | |
| split, first layout | 14 097 ms | 140–295 ms | ~60× |
| split, capture | 898 ms | 42–142 ms | |

Main thread: the remaining blocking work is one `LineDiff.hunks` pass on the main actor
(3.8 s in this debug build for this diff), down from four. **Not fixed here** — moving it
off-main changes the pane's loading lifecycle (the `.inline` path becomes asynchronous like
`.git`, and the snapshot instrument has to wait for content), which is its own change, not
this one. Worth a follow-up task; the row rendering no longer contributes to it.

Also found and **not** fixed: `LineDiff`'s Myers keeps a full trace (`D` copies of a
`2(n+m)+1` array), so memory grows with `D × (n+m)` — a 6000-line file rewritten end to end
would need gigabytes. That is why the fixture above is 2700 lines with a high change
fraction rather than 6000 lines. A linear-space refinement (Hirschberg / Myers §4b) is the
fix, and it belongs with the off-main work above.

## Evidence

- `swift build` exit 0.
- `swift test` **653 tests, 0 failures** — twice, at 22:33 and 22:39. `DiffRowsTests` 20/20,
  `LineDiffTests` 15/15. The three T-021 provenance/consent reds earlier sessions reported
  are green in this tree; nothing red was left for anyone else.
- Offscreen renders of the same 5130-line diff before and after are **pixel-identical** in
  unified. Split is identical except the left column is ~40 pt narrower — the measured
  width is exact where the `Grid` was generous; a fixture with the longest line first
  confirms nothing is clipped.
- Non-ASCII: a fixture mixing CJK, Vietnamese diacritics and emoji renders each fully, with
  the column sized to the CJK line.
- Launch smoke: app alive 8 s on a private `TENON_SOCKET_PATH`, empty log.
- Not committed.
