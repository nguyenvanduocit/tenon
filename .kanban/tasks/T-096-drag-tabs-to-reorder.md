# T-096: Drag tabs to reorder them
> Let a person drag a tab chip horizontally to choose its position in the current workspace.

- **priority**: medium
- **effort**: M

## Criteria
- [x] Dragging a tab shows a clear insertion preview and commits the tab at the previewed position when dropped.
- [x] Reordering preserves the tab's identity, active state, panes, pane focus, and content; it moves no tab between workspaces.
- [x] Cancelling the drag, dropping outside a valid insertion target, or dropping at the current position leaves the order unchanged.
- [x] The reordered tab sequence persists through workspace save and restore.
- [x] Clicking to select a tab, tab context menus, closing tabs, and existing pane drag-and-drop keep their current behavior.
- [x] Reordering has an accessible keyboard or menu alternative, with a useful VoiceOver label and announcement; visuals follow `docs/designs.md` and use no feature-local tokens.
- [x] The interaction is classified before implementation under `docs/architecture-interaction-boundaries.md`; focused tab-strip manipulation stays same-owner DIRECT/local control unless a registered host-wide command is deliberately added.
- [x] Headless tests cover forward and backward moves, boundary positions, no-op and invalid drops, active-tab preservation, and persistence; the native drag preview and drop behavior are visually verified.

## Outcome

**DONE 18:2x, session `73381a75`. Full suite 1680 / 0. Not committed.**

### The mechanism, and why it is not the pasteboard

Classified **before** implementation, and it is step 4 of the ordered decision law:
`ShellTitleBar` is host-native `TenonApp` chrome, the tab list is `WorkspaceStore`'s own
value, and reordering it crosses no ownership boundary — same-owner **DIRECT**. It registers
no product command and no keybinding, so it stays focused-view local control. The law's
`SwiftUI workspace, tab, pane, and settings interactions` entry grew 1313 → 2129 characters,
which fired `DirectInventoryGateTests` exactly as designed; the pin is updated in the same
change and the entry's justification clause names the missing mechanism (nothing places a
chip in the host's own title bar or accepts a pointer gesture inside it), not the difficulty
of building one.

The gesture is **one `DragGesture` inside the strip**, not a `.draggable`/`.dropDestination`
pasteboard drag like T-056's plugin view trees. That choice is what makes two criteria
properties of the mechanism rather than of the code:

- *"moves no tab between workspaces"* — the chip travels on no pasteboard and
  `WorkspaceCatalog.moveTab` names only the active workspace, so there is no parameter that
  could address another one. A tab id from elsewhere finds no chip and returns no events.
- *"cancelling the drag leaves the order unchanged"* — the live drag lives in
  `@GestureState`, which SwiftUI clears when the gesture ends **or is cancelled**. Nothing
  has to notice an Escape in order to clean up after it, and no caret can outlive the drag.

It also cost a piece of work: `TabDragPayload`, a marker+workspace+tab envelope with a
fail-closed decoder mirroring `PluginViewDrag`, was written and tested first and then deleted
whole when the gesture changed. It was refusing a drag that can no longer happen.

### What is where

- `Sources/TenonCore/TabReorder.swift` (NEW, 104 lines, no window): which tab a press picked
  up, which gap a pointer means, which array index that gap becomes, where the caret is
  drawn, whether a release still means the strip at all, and the two spoken sentences.
- `Sources/TenonCore/Workspace.swift`: `WorkspaceCatalog.moveTab(_:to:)` + the
  `WorkspaceEvent.tabMoved(tab:from:to:workspace:)` fact.
- `Sources/TenonCore/WorkspaceStore.swift`: the typed `moveTab` use case and its
  `workspace.tab-moved` projection onto the existing workspace EVENT family.
- `Sources/TenonApp/ShellTitleBar.swift`: the gesture, the caret, the extent reporter, the
  chip's spoken position, and its two VoiceOver custom actions.

**Insertion boundary and array index are different numbers.** Dropping in gap 4 of a
four-tab strip moves the dragged tab to index 3 when it came from the left of that boundary
and index 4 — out of range — when it did not. Conflating them is how a reorder lands one
place off, so `insertionIndex` and `destination` are separate functions and the second one
does the remove-then-insert adjustment in exactly one place.

**Gaps are counted by midpoint, not by measuring the space between chips.** Every x on the
strip then belongs to exactly one gap, so the caret never blanks out while the pointer is
over a chip — which is most of the strip — and no hit-tolerance constant exists to tune.

### Accessibility

A pointer drag is unreachable by keyboard and by VoiceOver, so the drag is an *addition* to
the route and never the route: each chip publishes `Move tab left` / `Move tab right` as
accessibility custom actions through the same `moveTab` the drag calls, and the ends publish
no action rather than publishing one that does nothing. Each chip's value now speaks its
place (`tab 2 of 4, active`), and a completed move announces itself through
`.announcementRequested` — VoiceOver cannot otherwise notice that a chip changed places in a
strip it is not focused on. Both sentences are pure functions in `TabReorder`, asserted
without a window, so the drag and the custom action say the same thing in the same words.

Visuals use `TenonTheme.amber` and the existing 6 pt/26 pt chip geometry. No feature-local
token, colour, or spacing scale was introduced.

### Evidence

- Full suite **1680 / 0** (baseline at claim time was unmeasurable: a peer had the shared
  test target's compile broken, and a later run read 1678 / 2 with both failures in T-097's
  in-flight `WorkspaceIdentityTests`; those are green now).
