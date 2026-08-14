# T-148: A session you marked outlives the cutoff

> Agent Sessions lets a person mark the sessions that matter, and a marked session keeps
> its place in the pane after the "N most recent" window has moved past it.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-012` [`agent-lens`](../../docs/prds/agent-lens.prd.md) — extends `AL-FR-001`

## Owner / files (agent lock)

Session `2c49b6c2`, claimed 2026-08-14 10:5x. Checked against T-144, T-141, T-140 and
T-135: none of them holds a file below. T-140 holds `PluginRuntime.swift` and
`PluginRuntimeBootstrap.swift` — this change needs neither, because `tenon.storage` is
already a shipped scoped facility.

- `plugins/claude-sessions/main.js`
- `Tests/TenonCoreTests/AgentSessionFavouritesTests.swift` (new)
- `docs/prds/agent-lens.prd.md`, `docs/prds/agent-lens.feature`
- `.kanban/tasks/T-148-a-session-you-marked-outlives-the-cutoff.md`
- `Sources/TenonApp/PluginViewSnapshot.swift` — added mid-task, one wait condition: the
  snapshot stopped at "the section has a body", which a still-scanning pane satisfies with
  an empty container, so this pane photographed blank every time. It now waits for content
  and the 20 s deadline still ends the wait.

## Why the cutoff is the whole problem

`plugins/claude-sessions/main.js:153` slices the scan to the `limit` setting (10/25/50/100
most recent). A favourite that only re-sorted inside that window would disappear from the
pane exactly when it becomes worth remembering — three weeks after the work, which is the
case a person marks a session *for*. So the mark has to survive the cutoff, not decorate it.

- Claude: the listing already walks the whole transcript directory before slicing, so a
  marked session is kept out of the slice at no extra I/O.
- Codex: the SQLite index is queried with `ORDER BY mtime DESC LIMIT n`, so a marked thread
  outside that window needs one bounded second query, `... AND id IN (…)`.

## Decisions taken with the operator (2026-08-14)

1. A favourite outlives the recent cutoff. (The alternative — sort-to-top only — was
   rejected as self-defeating.)
2. The pane shows a **Favourites** group above a **Recent** group; with nothing marked the
   pane renders exactly as it does today.
3. Favourites are stored for the whole plugin but **shown for the project that owns the
   pane** (`workspace.pane.owner.v1`), matching how every other part of this pane is scoped.

## Criteria

- [x] A marked session appears in the pane's Favourites group even when it falls outside
      the `limit` most recent — proved for Claude (kept out of the slice) and for Codex
      (fetched by ID with a second bounded query).
- [x] Marking and unmarking persists through `tenon.storage.set` and is read back on the
      next activation.
- [x] A favourite recorded against another project never appears in this pane.
- [x] A rejected storage write leaves the committed list visible and reports itself.
- [x] The favourites record is bounded, and the bound is asserted.
- [x] Every row's mark control carries its state in words, not colour or glyph alone.
- [x] `swift test` green; `agent-lens.prd.md` + `.feature` carry the new requirement.

## Evidence

`AgentSessionFavouritesTests` **7 / 0**, driving the shipped `plugins/claude-sessions/main.js`
in a real `PluginRuntime` over a bridge that answers the five intents the manifest declares.
Seven mutations, applied **one at a time** with the file restored between each, every one
reddening the test written for it:

| Mutation | Caught by |
|---|---|
| `recentAndMarked` returns the plain slice | `testAMarkedClaudeSessionSurvivesTheRecentCutoff` |
| `missingCodexFavourites` returns nothing | `testAMarkedCodexThreadOutsideTheIndexWindowIsFetchedByID` |
| the storage write never happens | `testMarkingASessionPersistsAndUnmarkingRemovesIt` (+2) |
| `indexOfFavourite` stops comparing project | `testAFavouriteRecordedForAnotherProjectNeverAppearsInThisPane` |
| a refused write reports nothing | `testARejectedWriteLeavesTheCommittedListVisibleAndSaysSo` |
| the bound is removed | `testTheFavouriteRecordIsBounded` |
| the mark control becomes a bare glyph | `testTheMarkControlNamesItsStateInWords` |

The photograph changed the design. The mark first sat in the verb row; at **420×620** a
fourth button broke every label in that row onto two lines, and a control shot taken with
the button removed proved the row was intact before it. The mark now sits on the title
line, which a narrow pane absorbs by wrapping the title one line further, and the verb row
is back to its shipped shape at both **900×620** and **420×620**. `PluginViewSnapshot` had
to learn the difference between "has a body" and "is showing something" first: this pane
publishes an empty container while it scans, and it photographed blank every time.

Full suite **2233 / 0**. Not proved: a mark surviving an app relaunch (asserted at the
`tenon.storage.set` boundary, not end to end), and the Favourites group photographed in the
app — `PluginViewSnapshot` hands every plugin a throwaway state root, so there is no seam
to seed a mark before the shot.

Note on the shared tree: `xcodegen generate` was run for the new test file, and it also
picked up **33 files other sessions had added without regenerating** (T-146/T-147 and
neighbours). `Tenon.xcodeproj/project.pbxproj` therefore carries their entries as well as
mine — the generator writes the whole project or none of it.
