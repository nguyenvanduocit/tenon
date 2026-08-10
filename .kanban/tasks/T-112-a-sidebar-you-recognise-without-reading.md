# T-112: A sidebar you recognise without reading
> Workspace tint is drawn on every row, not only the selected one, and an uncustomised
> workspace derives its own colour from its path — so switching stops requiring memory.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-001` workspace-shell (`WS-FR-016`, `WS-NFR-005`)

## Problem

Customisation exists but cannot do the job it was built for. Three separate faults:

1. **The tint rule is inverted against its own purpose.** `WorkspaceIdentityViews.swift:50-54`
   draws the workspace's colour only when `isActive`. Recognition serves the workspace you
   are *not* in yet; the colour appears exactly when you no longer need it. Every other row
   is `TenonTheme.muted` (#8E96A2), so they differ only by the shape of an 11 pt glyph.
2. **Differentiation is opt-in and manual.** `WorkspaceAppearance.default` is `folder` +
   inherited app accent, so every workspace starts identical and stays identical until
   someone hand-assigns a mark and a colour *and remembers the mapping they chose*.
   Remembering a mapping is still remembering.
3. Identity never leaves the sidebar (`WorkspaceMark` has exactly one call site,
   `WorkspaceSidebarView.swift:134`). Out of scope here — filed separately.

## Approach

- `WorkspaceTint` in `TenonCore`: a pure, deterministic path → colour rule with its own
  palette, plus one resolver so no surface spells the "explicit accent beats derived" rule
  itself. Deterministic hashing is written out (FNV-1a) because `String.hashValue` is seeded
  per process and would repaint the sidebar on every launch.
- `accent == nil` stops meaning "follow the app accent" and starts meaning "automatic" —
  the derived colour. Nothing is lost: the five named accents still include whatever the app
  accent is set to, so choosing it explicitly remains possible.
- Inactive rows draw their tint held back, active rows draw it whole. That honours what
  `workspace-shell.prd.md:345` was protecting (a sidebar that is orientation, not noise)
  while dropping the part of it that made the feature useless.

## Criteria

- [x] `WorkspaceTint.derived(forPath:)` is stable across processes and pinned to fixed values
- [x] Paths differing only by trailing slash / `.` / `..` resolve to the same tint
- [x] An explicitly chosen accent beats the derived tint
- [x] Every palette entry is legible against `TenonTheme.chrome` (worst 5.06:1, floor 3:1)
- [x] A typical sidebar of workspaces gets visibly distinct tints
- [x] Every row draws its tint; the selected row stays clearly the selected one
- [x] The identity popover offers "Automatic" showing the colour it will actually use
- [x] Reset restores derived name, folder mark, automatic colour
- [x] `WS-FR-023`/`WS-FR-024` added, `WS-FR-016` corrected, three decisions logged as
      superseding the old "unselected tints stay visually quiet" constraint
- [x] Sidebar snapshot taken at 110 pt and 232 pt
- [x] `swift test` green — 1868 / 0

## What the snapshot found that the tests could not

The first palette was twelve hues spaced evenly around the wheel. Every assertion passed —
coverage, contrast, distribution — and the picture showed three greens reading as one
colour, because an even wheel puts three of twelve hues where the eye discriminates worst.
The palette is now ten hues spaced by eye: CIELAB ΔE 25.1 between the closest pair against
the even wheel's 16.7, worst-case contrast 5.06:1 against 4.48:1, at the cost of two
colours' worth of collision headroom. A ΔE floor is now asserted so the next person cannot
add a hue that only looks distinct on a measurement.

## Limits, stated

- A pure path→colour rule cannot keep a whole sidebar distinct. In the eight-workspace
  snapshot fixture two pairs share a colour (six distinct of eight); the popover is how a
  clash that matters gets settled. Assigning colours from the catalog instead would remove
  the collisions and cost stability — a workspace would change colour when a different one
  was added, which is the recognition this task exists to build.
- Identity still appears only in the sidebar; at 110 pt names truncate to `te…`/`su…` and
  colour becomes the only channel left, which is the argument for carrying it into the
  titlebar as well. Out of scope here, unfiled.

## Owner / files (agent lock)

Released 2026-08-10 20:3x — session `e3b7fcdc` complete, no files held.
