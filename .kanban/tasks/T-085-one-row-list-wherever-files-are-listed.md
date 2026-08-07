# T-085: One row list, wherever files are listed
> The Changes pane hand-draws a file tree that the file explorer already draws better; make one row component both use.

- **priority**: medium
- **effort**: M

## Why

Three separate code paths draw an indented list of files today:

| Surface | Rows come from | Drawn by |
|---|---|---|
| Changes pane | `ChangesPanelView.swift:483-609` — own `TreeBuilder`, own `collapsed` set | own `row()` / `treeRow()` |
| File Explorer | `plugins/file-explorer/main.js:169-185` → `items[]` | `PluginRowsView.swift:17-228` |
| Git panel | `plugins/git/main.js:366-380` | view-tree renderer (`card` + `hstack` + `badge`) |

The drift is visible: indent 9pt vs 12pt, font 11 vs 11.5, a full-width hover rectangle vs a
4pt pill. It is also functional, not only cosmetic — the Changes pane has **no context menu,
no drag-out, and no selection state**, all of which `PluginRow` already implements
(`PluginRowsView.swift:109-110`, `192-228`). Every affordance the explorer gains, the Changes
pane silently does not.

Both views are composed from the same file (`BuiltInSlotViews.swift:79` and `:450`) and both
live in `TenonApp`, so this crosses no interaction boundary. It is invariant 6 —
one typed semantic implementation — applied to a view.

## Design

`PluginRowItem` cannot express what the Changes pane needs: a trailing status badge with a
tint (`M` amber, `?` muted, `A` green) and a section heading (`STAGED 3`). Those two fields
are the whole of the work.

The type is renamed with them: a row list that a host-native pane renders through is not a
*plugin* row, and leaving `Plugin` in the name would make the next reader ask which plugin
owns the Changes pane. The rename is mechanical — 8 source references, 4 in `project.pbxproj`.

```
TreeRowItem
  kind: .row | .sectionHeader      // NEW
  id, label, depth, icon, expanded, menu, editing, placeholder, selected, path
  detail: String?                  // NEW — muted secondary text ("rnd/agent-lab/engine")
  accessory: RowAccessory?         // NEW — (text: "M", tint: ColorToken)
```

`detail` and `accessory` are additions to the PUBLIC `tenon.views.set` items schema, so they
carry the same obligations as any public vocabulary change: documented in
`docs/design-plugin-views.md`, decoded fail-soft like every other token field (an
unrecognised tint degrades to `.default` rather than dropping the row), and bounded.

### Verbs

A first pass gave the Changes rows a context menu — Reveal in Finder, Copy Path — for parity
with the explorer. It was pulled back before landing, and the reason is worth keeping: both
verbs already exist as the canonical intents `file.reveal.v1` and `clipboard.write.v1`, so
writing them into a host pane is NEW same-owner DIRECT behaviour. The boundary law
(`docs/architecture-interaction-boundaries.md:348-360`) records that this inventory went 11 →
17 entries and 3,363 → 10,788 characters "ambient, not decided", and now requires a labelled
justification clause for any addition. Reusing a row renderer does not earn that edit, and it
is not a call to make as a side effect of one.

Nothing was lost that a person reaches for: the shared row carries `path`, so a Changes row
can be **dragged** to Finder or to a terminal. `ChangesRowPlanTests` asserts the empty menu
and states this reason, so inverting it means moving the law and its pin in the same change.
T-086 carries the open question.

**Out of scope, deliberately:** migrating the git panel's rows. Its rows carry inline
`Stage` / `Unstage` / `Discard` buttons, which `TreeRowItem` does not express and which
`menu` would replace with right-click — a change to how that panel is operated, not a
refactor. Recorded as a follow-up so the choice is the user's, not a side effect of this task.

## Criteria

- [x] `TreeRowItem` carries `kind`, `detail`, `accessory`; `RowAccessory` reuses `ColorToken`
- [x] The decoder reads `detail` / `accessory` / `kind` from a plugin's `items`, fail-soft
- [x] `TreeRowsView` renders `detail`, the trailing accessory, and a section header
- [x] `ChangesPanelView` builds `[TreeRowItem]` and renders through `TreeRowsView`
- [x] The Changes pane gains drag-out, selection, icons and the explorer's row geometry
- [x] Its rows publish NO menu, and a test says why — see "Verbs" above
- [x] Tree/flat toggle and collapse-by-directory still work from the pane header
- [x] `docs/design-plugin-views.md` documents the two new fields
- [x] `docs/domains.md` declares `row-list`; new/renamed files carry the tag; budget lowered
- [x] `swift test` green, no regression against baseline

## Owner / files (agent lock)

Released 2026-08-07 18:5x — task complete, every file below is free.

## Evidence

- baseline before the change: **1379 / 0**
- every suite touching this change, self-run at close: **70 / 0** (`TreeRowItemTests`,
  `ChangesRowPlanTests`, `ShippedPluginsTests`, `WorkspaceScopedViewStateTests`,
  `PluginViewInstanceTests`, `DomainTagFitnessTests`, `DirectInventoryGateTests`,
  `InteractionBoundaryFitnessTests`)
- 6 mutations, 6 caught: accessory bound removed, unknown `kind` mis-mapped, `A` tinted amber,
  heading emitted after its files, seeded pane given a path, row id stripped of its section prefix
- rendered offscreen through `TENON_CHANGES_SNAPSHOT` — folder/doc icons, chevrons, 12pt indent,
  section headings with right-aligned counts, tinted status column, single-child chains collapsed

## Not this task's failures

The final full run was **1413 / 2**. Neither belongs to this change; both are recorded here so
their owners see them:

- `AgentLensInputAndSurfaceTests.testAnsweringAListedOptionSelectsAndSubmitsTheChoice` —
  reproducible, `["2"]` against an expected `["2", <CR>]`: answering a listed option stopped
  sending its carriage return. `AgentLensView.swift` was written at 18:45, after this task's
  last source edit at 18:40; the file is claimed by T-071 and was never touched here, and no
  Agent Lens source names `TreeRowItem` or `TreeRowsView`.
- `CallerConsentTests.testConcurrentPolicyApprovalsShareOnePromptAndPersistOneGrant` — passes
  in isolation, so a load flake on a machine running several agents' builds at once. It also
  lives in `TenonIntentCoreTests`, whose target depends on `TenonIntentCore` alone — none of
  this change is in that binary.
