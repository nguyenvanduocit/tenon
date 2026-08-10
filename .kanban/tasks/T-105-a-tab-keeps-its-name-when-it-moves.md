# T-105: A tab keeps its name when it moves
> The fallback name is numbered by position, so reordering two unnamed tabs swaps the chips and swaps the labels back — the move becomes invisible.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-002` command-surfaces — the tab strip's identity, alongside
  `CMD-FR-013`/`CMD-FR-014` (drag reorders)

## Reported

2026-08-10 09:3x, user, on the staging build carrying T-101's fix, immediately after
confirming the drag itself works:

> "tab có thay đổi, nhưng mà tên của tab cũng thay đổi luôn … chính điều đó làm tôi
> trước đó nghĩ là nó không đổi"

Drag Terminal 1 past Terminal 2 and the chips do swap — then the labels swap back, so the
strip reads exactly as it did before the drag. The reorder was working and looked broken.

## Root cause

`ShellTitleBar.tabTitle(for:index:)` derives the fallback from the tab's **place**:

```swift
let terminalTitle = pool.title(for: tab)
if terminalTitle != "Terminal" { return terminalTitle }
return "Terminal \(index + 1)"
```

`Tab` carries `id`, `slots`, `activeSlotID` and nothing that survives a move, so there was
no other number available. T-096 recorded this and exempted itself — "the criterion's list
of what must survive a reorder does not include the title" — which is true of the criteria
and false of the product: a name that follows the position instead of the tab makes the one
gesture the criteria are about unobservable.

## Decision — user-chosen 2026-08-10 09:4x

The number is assigned when the tab is created and never changes. Closing tabs leaves gaps
(`Terminal 1`, `Terminal 3`, `Terminal 4`), which is how Terminal.app numbers its windows.
The rejected alternative was renumbering densely on close: it keeps the numbers tidy and
still changes a tab's name under the person's hands, just at a different moment.

## Criteria
- [x] A tab's fallback name follows the tab through a reorder, in both directions and at
      both ends of the strip — `testATabKeepsItsNumberWhenItMoves`
- [x] Numbers are assigned at creation and gap after a close —
      `testClosingATabLeavesAGapInsteadOfRenamingTheSurvivors`. **Amended from "never
      reused"**: see the limit below, which is what the code actually promises.
- [x] The number survives save and restore —
      `testATabsNumberSurvivesTheDocumentEvenWhenTheNumbersGap`
- [x] A catalog written before this change restores with dense numbers in strip order, and
      keeps them stable from then on — `testACatalogWrittenBeforeTabsHadNumbersRestoresInStripOrder`
- [x] A terminal that has named itself is unaffected — the number is only the fallback;
      `tabTitle(for:)` returns `pool.title(for:)` untouched whenever it is not `"Terminal"`
- [x] Tabs created by every route get one: `newTab`, a workspace's first tab, and a pane
      dragged out into a tab of its own — `testEveryRouteThatMakesATabNumbersIt`
- [ ] **Confirmed by hand**: drag `Terminal 1` past `Terminal 2` and read `Terminal 2 |
      Terminal 1` — the one thing no headless seam can answer

## What is where

- `Sources/TenonCore/Workspace.swift` — `Tab.number`, and `Workspace.nextTabNumber` as the
  one place a number is handed out. All three creation routes call it.
- `Sources/TenonCore/WorkspaceCatalogStore.swift` — `TabRecord.number` (optional), written on
  capture, and `tabRecord.number ?? tabs.count + 1` on restore, which is the whole migration.
- `Sources/TenonApp/ShellTitleBar.swift` — `tabTitle(for:)` lost its `index` parameter.

## The limit, stated rather than sold past

`nextTabNumber` is `max + 1` over the tabs a workspace currently holds, so closing the
**highest**-numbered tab hands that number back to the next one. The promise the design keeps
is *no tab's name ever changes*, which is the defect that was reported; it is deliberately not
*no number is handed out twice*. No two chips ever read alike, because a number only returns
once nothing holds it. Strict monotonicity would cost a counter persisted per workspace and
buy nothing a person can see, and the first draft of `Tab.number`'s documentation claimed it
anyway — corrected in the same change.

## Evidence

- Full suite **1735 / 0** at 10:3x.
- Two mutations, each run alone, sources restored from `cmp`-verified copies (never
  `git checkout` — peers are live in this tree):
  - **M1** `newTab` stops numbering → **6** tests red across the order suite
  - **M2** persistence stops writing the number → **4** tests red, including the pre-existing
    catalog round trip
- `InteractionBoundaryFitnessTests` now holds the call site: `ShellTitleBar` must contain
  `"Terminal \(tab.number)"` and must not contain `index + 1`.

## Owner / files (agent lock)

Claimed 2026-08-10 09:4x by session `f673eeeb`:

- `Sources/TenonCore/Workspace.swift`
- `Sources/TenonCore/WorkspaceCatalogStore.swift`
- `Sources/TenonApp/ShellTitleBar.swift` (shared with T-101, same session)
- `Tests/TenonCoreTests/WorkspaceTabOrderTests.swift`
- `Tests/TenonCoreTests/WorkspaceCatalogStoreTests.swift`
