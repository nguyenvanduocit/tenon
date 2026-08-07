# T-076: One header per pane
> A pane draws ONE chrome header. Content — built-in and plugin alike — contributes items into
> its `leading` and `trailing` slots instead of drawing a second bar inside the body.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
**No lock. Every file this task touched is FREE.** Session d396aade ran steps 1–4 and 6 and
released on 2026-08-07. Newly free and worth naming because they were held longest:
`PaneHeaderSchemaTests.swift`, `PaneHeader.swift`, `PluginRuntimeValueParsing.swift`,
`PluginRowsView.swift`, `PaneHeaderStore.swift`, the three PaneHeader test files in
`TenonAppStateTests`, and `InteractionBoundaryFitnessTests.swift`.

Untracked, needs `git add` on the next commit that includes this work — 13 new files plus the
design record, verified against `git status --untracked-files=all`:

```
Sources/TenonCore/PaneHeader.swift          Sources/TenonApp/PaneHeaderBar.swift
Sources/TenonCore/PaneHeaderItem.swift      Sources/TenonApp/PaneHeaderCommand.swift
                                                Sources/TenonApp/PaneHeaderLayout.swift
Tests/TenonCoreTests/PaneHeaderTests.swift  Sources/TenonApp/PaneHeaderProjection.swift
Tests/TenonCoreTests/PaneHeaderSchemaTests.swift
Tests/TenonAppStateTests/PaneHeaderLayoutTests.swift
Tests/TenonAppStateTests/PaneHeaderProjectionTests.swift
Tests/TenonAppStateTests/PaneHeaderStoreTests.swift
Tests/TenonAppStateTests/PluginPaneHeaderRouteTests.swift
Sources/TenonApp/PaneHeaderStore.swift      docs/design-pane-header.md
```

⚠️ **Do not `git add -A`.** Several tasks have uncommitted work in this tree — T-071 in the two
Agent Lens files, T-081 in `plugins/claude-sessions/main.js`, and the automation task across
`TenonApp.swift` / `AutomationSlotView.swift`. Add the paths above plus the modified files this
task actually edited, and nothing else.

**RELEASED 17:1x — no file is claimed by this task any more, including the two Agent Lens files.**

Historical record of that claim, kept because another session's work is still uncommitted in
those files: session d396aade re-claimed `AgentLensView.swift` and `AgentLensSession.swift`
from 13:5x for step 5, user-directed. T-071's claim on them is treated as expired: every file that
task claimed for its Agent Lens half had been untouched for 20–22 hours when this was taken
(`AgentLensView.swift` 08-06 17:38, `AgentLensSession.swift` 08-06 18:02, `AppIntentRuntime.swift`
08-06 16:25, `docs/design-open-handlers.md` 08-06 15:25, against 08-07 13:48). The one recent touch
in T-071's file list, `TenonApp.swift` at 08-07 12:57, belongs to the automation task — its
`setPaused:` edit broke the build at `TenonApp.swift:44:36` and was observed directly.

T-071's uncommitted work in both files (+1213 / +160 lines) is backed up byte-identical at
`scratchpad/t071-backup/` and **no `git checkout` will be run on them** — that would destroy the
peer's work outright. If T-071 wakes up, restore from there and split the edits.

Also claimed for the same round, user-directed: `plugins/git/main.js` and
`plugins/claude-sessions/main.js` — they lost nothing in the migration (verified: zero
`subtitle`/`actions` at HEAD) but gain headers now, which is new feature work rather than migration.

## Design
`docs/design-pane-header.md` — the committed design record: schema, both interaction
classifications, geometry and the overflow rule, the plugin-facing API with a worked example,
what each pane publishes, and the verification table. It describes what shipped.

User decisions taken 2026-08-07:
- **Two slots**, `leading` + `trailing`. No third slot for verbs: it would render as the tail of
  `trailing` with no distinct layout, fold, or hit-test rule — two names for one operation.
