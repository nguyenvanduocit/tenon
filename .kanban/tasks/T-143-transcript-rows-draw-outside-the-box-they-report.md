# T-143: Transcript rows draw outside the box they report
> Agent Lens Chat overlaps every message on the one below it, because one alignment change made a row's drawn content leave the row's own bounds.

- **priority**: critical
- **effort**: S

## Owner / files (agent lock)
Released 2026-08-13 13:1x. Session `a223b39a` held `Sources/TenonApp/AgentLensView.swift`,
`Tests/TenonAppStateTests/AgentSessionLayoutAlignmentTests.swift`, and the PRD-012 pair.

While it was held it overlapped T-141's standing claim on `AgentLensView.swift` (session
`7e46371b`), taken with the risk stated to the operator: T-141 shipped commit `4b1ca5b` on
2026-08-12 22:48 and left the file clean in the working tree, this defect is the fallout of that
same commit, and the operator reported it live from the running app. Doing was at three cards;
this was the fourth, for a shipped regression on the primary reading surface.

## What is wrong

`AgentSpineChrome` — the chrome every Chat row wears — lays its tick rail beside its content with:

```swift
HStack(alignment: .firstTextBaseline, spacing: 8) {   // AgentLensView.swift:799
    ZStack(alignment: .top) { Canvas … ; Button … }
        .frame(width: 18)
        .frame(maxHeight: .infinity)                   // greedy, and holds no text
    content …
}
```

A view with no text resolves `firstTextBaseline` to its **bottom edge**. The rail is greedy in
height, so its bottom is the row height — the number the `HStack` is still computing. The guide
therefore depends on the result of the alignment that reads it. SwiftUI settles that by sizing
against the proposal and placing against the final height, so the row **reports one height and
draws at another**, and a `LazyVStack` stacks the next row over the overflow.

Measured on the shape itself, one row, 380 pt wide, offscreen `NSHostingView`:

| alignment | row bounds | content bounds | content below the row's bottom |
| --- | --- | --- | --- |
| `.top` | `(20, 221.5, 380, 57)` | `(46, 226.5, 354, 47)` | **−5.00 pt** (inside, by the padding) |
| `.firstTextBaseline` | `(20, 217, 380, 66)` | `(46, 269, 354, 47)` | **+33.00 pt** |

33 pt of a one-paragraph row is drawn outside the box that row hands its parent. A real message is
several paragraphs, which is why the operator's screenshot has whole blocks written over each other.

`.top` is what this line held from the day it was written until `4b1ca5b`, whose message never
mentions the change. That commit's own thesis is to stop measuring text per row; a baseline guide
asks every row for a text measurement, so `.top` serves its stated goal as well as this one.

## Criteria
- [x] A headless test mounts the shipping `AgentSpineChrome` and fails on the shipped alignment
- [x] Chat rows draw inside the bounds they report, at both narrow and wide pane widths
- [x] The tick still sits on the row's first line of text
- [x] `AL-FR-050` states the rule, with a scenario in `agent-lens.feature`
- [x] Full suite green

## Receipt

`AgentSessionLayoutAlignmentTests` red first at both bounds — 63.0 pt overflow at 320 pt, 33.0 pt
at 860 pt, content starting 52.0 pt below the row — then **11 / 0**, with the eight pre-existing
cost tests in that file unmoved. Full suite **2102 tests / 0 failures**, twice (126 s, 128 s).

Owed: no photograph of the assembled Chat pane. There is no snapshot hook for the Chat account —
`TENON_TIMELINE_SNAPSHOT` covers only Timeline — so `AL-NFR-010`'s installed visual receipt stays
open for this surface, as it is for the rest of PRD-012.
