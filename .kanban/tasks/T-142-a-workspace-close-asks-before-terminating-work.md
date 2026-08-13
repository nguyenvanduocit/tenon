# T-142: A workspace close asks before terminating work

> Removing a workspace from the sidebar crosses the same terminal-process gate as closing a
> tab: idle work closes directly; running or unverifiable work asks first.

- **priority**: high
- **effort**: M
- **PRD**: `TENON-PRD-001` (`docs/prds/workspace-shell.prd.md`)
- **requirements**: `WS-FR-026`

## Root cause

The row's destructive menu called `WorkspaceStore.removeWorkspace` directly. The existing
process inspection, stale-result token, and native alert lived privately in `ShellTitleBar`,
so tab close was protected while workspace removal had no gate at all. Earlier notes called
that workspace behaviour deferred, but no follow-up card or requirement existed.

## Implementation

- `ShellCloseCoordinator` is the one app-composed DIRECT owner for tab and workspace close.
- Workspace targets capture every slot across every tab. An asynchronous answer applies only
  while the target exists with exactly that slot set and foreground-process snapshot; a
  changed pane or process identity fails safe to confirmation.
- `ContentView` projects the one pending decision through a native SwiftUI `.alert`.
- Sidebar and title-bar gestures call the coordinator; neither contains process policy.

## Criteria

- [x] A workspace with no live terminal closes immediately without process inspection
- [x] Complete idle identity closes immediately; running work asks before removal
- [x] Incomplete identity and unavailable inspection fail safe to confirmation
- [x] Every tab and pane in the workspace is included in the snapshot
- [x] Older async answers cannot act after a newer request
- [x] A pane-set change during inspection cannot reuse a stale idle answer
- [x] A foreground PID change in the same pane cannot reuse a stale idle answer
- [x] Cancel leaves the catalog unchanged; Confirm commits through `WorkspaceStore`
- [x] The sidebar adapter calls the shared coordinator and no longer removes directly
- [x] The shipping alert modifier mounts as a native `NSWindow` sheet with workspace copy,
      destructive action, and a working Cancel button
- [x] DIRECT inventory, PRD requirement/scenarios/delivery receipt, domain tags, and Xcode
      project membership are updated in the same change

## Evidence

- `WorkspaceCloseConfirmationTests` **13 / 0**, including a hosted native-window sheet on the
  real `.running` branch and its real Cancel button; closure seams make
  idle/running/unavailable/race branches exact.
- `DirectInventoryGateTests` **3 / 0** and `DomainTagFitnessTests` **7 / 0**.
- Settled full suite **2100 / 0**; Xcode test build succeeded; independent review and
  verification both returned PASS after the foreground-identity race repair.
- The exact final Staging candidate was built, signed, and installed without replacing
  production. macOS
  denied the shell Accessibility permission, so no installed-app context-menu journey is
  claimed; the native presentation receipt is the hosted `NSWindow` test above.

## Boundary decision

DIRECT. Both gestures are fixed host chrome, terminal identity is host-private, and the
mutation is the same typed `WorkspaceStore` service. No plugin/CLI/agent principal, public
intent, contribution point, or caller-owned lifetime is introduced.