- **A header control focuses its pane** on click; ✕ stays the exception.
- **The Agent Lens inspector becomes a body panel**, not a popover.
- **`slotHeaderHeight` 31 → 34**, for an honest `.controlSize(.small)` inset.
- **Sequencing:** steps 1–4 + 6 now; AgentLens when T-071 releases it.

## Where this stands

**Landed: steps 1, 2, 3, 4 and 6. Full suite 1313 / 0** (step 4 left it at 1300 / 0; step 6
added the five fitness tests below, and eight more arrived from concurrent tasks).

⚠️ Two intermediate runs showed 3 then 2 failures in
`TenonIntentCoreTests/IntentKernelLatencyBudgetTests.swift` — an untracked file a peer was
writing mid-run. It passes in isolation and the final full run is clean. Not this task's, and
not a regression.

A pane draws one header. `PaneHeaderItem` and `PaneHeader` are pure `TenonCore` values whose
bounds are applied by `PaneHeader.admitting(leading:trailing:)` — the one policy path, with the
storing initialiser private, so a built-in Swift producer is clamped by exactly the code a
plugin is. `PaneHeaderLayout.solve` is a pure function; `PaneHeaderBar` is the one renderer,
mounted twice (the card's AppKit host, and `DiffSnapshot`'s offscreen frame).
`WorkspaceStageView.body` reads `paneHeaders.headers` — the invalidation contract.

Migrated: **Diff**, **Docs**, **Changes**, **File** (host-native, through `PaneHeaderStore` +
the typed `PaneHeaderCommand`), and **browser**, **file-explorer**, **kanban** (plugin, through
a `header` key inside the existing `views.set` CONTRIBUTION). Deleted: `ViewAction`,
`subtitle`, `actions`, `browserBar`, `BrowserBarView`, `PluginRowsView.header`,
`ChangesPanelView.header`, `DiffSlotView.controlBar`, the Docs strip,
`FileSlotView.statusBadge`, and the dead `ChangesSlotView` / `GitChangesModel`.

**Nothing on the `tenon` global changed.** `testRuntimeExportsOnlyTheClassifiedPublicSurface`
and `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` are byte-identical and green —
that is the receipt the public surface did not grow.

Step 6 added five fitness tests to `InteractionBoundaryFitnessTests.swift`, each falsified by
reintroducing what it forbids and watching it go red:

| test | holds |
|---|---|
| `testExactlyOneImplementationDrawsAPaneHeader` | `PaneHeaderBar(` appears in exactly `["DiffSnapshot.swift", "PaneHeaderBar.swift"]`, and the fixed-height in-body strip signatures appear in exactly `["AgentLensView.swift"]` |
| `testSupersededPaneHeaderPathsAreGoneFromShippedCode` | `ViewAction`, `browserBar`, `BrowserBarView`, `ChangesSlotView`, `GitChangesModel` appear nowhere under `Sources/` or `plugins/` |
| `testPaneHeaderCodeStaysContributionAndDirect` | the seven pane-header sources reach no intent path and mint no principal |
| `testBuiltInHeaderItemsNeverMintRawActionStrings` | `PaneHeaderCommand(rawValue:` appears only at the router, and each of the enum's tokens is spelled only by the enum (tokens are read out of the source, so a new case is swept automatically) |
| `testPaneHeaderDocumentStatesCurrentSchema` | `docs/design-pane-header.md` states the shipped schema and teaches no superseded key |

Docs corrected in step 6: `design-plugin-host-capabilities.md` (its canonical author-facing
`tenon.views.set` example publishes a `header`), `design-plugin-settings.md` (the browser's
chrome), `plugins/browser/main.js`'s comments, and `docs/README.md` (index row). A sweep of
the whole `docs/` tree for the superseded keys now returns nothing. `design-command-palette.md`'s
`subtitle`/`actions` were checked and left alone: those are palette RESULT fields, a separate
live API (`PluginRuntime.swift:1777`, `:1801`).

### The one carve-out, and why it expires

