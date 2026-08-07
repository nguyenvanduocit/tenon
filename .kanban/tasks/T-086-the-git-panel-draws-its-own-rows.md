# T-086: The git panel draws its own rows
> The last hand-built file list in the product — and moving it changes how the panel is operated, so it is a product call, not a refactor.

- **priority**: low
- **effort**: S

## Why this was left out of T-085

T-085 collapsed two of the three file lists onto one `TreeRowsView`. The third is the git
panel, which builds its rows out of view-tree nodes — `card` + `hstack` + `badge` + `button`
(`plugins/git/main.js:366-380`, `sectionCard` at `:383`). It is the only list left that
answers "what does a right-click do" differently, and the only one whose rows cannot be
dragged to a terminal.

It was not migrated with the others because its rows carry **inline verbs**: `Stage`,
`Unstage`, `Discard`, one button per row. `TreeRowItem` has no trailing-button field, and the
honest translation is `menu` — the file explorer's pattern, where those verbs move to
right-click. That is a change to how a person operates the panel, not a change to how it is
drawn, and T-085 had no mandate to make it.

## The actual decision

Which of these the git panel should become:

1. **Verbs move to the context menu.** Rows become `TreeRowItem`s: badge → `accessory`,
   `Stage`/`Unstage`/`Discard` → `menu` (Discard `destructive: true`). Dense, consistent with
   the explorer, drag-out for free — but a discoverable button becomes a hidden one, and
   staging is the panel's primary verb.
2. **Rows grow a trailing action.** Add a bounded trailing-button field to the row vocabulary,
   so a row can keep one visible verb. Keeps discoverability, but every list in the product
   then has to answer whether it wants buttons in its rows.
3. **Leave it.** The git panel is a *form* — commit box, branch controls, bulk actions — that
   happens to contain a list. Forms are what `body` is for. Then T-085's boundary is the right
   one and this task closes as "won't do", which is a legitimate outcome.

## The same question, from the other side

T-085 hit a smaller version of this in the Changes pane and answered it "no verbs for now":
`Reveal in Finder` and `Copy Path` are already `file.reveal.v1` and `clipboard.write.v1`, so
putting them in a host pane's row menu is new same-owner DIRECT surface, and the boundary law
now makes any addition to that inventory a reviewed edit
(`docs/architecture-interaction-boundaries.md:348-360`). Whoever takes this task is deciding
for BOTH panes at once: what a row in this product may offer, and through which mechanism.
Deciding it once, here, is better than two panes answering it differently a month apart.

## Criteria

- [ ] A decision recorded between 1, 2 and 3, with the reason
- [ ] If 1 or 2: the git panel's file rows render through `TreeRowsView`, staging verbs still reachable
- [ ] If 2: the trailing-action field is documented in `docs/design-plugin-views.md` and bounded
- [ ] If 3: `docs/domains.md`'s `row-list` Excludes line says why a form's list stays a form
