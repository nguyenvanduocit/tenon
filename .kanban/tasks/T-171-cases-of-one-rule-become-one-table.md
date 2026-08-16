# T-171: Cases of one rule become one table
> Seven groups where several tests drive one rule with different inputs collapse into a
> table each; groups where each test pins a different rule stay as they are.
- **priority**: low
- **effort**: S

## Why

Follow-up to [T-170](T-170-a-fitness-test-that-pins-behaviour-not-source-text.md), which
measured duplication with exact-match-after-normalisation and found only 16 cases. That
measure was too narrow. Re-measured with real similarity (`difflib` ratio over normalised
bodies, Jaccard prefilter):

| threshold | groups | tests that would disappear if every group merged |
|---|---|---|
| ≥0.95 | 43 | 49 |
| ≥0.90 | 58 | 66 |
| ≥0.85 | 71 | 83 |
| ≥0.75 | 97 | 123 |

Merging all 83 was refused after reading them. **154 tests sit in those 71 groups and 50 of
them (32%) carry their own doc comment explaining why they exist** — they share a shape, not
a meaning. `AgentCallerAdmissionTests` is the clearest case: four tests are all one line of
`XCTAssertNil(admit(...))`, and they separately refuse a human typing at an agent pane's
shell prompt, a chain reaching `launchd` (including the `pid 0` a zeroed struct reads as),
an empty ancestry, and a pane with no agent in it. Those are four attack paths with four
names, and a table would turn them into four array elements. The same holds for
`AgentReadingSilenceTests` (silence vs ceiling), `AppStatePathsTests` (bundle trust vs
environment override), and `AgentLaunchCommandTests` (control characters vs absolute path).

What is left is the honest set: groups that are genuinely **one rule evaluated at several
inputs**, where the test name adds nothing the table's `why` column cannot carry.

## Criteria
- [x] Seven groups merged, **11 tests fewer** (2289 → 2278), each table carrying a `why`
      string per row so a red case still says which input broke:
      | file | merged | now |
      |---|---|---|
      | `LauncherListHeightTests` | 3 | `testTheListAsksForExactlyItsRowsSeparatorsAndPaddingUpToTheCeiling` |
      | `FilePaneKindTests` | 3 | `testTheExtensionDecidesTheRendererAndTheEditorTakesTheRest` |
      | `SlotAccessibilityValueTests` | 2 | `testTheSpokenValueDescribesWhereThePaneIsAndHowMuchItCovers` |
      | `AgentLensFileLinkTests` | 3 | `testEverySpellingOfAResolvingPathBecomesAFileLink` |
      | `AgentLensFileLinkTests` | 2 | `testASuffixPointsIntoTheFileAndOnlyTheLineIsCarried` |
      | `DiffRowsTests` | 3 | `testSplitAlignsTheTwoSidesAndPadsTheShorterOneWithAGap` |
      | `AgentLensMarkdownTests` | 2 | `testTextThatOnlyLooksLikeStructureStaysOneParagraph` |
- [x] No group merged where the members pin different rules. Left alone, by name:
      `AgentCallerAdmissionTests` (four attack paths), `TerminalJobTerminationTests`,
      `AgentReadingSilenceTests` (silence vs ceiling), `AppStatePathsTests` (bundle trust vs
      environment override), `AgentLaunchCommandTests` (control characters vs absolute
      path), `EditableFieldDraftTests`, `WorkspaceDefaultContentTests`, `PermissionBypassTests`,
      `AgentHookAdmissionTests`, `RunloopHealthTests`, `SpatialLayoutTests`.
- [x] No file touched that another session holds. `git status` shows only the six merged
      files and this task file.
- [x] `swift test` green — **`Executed 2278 tests, with 0 failures`, exit 0** — and each
      merged table watched to fail on a wrong expectation.

## Mutation receipts — every table was watched to fail

One wrong value planted in each of the six tables, all in a single run. Six failures came
back, one per table, each naming the row that broke — which is the property that had to hold
before merging was safe, because a table that reports only "this test failed" would have
traded fault localisation for a smaller number.

| table | planted | reported |
|---|---|---|
| `LauncherListHeight` | 122 → 999 | `("122.0") is not equal to ("999.0") - a single section draws no separator: 4·28 + 10` |
| `FilePaneKind` | `.gif` → `.text` | `("image") is not equal to ("text") - /repo/anim.gif should render as text` |
| `SlotAccessibilityValue` | span text | `("…2 by 3 cells") is not equal to ("…9 by 9 cells")` |
| `AgentLensFileLink` | path → missing | `("[]") is not equal to ("[file:///workspace/Sources/App.swift]") - a cited path with a line must render as a file link` |
| `DiffRows` | `"Z"` → `"WRONG"` | `… - one line out, three in: the gap is on the left` |
| `AgentLensMarkdown` | added `"- a real bullet"` | parsed as `.list(…)`, not `.paragraph` — the parser really does tell a bullet from emphasis |

All six files restored byte-identical (`cmp -s` clean).

## Owner / files (agent lock)

**RELEASED 2026-08-16 18:0x by session `2700a0db`** — four criteria met, full suite 2278 / 0.
No file is claimed by this task now.

Held while the work ran and now free: `LauncherListHeightTests.swift`, `FilePaneKindTests.swift`,
`SlotAccessibilityValueTests.swift`, `AgentLensFileLinkTests.swift`, `DiffRowsTests.swift`,
`AgentLensMarkdownTests.swift`. Nothing held by T-144, T-141, T-140, or T-135 was written.
