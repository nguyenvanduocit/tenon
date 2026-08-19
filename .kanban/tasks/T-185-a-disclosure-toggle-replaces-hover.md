# T-185: A disclosure toggle replaces the hover that closed under a moving pointer
> Operator-reported: hovering a sidebar row open, then moving toward another workspace to
> click it, closed the first row and reflowed the rows below it under the pointer — missing
> the click. Hover-driven open/close is withdrawn; a per-row toggle button opens/closes the
> account instead, independent of hover and of which workspace is selected.
- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
Released — DONE 2026-08-19, this session. Built additively on top of T-179's uncommitted WIP
(claimed by session `c7162dba`, not currently connected — confirmed via `ListAgents` before
starting). Touched: `Sources/TenonApp/WorkspaceSidebarView.swift`,
`Sources/TenonApp/WorkspaceIdentityViews.swift` (one stale doc-comment line),
`Tests/TenonAppStateTests/WorkspaceIdentityFormTests.swift`, `docs/prds/workspace-shell.prd.md`,
`docs/prds/workspace-shell.feature`. Did not touch `WorkspaceAgentTagline.swift`,
`SidebarSnapshot.swift`, or `WorkspaceAgentTaglineTests.swift`, all also held by T-179.
**Risk carried forward**: if session `c7162dba` returns and overwrites
`WorkspaceSidebarView.swift`/`WorkspaceIdentityViews.swift` wholesale rather than merging, this
task's diff could be lost — operator chose to proceed anyway (asked directly, see below).

## What was reported
The operator, using the app: hover opens a row's agent account inline; moving the pointer to a
neighbouring row to click it closes the first row's account (180 ms grace, then close), which
shifts every row below it upward at the exact moment the pointer is travelling toward one of
them — so the click lands on the wrong row, or misses. Confirmed by reading
`WorkspaceRow.holdAgents`/`openAgents`/`closeAgents` (removed by this task): the close was
driven purely by `.onHover` leaving a row, with no relationship to what the pointer was
actually headed toward.

## Fix
Hover no longer opens or closes a row's account. Each row that holds agent panes now draws a
disclosure toggle (`accountToggle`, a chevron at the trailing edge) as a **sibling** button next
to the row's own `select` button — not nested inside it, since SwiftUI only fires the outer of
two nested buttons, and the toggle's whole point is that clicking it must never select the
workspace. `isShowingAgentsInline` is written from exactly one place (the toggle's action) and
stays exactly as the operator left it — including across a sidebar collapse/expand and
regardless of which workspace is selected — until the toggle is clicked again or the
workspace's last agent pane leaves (still force-closes it, so an account never sits open naming
nobody).

The rail (collapsed sidebar) lost its hover-driven popover outright — there is no room for a
toggle on a 48 pt icon rail, and `WS-FR-036` already guaranteed every agent pane is reachable
from the row's context menu regardless of hover, which remains the rail's route.
`WorkspaceRowPopover`, `holdAgents`, `openAgents`, `closeAgents`, and the 180 ms dismissal grace
are deleted — nothing drove them after hover was withdrawn from this feature.
`WorkspaceAgentList` lost its `fixedWidth` parameter (the popover was its only caller ever
passing `true`); `WorkspaceAgentListLayout.width` (260 pt) went with it as dead weight.

The row's accessibility identity (`tenon.workspaceRow`, spoken label, `.isSelected` trait, move
up/down actions) moved from the row's outer container onto its `select` button specifically —
a container with two focusable children (the toggle sits beside it) does not adopt a label
placed on the container, so leaving it there would have silently stopped speaking at all.

## Scope note
Two interpretations were live before this task started: "active workspace forces its row
open" (session's first reading of the operator's request, confirmed via `AskUserQuestion`) and
then this toggle design, which the operator asked for instead after seeing the reflow problem
with the hover-driven version. The `isActive`-driven forced-open approach was never shipped —
superseded before any code landed.

## Criteria
- [x] Clicking a row's disclosure toggle opens/closes its account; clicking it never selects
      the workspace
- [x] Selecting a workspace never opens or closes any row's account
- [x] The account's open/closed state is independent of which workspace is active/selected
- [x] A row with no agent panes offers no toggle (unchanged tab-count line)
- [x] A row whose last agent pane leaves force-closes its account
- [x] The rail (collapsed sidebar) keeps agent-pane access through its context menu; no popover
- [x] `swift build` clean, full `swift test` **2379 / 0**
- [x] `WS-FR-036` requirement text, delivery matrix, decision log, and `.feature` scenarios
      restated to describe the toggle instead of hover
- [ ] Owed: a live click check — tapping the toggle vs. tapping elsewhere on the row is an
      installed-app check, same category as T-179's "owed a live hover"; no headless run can
      press a button