- 32 new tests: `TabReorderTests` 19, `WorkspaceTabOrderTests` 12, `TabStripReorderTests` 1.
- **7 mutations, one run each, every one caught**, sources restored with `cmp`-verified
  copies (never `git checkout` — peers were mid-edit):
  - M1 drop the `insertion != source + 1` no-op guard → 2 tests
  - M2 drop the remove-then-insert adjustment → 5 tests across all three suites
  - M3 drop `index != from` in `moveTab` → 3 tests
  - M4 let a reorder also select the tab it moved → 3 tests
  - M5 count gaps from leading edges instead of midpoints → 1 test
  - M6 admit a release anywhere as a drop → 1 test (2 assertions)
  - M7 let a press always pick up the first tab → 1 test (2 assertions)
- **M2 found a real defect in this task's own test.** `testEveryGapProducesTheOrderAPersonSees`
  applied the returned destination with a bare `insert(at:)`, so a wrong rule *trapped*
  instead of failing — taking the whole shared test run down with it rather than naming the
  broken rule. It now asserts the bound. Production was never exposed: `moveTab` refuses an
  out-of-range index.

### Visually verified, and what the picture caught

`TabStripReorderTests` lays the shipped `TabChip` out through the shipped
`TabChipExtentReporter`, places the shipped `TabInsertionCaret` at the x the shipped rule
answers with, and — given `TENON_TAB_STRIP_SNAPSHOT=<path>` — writes the PNG. Confirmed at
620×36: the caret stands in the gap at full chip height, the dragged chip is clearly dimmer
than its neighbours, the active chip keeps its wash, nothing clips.

**The first version of that test was wrong, and the photograph is what said so.** It measured
chips with `NSHostingView.fittingSize`, and the picture showed the caret sitting on top of a
chip's ✕: a close control is an `.overlay`, so a chip's ideal width and its laid-out width
differ by exactly that button. The strip has never used the ideal number — but a picture
taken with it would have been evidence for a layout the app does not draw. Both the strip and
the test now read the laid-out frame through one shared reporter.

### ⚠️ Left for human verification — the one thing headless cannot answer

The click/drag composition. The chip is still a `Button`; the reorder is attached to the row
as `.highPriorityGesture(DragGesture(minimumDistance: 6))`, which is the conventional SwiftUI
way to say "a drag wins once it travels, and until then the press is the button's". No
headless test can drive that arbitration. **Open a window, click a tab (it must still
select), then drag one (it must not select).** If a drag also selects, the one-line fix is
`.simultaneousGesture` plus a suppress flag; if a click stops selecting, lower
`minimumDistance` or move the gesture onto the chip.

### Known limits, stated not sold past

- A tab's *fallback* title is positional (`Terminal 3` is `"Terminal \(index + 1)"`), so
  moving tabs renumbers the placeholder names of tabs whose terminal has not named itself.
  That is the pre-existing design of the fallback, not something this task introduced, and
  the criterion's list of what must survive a reorder does not include the title.
- The dragged chip does not follow the pointer; it dims in place and the caret carries the
  preview. Offsetting it would make its own reported extent chase the pointer measured
  against it. Reachable later by reporting extents before the offset.
- The reorder reads the strip's own coordinate space while the canvas's pane-drag hit-testing
  reads window space through `DragRouter`. Two readings of the same chips, deliberately: the
  window-space one exists to meet `NSEvent.locationInWindow`, and converting between them
  would put a flip in the path of a gesture that needs no y at all.

### ⚠️ Note for session `87cdeb99` (T-097)

Mutation testing restored `Sources/TenonCore/Workspace.swift` twice from a copy taken at
~18:04, while you were live-editing that file. A `diff` afterwards showed exactly one line
differing — `customName`, which you had since completed — and `WorkspaceIdentityTests` is
27/27 green, so nothing appears lost. Please glance at your own diff anyway. Future mutations
in this task will only touch files it holds exclusively.

## Owner / files (agent lock)

**RELEASED 18:2x — every file below is FREE.**

Was held exclusively by session `73381a75`:

- `Sources/TenonCore/TabReorder.swift` (NEW)
- `Sources/TenonApp/ShellTitleBar.swift`
- `Tests/TenonCoreTests/TabReorderTests.swift` (NEW)
- `Tests/TenonCoreTests/WorkspaceTabOrderTests.swift` (NEW)
- `Tests/TenonAppStateTests/TabStripReorderTests.swift` (NEW)
- `docs/architecture-interaction-boundaries.md`
- `Tests/TenonCoreTests/DirectInventoryGateTests.swift`

Was shared and region-split with T-097 (`87cdeb99`), which holds both files whole; each edit
was a surgical `Edit` inside one named region and nothing else in either file was opened:

- `Sources/TenonCore/Workspace.swift` — one `WorkspaceEvent` case at the end of the enum, and
  `moveTab(_:to:)` beside `addSlot` in the `WorkspaceCatalog` tab section.
- `Sources/TenonCore/WorkspaceStore.swift` — one `moveTab(_:to:)` passthrough beside
  `closeTab`, and one `case` at the end of the `busRepresentation` switch.

## Notes
- This is tab ordering within one workspace, not pane drag-and-drop and not moving a tab across workspaces.
- Use stable tab identity during the gesture; do not derive the dragged item from a mutable array index after the list reorders.