`testExactlyOneImplementationDrawsAPaneHeader` is two assertions. The first is a SUBSET check:
no file may carry a fixed-height in-body chrome strip unless it is the file that still declares
the last known bar — that is what catches a new second header. The second is an EQUALITY check
on the set of files declaring `struct AgentLensModeBar`, asserted to be **exactly**
`["AgentLensView.swift"]`. The moment step 5 deletes that type the equality turns RED and forces
the carve-out to be deleted in the same edit.

The carve-out is keyed on the TYPE NAME, never on the bar's height. It was written keyed on
`.frame(minHeight: 36)` and that was wrong: 36 is T-071's *uncommitted* value, while HEAD carries
`.frame(minHeight: 34)`. A commit of only T-076's files would have been RED on a fresh checkout —
the sweep returns `[]` there while the expectation demanded one entry. A fitness test whose
expectation depends on a number another task is actively moving fails for reasons that have
nothing to do with what it guards.

Falsified: appending `.frame(height: 31)` to `PaneHeaderLayout.swift` turns the subset half red
and names that file in the failure message; restored byte-identical afterwards, verified by `cmp`.

### Two defects the closeout round itself introduced, since fixed

1. **A new flake of the class the round existed to remove.**
   `PluginPaneHeaderRouteTests` asserted an ORDERED array over `host.log`, but
   `routePluginHeaderAction` sends each action into its own unstructured `Task`, so N clicks are
   N tasks each suspending into the host actor and then the plugin runtime actor. Swift
   guarantees no ordering between them. Failed 1-in-3 full-suite runs, 0-in-6 isolated. Both
   tests in that file now compare as a `Set` — plus an explicit count assertion, because a set
   comparison alone would let a duplicate line hide a lost report. This is not a weakened
   assertion: a header control reports its own fact, never a position in a sequence, so order was
   never the property under test.
2. The carve-out coupling described above.

## Step 5 — landed. Every step of T-076 is done.

**Full suite 1365 / 0.** `AgentLensModeBar` and `AgentLensPalette` are deleted, `showsInspector`
and `inspection` live on `AgentLensViewModel`, the inspector is a body panel with a dismiss
scrim, the two `agentLens.*` cases are in `PaneHeaderCommand`, and the header is published from a
pure projection gated on `isAgentDetected`. **No pane in the app draws a second header row** —
`.frame(height: 31)`, `.frame(height: 27)` and `.frame(minHeight: 36)` are all absent from
`Sources/TenonApp`, and the test-46 carve-out is gone.

`git` and `claude-sessions` also gained headers (user-directed, new feature rather than
migration), which is how the accessibility gap below was found.

**T-071's uncommitted work survived intact**, measured rather than assumed: of the 890 non-blank
lines it had added to `AgentLensView.swift`, 807 are present verbatim and all 83 absent lines are
exactly the block this task was chartered to delete. `AgentLensSession.swift`: 125 of 130, the 5
absent being doc-comment prose rewritten in place. Its `showsInspector` / `inspection` state was
promoted onto the view model rather than dropped.

⚠️ **`git show HEAD` is the WRONG baseline for the Agent Lens files.** HEAD holds a stale
544-line version with no split view and no inspector. The correct baseline is the byte-identical
copy at `scratchpad/t071-backup/`. Anyone auditing this migration against HEAD will reach false
conclusions.

## The accessibility half, and what it cost to learn

`.help()` on macOS becomes an accessibility HELP — a hint — and never a label. The migration
therefore gave every icon-only control a tooltip and no spoken name, and Agent Lens lost three
names to it: its diagnostics warning, its inspector toggle, and `currentActionSummary` — what
the agent is doing right now, the most time-sensitive fact a supervision pane has.

Fixed at the one choke point every tooltip passes through:
`paneHeaderHelp(_:spokenAs:)` now applies `.accessibilityLabel` for `dot` / `image` /
`iconButton` / `toggle` / `menu` (a glyph has no words, so the tooltip IS the name) and
`.accessibilityValue` for `label` / `badge` (their text is already the name; the tooltip is the
detail beside it, which is the shape the old mode bar used). Pinned by
`testEveryHeaderTooltipAlsoCarriesASpokenName`, falsified by injecting a bare `.help(…)`.

