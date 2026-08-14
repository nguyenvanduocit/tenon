# T-153: A collapsed sidebar can be dragged open again

> The 48 pt icon rail keeps the same right-edge resize affordance as the expanded sidebar.
> Collapse is one end of the resize interaction, not a state that deletes the interaction.

- **priority**: medium
- **effort**: S
- **type**: bug
- **Unclaimed.** This can stay independent of T-144 by leaving `ShellTitleBar.swift` alone.

## Reproduction and root cause

1. Expand the workspace sidebar.
2. Drag its right border left until it collapses into the icon rail.
3. Hover and drag the rail's right border back toward the right.
4. The pointer does not become a resize cursor and the sidebar does not move.

`ContentView` mounts the full-height `sidebarEdge` only inside `if sidebarVisible`. The drag's
`.collapse` outcome sets that value to false, which immediately unmounts the handle; collapsed
chrome is then only a static rule. `SidebarResizeTests` assert the 48 pt rendered width and the
expanded-to-collapsed threshold, but have no collapsed-to-expanded transition.

**Falsification criterion:** if a mounted collapsed shell still contains the live
`tenon.sidebarResize` hit target at the rail's rendered right edge, this diagnosis is wrong.
The current source does not mount it there, so confidence is HIGH.

## UX decision

- The visible right edge is draggable in both states and uses the same 8 pt acquisition area,
  resize cursor, amber hover/active state, and accessibility identity.
- Expanded behaviour stays exactly as it is: the edge follows the pointer, clamps at
  `maxWidth`, and collapses below `minWidth`.
- A collapsed drag starts from `collapsedWidth` (48 pt). Moving right keeps the rail collapsed
  until the pointer reaches `minWidth` (110 pt); the active edge stays amber during this
  threshold travel so the gesture never reads as dead.
- At `minWidth`, the sidebar expands at the pointer and the same uninterrupted drag continues
  to resize it. It does not jump to the previously stored width after a one-pixel movement.
- Releasing before `minWidth`, dragging left, or clicking without a drag leaves the rail
  collapsed and does not overwrite the last expanded width. The title-bar toggle therefore
  still restores the person's previous width.
- In the collapsed state the draggable segment begins below the title bar. A 48 pt-wide rail
  cannot safely carry a full-height handle through the macOS traffic-light region; the title
  bar keeps its own chrome and input unchanged.

## Criteria

- [ ] `sidebarEdge` remains mounted and discoverable when the sidebar is collapsed, aligned to
      `SidebarResize.renderedWidth(...)` rather than the stored expanded width.
- [ ] One pure resize state machine covers expanded-to-collapsed and collapsed-to-expanded
      drags; the view does not grow a second ad-hoc threshold rule.
- [ ] From collapsed, crossing `minWidth` expands at the pointer and continues the same drag;
      releasing below it remains collapsed and preserves the stored expanded width.
- [ ] Hover, cursor balancing, amber feedback, hit-target width, and
      `tenon.sidebarResize` accessibility identity are equivalent in both states, including
      the state change that occurs while the pointer is still down.
- [ ] The collapsed hit target starts below `TenonTheme.titleBarHeight` and does not intercept
      traffic lights, sidebar toggle, tabs, or window dragging.
- [ ] Headless tests pin both directions, the exact threshold, cancellation below threshold,
      max-width clamping, and stored-width preservation. A mounted-shell test proves the
      handle exists in both states rather than testing only `SidebarResize.resolve`.
- [ ] Hardware verification performs collapse → drag-open → resize → collapse in one session,
      with the sidebar toggle still restoring the previous width and no stuck resize cursor.
- [ ] The implementation follows `docs/designs.md`, adds no feature-local metrics or colours,
      and records the corrected interaction in the workspace-shell PRD/feature scenarios.

## Owner / files (agent lock)

Unclaimed. Expected files when claimed:

- `Sources/TenonApp/ContentView.swift`
- `Sources/TenonApp/SidebarResize.swift`
- `Tests/TenonAppStateTests/SidebarResizeTests.swift`
- mounted shell/interaction coverage under `Tests/TenonAppStateTests/`
- `docs/prds/workspace-shell.prd.md`
- `docs/prds/workspace-shell.feature`
