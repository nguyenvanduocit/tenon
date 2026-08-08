# T-086: The git panel draws its own rows
> Closed as "won't do", user-directed. The git panel is a view; it does not earn a change to the row vocabulary.

- **priority**: low
- **effort**: S
- **status**: closed 2026-08-08 (option 3)

## The decision

**Option 3: leave it.** The git panel is a *form* — commit box, branch controls, bulk actions —
that happens to contain a list. Forms are what `body` is for, so T-085's boundary was the right
one and this closes without a code change.

The reason is the user's, and it is stronger than "the boundary is fine": asked whether the row
vocabulary should grow a trailing-button field so the panel's `Stage` / `Unstage` / `Discard`
could survive a migration, the answer was that the panel does not need to be an operations
surface at all — *"ta chỉ cần view thôi"*. A vocabulary widened permanently for one call site
whose verbs are not the product's priority is a bad trade in both directions.

Option 2 was started and reverted rather than left half-built: `RowTrailingAction`, its decoder,
and its renderer are not in the tree.

## What is NOT decided here

The git panel's inline `Stage` / `Unstage` / `Discard` buttons **ship today**
(`plugins/git/main.js:420-434`). "We only need view" is a decision about where effort goes, not
an instruction to delete working behaviour, and nothing here removed it. Making the panel
genuinely read-only is a separate call with its own task.

## The bigger question this surfaced, left open

Two panes list the same files:

- **Changes — working tree** (`ChangesPanelView`, host-native): `TreeRowsView` rows, no verbs,
  drag-out. Migrated by T-085.
- **Git** (`dev.tenon.git`, plugin): hand-built `hstack + badge + button` rows, inline verbs, a
  form around them.

T-086 asked how a row should be drawn. The larger question is whether both panes should exist.
That is a product call, out of scope here, and worth its own task if the duplication starts to
cost anything.

## Criteria

- [x] A decision recorded between 1, 2 and 3, with the reason
- [n/a] If 1 or 2: the git panel's file rows render through `TreeRowsView`
- [n/a] If 2: the trailing-action field is documented and bounded
- [x] If 3: `docs/domains.md`'s `row-list` Excludes line says why a form's list stays a form

## Original framing, kept for the record

T-085 collapsed two of the three file lists onto one `TreeRowsView`. The third is the git panel,
which builds its rows out of view-tree nodes. It was not migrated with the others because its
rows carry **inline verbs**, and `TreeRowItem` has no trailing-button field: the honest
translation is `menu`, which moves those verbs to right-click. That is a change to how a person
operates the panel, not a change to how it is drawn, and T-085 had no mandate to make it.

T-085 hit a smaller version of the same question in the Changes pane and answered it "no verbs
for now": `Reveal in Finder` and `Copy Path` are already `file.reveal.v1` and
`clipboard.write.v1`, so putting them in a host pane's row menu is new same-owner DIRECT
surface, and the boundary law makes any addition to that inventory a reviewed edit
(`docs/architecture-interaction-boundaries.md:348-360`).
