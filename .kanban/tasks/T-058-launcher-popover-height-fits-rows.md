# T-058: Launcher popover height fits its rows
> User screenshot (00:24): the launcher popover stretches near screen height under ten
> rows of content. `LauncherMenu.results` hands its `ScrollView` `.frame(maxHeight:
> listCeiling)` — and a ScrollView is greedy: offered a screen's worth of height inside
> a popover, it takes all of it regardless of content. The list's height must be stated,
> not offered: rows + separators + padding, clamped by the ceiling.
- **priority**: high
- **effort**: XS

## Owner / files (agent lock)
RELEASED 00:3x — done + verified, all files free (`LauncherMenu.swift`,
NEW `LauncherListHeight.swift`, NEW `LauncherListHeightTests.swift`).

## Design
Pure rule `LauncherListHeight` (TenonApp, beside `LauncherSections`): given row count,
section count, ceiling → exact list height = rows·rowHeight + (sections−1)·separator +
list padding, clamped by ceiling. The view reads the same named constants it draws with
(one source), the tests state the arithmetic independently (T-043's tautology lesson).
`results` then sets `.frame(height:)` — the popover ends at its last row, and scrolling
begins only when the rows genuinely outgrow the screen.

## Criteria
- [x] Ten rows / three sections under a tall ceiling → exactly the drawn height of ten
  rows, two separators, and the list padding (independent arithmetic in the test:
  10·28 + 2·9 + 10 = 308)
- [x] Content taller than the ceiling → exactly the ceiling (scroll takes over)
- [x] One section → no separator contribution (4·28 + 10 = 122)
- [x] `LauncherMenu` states the list height from this rule (`.frame(height:)` replaces
  `.frame(maxHeight:)`; the separator rule/padding and list padding now draw from the
  same named constants the rule computes with); red-first on assertions; full
  `swift test` green, build exit 0

## Evidence
- RED 00:28 — stub returning `ceiling` (exactly today's greedy behaviour): 2/3 tests
  fail on assertions (900 ≠ 308, 900 ≠ 122), clamp test green beside them. The stub
  doubles as the mutation proof for the fit rule.
- GREEN 00:30 — build exit 0 (warnings-as-errors), full `swift test` **924 / 0**
  (was 921) in 53 s.
- Root cause, stated: `results` gave its `ScrollView` `.frame(maxHeight: listCeiling)`;
  a ScrollView offered height inside a popover takes all of it, so the popover was as
  tall as the screen allowed regardless of ten rows of content. Height is now computed
  (rows + separators + padding, clamped by ceiling) — the popover ends at its last row,
  and scrolling begins only when rows genuinely outgrow the screen.
- Human-verify (pixels): open `+` or right-click a tab — the popover should hug its
  rows; type a query that matches nothing — the compact empty row is unchanged.