**Two mechanism claims made during this task were WRONG, and measurement settled both:**
1. *"`.help` on a label inside a `.segmented` Picker is dropped by the SwiftUI→AppKit bridge."*
   False. It arrives as `NSSegmentedControl.toolTip(forSegment:)`. The real cause of the shipped
   no-op was `.help("")` on the picker AROUND the segments, which REPLACES every per-segment
   tooltip with its own.
2. *"A tooltip on a non-interactive item cannot reach the pointer, because `PaneHeaderHostView`
   declines the hit test there."* False. SwiftUI installs one full-bounds `NSTrackingArea` per
   host owned by a `TooltipBridge.DynamicTooltipManager`, and AppKit asks THAT object per point —
   a path independent of `hitTest`. Pinned by
   `testANonInteractiveHeaderItemCarriesItsTooltipIntoAppKit`, which queries the same resolver
   AppKit queries, at each item's own centre.

**What no headless test can hold:** whether AppKit then SPEAKS the label. An `NSHostingView` in
an offscreen borderless window builds no accessibility tree at all — measured by walking it
after `display()`, a runloop turn, and `NSAccessibilityUnignoredDescendant`, all empty. The
renderer's shape is pinned; delivery needs a launch smoke check with VoiceOver.

## Domain tags

All seven new source files are tagged, and `docs/domains.md` declares **`pane-chrome`**:
what a pane says about itself and who may put something there — the vocabulary and its
admission rules, the solver, the renderer, the store, and the typed routing. It excludes the
canvas geometry a pane sits IN (drag, resize, split, focus ring — that is a pane's position,
not its chrome) and the content below the strip. A plugin's right to contribute a header is
`plugin-contributions`; the vocabulary it contributes in, and everything that draws it, is
`pane-chrome`. The two `TenonCore` value files carry both.

`untaggedFileBudget` lowered 153 → 146. `PaneHeaderLayout.swift` is over 400 lines, so its one
`// MARK:` carries its own tag as `DomainTagFitnessTests` requires.

## Follow-up found here, not fixed here
**T-080** — `PluginRuntime.emitLog` does `_ = hostTasks.launch { … }` and discards the line
when the 512-task ledger is full, so `tenon.log` lines are dropped silently under host-task
saturation. Every plugin log line, not only header diagnostics. Deliberately not changed here:
making `emitLog` block risks deadlocking the runtime actor, and the policy is runtime-wide
rather than a header decision. This task bounded its own side — a header emits at most
`PluginParsedHeader.maximumDiagnostics` (16) lines per `views.set`.

## Criteria
- [x] `PaneHeaderItem` / `PaneHeader` are pure `TenonCore` values; every bound is enforced on the
      one construction path so a Swift producer is clamped exactly as a plugin is
- [x] `PaneHeaderLayout.solve` is a pure function: no placement left of the accessory floor, none
      under the resize edges, none overlapping the close button, drag band never starves
- [x] `WorkspaceStageView.body` reads `paneHeaders.headers` — the invalidation contract
- [x] `testRuntimeExportsOnlyTheClassifiedPublicSurface` and
      `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` pass **unmodified**
- [x] A plugin publishes a header through the existing `views.set`; clicks return through the
      existing `onSelect` / `onSubmit`
- [x] Pane drag, resize, double-click fill-width, right-click menu, and ✕ all behave as they do
      with no header contributed
- [x] `ViewAction`, `subtitle`, `actions`, `browserBar`, `BrowserBarView`, `PluginRowsView.header`,
      `ChangesPanelView.header`, `DiffSlotView.controlBar`, the Docs strip,
      `FileSlotView.statusBadge`, `ChangesSlotView` and `GitChangesModel` are deleted
- [x] A fitness test asserts exactly one implementation draws a pane header
- [x] `docs/design-pane-header.md` exists, states the shipped schema, and is gated by a test
- [x] No document teaches a deleted key
- [ ] **Step 5:** `AgentLensModeBar` deleted, the Agent Lens header published, and the test-46
      carve-out removed
- [x] Full suite green after every landed step
