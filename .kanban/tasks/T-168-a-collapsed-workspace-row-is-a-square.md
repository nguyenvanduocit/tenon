# T-168: A collapsed workspace row is a square, not a stripe

> The icon rail draws each workspace in a 38×46 rectangle; its fill and selection should read
> as a tile the same width as the rail leaves it.

- **priority**: medium
- **effort**: XS

## Owner / files (agent lock)

**DONE 2026-08-16 01:5x, session `03300f8f`. ALL LOCKS RELEASED** — `WorkspaceSidebarView.swift`,
`SidebarResizeTests.swift`, and `workspace-shell.prd.md` are free. Not committed.

## Why 38

Two numbers already in the tree agree on it, so none is invented:

- the rail leaves the row `SidebarResize.collapsedWidth` (48) minus
  `WorkspaceSidebarLayout.collapsedHorizontalInset` × 2 (5) = **38 pt** of width, so 38 pt of
  height is the square;
- `docs/designs.md:105` contracts a **two-line utility row at 36–40 pt**, which is exactly
  what the expanded row is (name over tab count). At 46 the row sat outside its own contract.

So `rowHeight` derives from `collapsedRowWidth` rather than carrying a literal: change the
rail width or its inset and the mark stays square instead of quietly becoming a rectangle
again.

## Criteria

- [x] `WorkspaceSidebarLayout.rowHeight == WorkspaceSidebarLayout.collapsedRowWidth`, asserted
      rather than commented — `testACollapsedWorkspaceRowIsSquare`.
- [x] The row height stays inside `designs.md`'s 36–40 pt two-line utility row band, asserted —
      `testTheWorkspaceRowKeepsTheTwoLineUtilityRowBand`, red first at `46.0 > 40.0`.
- [x] Expanded row still shows its 29 pt mark, name, and tab count without clipping —
      photographed at 232 pt and at 110 pt (`SidebarResize.minWidth`), not inferred.
- [x] Collapsed rail photographed at 48 pt, before and after; the selected row's fill measures
      **38.0 × 38.0 pt** read off the after PNG.
- [x] `swift test` **2291 tests, 8 failures**, all eight another session's in-flight Agent Lens
      work (`AgentCLIRetryTests`, `AgentReadingOptionsTests`, `AgentSessionTimelineTests` over
      their modified `AgentSessionTimeline.swift` / `AgentTimelineSynthesis.swift`). Zero in
      this task's scope: `SidebarResizeTests` **8 / 0** and `SidebarFooterTests` both passed
      inside that run. Reported to that owner's files, not touched.

## Evidence

- RED first: `SidebarResizeTests.swift:32` — `XCTAssertLessThanOrEqual failed: ("46.0") is
  greater than ("40.0")`, 2 failures, before the constant moved.
- The number is borrowed twice over, not invented: `SidebarResize.collapsedWidth` (48) −
  `collapsedHorizontalInset` × 2 (5) = 38, and `docs/designs.md:105` contracts a two-line
  utility row at 36–40 pt.
- Snapshots (`TENON_SIDEBAR_SNAPSHOT`): rail at 48×420 before and after, 48×600 after so the
  selected mark clears the footer, 232×420, and 110×420.
- A peer had the shared test target failing to compile for ~3 minutes mid-session
  (`AgentSessionTimelineTests.swift`, ten errors). Waited it out rather than touching their
  files; the full-suite number above is from the run after they restored it.
