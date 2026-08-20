# Sleep Workspace Design

**Status:** Draft — awaiting spec review before `writing-plans`
**Date:** 2026-08-20
**Baseline:** `d3926d1ba840537842be5502f7757289eac6ec6e`

## Goal

An operator running several workspaces in parallel needs to reclaim CPU/RAM from the ones
they are not actively using, without losing the tab/pane layout they built and without
tearing down the workspace itself. Two independent actions cover this:

1. **Sleep** — kill every live PTY and plugin webview belonging to one workspace right now,
   while leaving its catalog (tabs, panes, layout, UUIDs) untouched. Reopening a slept
   workspace behaves exactly like opening a workspace after a relaunch: nothing is restored
   automatically, and viewing a pane materializes a fresh resource for it.
2. **Move to Background** — remove a workspace from the sidebar's main catalog list without
   touching any of its live resources. A backgrounded workspace keeps running exactly as
   before; it is reachable again only through a dedicated "Backgrounded" section.

These are not two modes of one action. Sleep changes nothing in the `Workspace` value model
and touches only host-owned resource pools. Move to Background changes the value model and
touches nothing live. They are exposed as two separate items in a workspace row's context
menu.

## Evidence baseline

### Orca's "Sleep Worktree" (`references/orca/src/renderer/src/components/sidebar/sleep-worktree-flow.ts:20-220`)

Orca's closest analogue operates at worktree granularity (Orca's unit closest to Tenon's
`Workspace`), triggered only by an explicit user action — there is no idle timer in this
path:

- `shutdownWorktreeBrowsers(worktreeId)` then `shutdownWorktreeTerminals(worktreeId, {
  keepIdentifiers: true })` kill every PTY and persistent webview owned by the worktree
  (`sleep-worktree-flow.ts:166,181`). `keepIdentifiers: true` records `shutdownReason:
  'manual-sleep'` and calls `pty.kill(ptyId, { keepHistory: true })`
  (`store/slices/terminals.ts:3057-3136`) — the process is genuinely killed, not suspended.
- If the target worktree is the active one, Orca clears `activeWorktreeId` first through a
  non-rendering "sleep intent" marker before tearing down, specifically to avoid a
  visible-unmount race against the PTY exit (`sleep-worktree-flow.ts:144-155`); on failure it
  restores the previous active id so the action is retryable (`:194-201`).
- Wake is deliberately **not** an eager mass-relaunch: records are captured with
  `restoreOnTabOpenOnly: true` (`shared/agent-session-resume.ts:58-71`), and each pane
  resumes only when its own tab is opened. `wake-sleeping-agents-in-background.ts:189-195`
  cites a real bug (#11598) where eager wake respawned an entire workspace the user had just
  put to sleep.
- A separate, coarser layer exists for cloud/VM-backed workspaces
  (`ephemeralVm.suspendWorkspace()`, `sleep-worktree-flow.ts:182-184`, backed by the optional
  `suspend`/`resume`/`destroy` lifecycle hooks in `orca-per-workspace-env.md` §8). Tenon has
  no equivalent remote-environment concept and this is out of scope.

Orca also has a *second*, unrelated mechanism — automatic per-agent hibernation
(`agent-hibernation-{planner,coordinator,confirmation,input-guard}.ts`): a 60-second-tick
idle GC that kills individual completed, backgrounded, idle-≥30-minute agent panes one at a
time. This is a background resource-GC layer sitting *under* explicit sleep, not the feature
itself, and confirmed out of scope for this design (see Scope).

### Tenon already has most of the "sleep" mechanism

`Sources/TenonApp/SurfacePool.swift:460-481`:

```swift
func retainOnly(_ slotIDs: Set<UUID>) {
    for key in surfaces.keys where !slotIDs.contains(key) {
        surfaces[key]?.terminate()
        surfaces.removeValue(forKey: key)
        ...
    }
    ...
}
```

This already tears down (`.terminate()`, which runs the SIGHUP→120ms-wait→SIGKILL sequence
documented in `terminal.prd.md` §6 Close and teardown flow) every terminal surface **not** in
the given set, and drops its cached title/directory/activity state with it.
`Sources/TenonApp/PluginWebSurfacePool.swift` has the identical shape: `retainOnly(_
liveKeys: Set<WebSurfaceKey>)` (`:137`) and `dispose(_ key:)` (`:132`).

Today this is only ever called with **every slot ID in the entire catalog**
(`Sources/TenonApp/TenonApp.swift:1253-1256`, `Set(snapshot.allSlotIDs)`), which is exactly
why a workspace's PTYs currently stay alive for as long as its slots exist in the catalog,
whether or not that workspace is the one on screen. Sleep is a new call site that passes a
narrower set — everything **except** the slept workspace's slots — reusing the same
teardown, with no change to `retainOnly` itself.

`retainOnly` only evicts; it never creates. A slot ID present in the passed set with no live
surface stays without one until something calls `surface(for:workspacePath:)`
(`SurfacePool.swift:107`) on demand. That call already exists and already runs on ordinary
view materialization — restoring a workspace after relaunch goes through exactly this path
today (`workspace-shell.prd.md`: "Restore ... does not construct heavyweight pane resources
until they are viewed"; guardrail `WS-GM-002`: "restoration creates unseen terminal/web
resources: zero surface construction before view demand"). Sleep produces the identical
state deliberately, so wake needs no new code path at all.

### `terminal.prd.md`'s non-goal does not block this

`terminal.prd.md` §5 Non-goals states: "Restoring a dead PTY, process, or scrollback **after
relaunch**." Sleep never crosses a relaunch boundary — it is a live, in-session action, and
its wake is not a restoration of the killed process; it is the ordinary fresh-materialization
path any never-yet-viewed slot already goes through. This design does not touch, weaken, or
reinterpret that non-goal.

### `removeWorkspace` is the pattern for the visibility mutation

`Sources/TenonCore/Workspace.swift:557-591` (`WorkspaceCatalog.removeWorkspace`) already
implements the exact shape Move to Background's active-workspace handoff needs: it guards
against removing the last workspace (`workspaces.count > 1`), and when the removed workspace
was active, it re-selects a neighbor and emits `.workspaceSelected` plus the resulting
`.tabSelected`/`.slotFocused` facts (`:578-587`). `WorkspaceStore.setWorkspaceAppearance(_
id:to:)` (`Sources/TenonCore/WorkspaceStore.swift:104`) is the pattern for a workspace-level
presentation field that leaves the tab/slot tree untouched, which is the shape
`setVisibility` needs (paralleling `appearance`, not `removeWorkspace`'s destructive path).

### Existing intent vocabulary and audience convention

`Sources/TenonCore/CoreIntentName.swift:42-57` lists the current `workspace.*` intents
(`workspaceIdentitySet = "workspace.identity.set.v1"`, `workspacePaneClose =
"workspace.pane.close.v2"`, etc.). `Sources/TenonCore/CoreIntentRules.swift` assigns nearly
all of them `audiences: programmatic` — `CoreIntentAudienceProfile.programmatic` resolves to
`[.plugin, .cli, .agent]` (`Sources/TenonCore/CoreIntentName.swift:74-86`), matching
invariant 8 in `CLAUDE.md`: "Core intent audiences are exact: `{plugin, cli, agent}` or
`{plugin}`". The two new intents this design adds follow the same
naming (`workspace.sleep.v1`, `workspace.visibility.set.v1`) and the same `programmatic`
audience, for parity with every other workspace lifecycle action a CLI/agent/plugin caller
can already reach.

## User experience

### Entry point

A workspace row's existing sidebar context menu (the same menu that already carries identity
customization per `command-surfaces.prd.md`) gains two new items:

- **Sleep** — enabled whenever the workspace has at least one materialized surface (terminal
  or plugin webview). Disabled/absent when it has none (nothing to free).
- **Move to Background** — enabled whenever more than one workspace is currently `.visible`.
  Disabled when this is the only visible workspace left (there must always be something to
  show in the single main window, per `WS-A-001`).

### Sleep flow

1. If any live terminal in the workspace has a running (non-idle) process — the same
   inspection `terminal.prd.md`'s tab-close flow already performs — show the same destructive
   confirmation sheet tab-close uses, scoped to "N running processes across this workspace
   will be stopped." Idle-only or empty workspaces sleep without confirmation.
2. On confirm: if the workspace is currently active, select another workspace first (reusing
   `removeWorkspace`'s neighbor-selection shape, but without removing anything), avoiding the
   visible-unmount race Orca's own implementation had to specifically guard against.
3. Call `SurfacePool.retainOnly` and `PluginWebSurfacePool.retainOnly` with every slot ID in
   the catalog **except** the slept workspace's slots.
4. No domain event fires — the `Workspace` value did not change. A host-local, non-persisted
   "currently slept" marker (a `Set<UUID>` of workspace IDs) drives the sidebar's sleep
   indicator and is cleared automatically the moment any slot belonging to that workspace
   materializes a surface again (i.e., the marker is a presentation cache, not state anything
   else depends on for correctness).

### Wake

There is no Wake action. Selecting the workspace and opening/focusing a tab materializes its
active pane exactly as an ordinary restored-but-never-viewed pane would. A freshly
materialized terminal is a plain new shell in the workspace's path — no agent session is
auto-resumed, matching the explicit product decision that wake behaves identically to
"quit and reopen the app."

### Move to Background flow

1. If the target is the active workspace, `setVisibility` reselects a neighbor the same way
   `removeWorkspace` does, then applies the visibility change.
2. `Workspace.visibility` becomes `.background`; `WorkspaceEvent.workspaceVisibilityChanged`
   fires; `WorkspaceCatalogStore` persists it like any other workspace field.
3. `WorkspaceSidebarView`'s main list renders only `.visible` workspaces. A new "Backgrounded"
   section at the bottom of the sidebar (below the existing recent-workspaces affordance)
   lists `.background` workspaces by name.
4. Selecting a row in that section calls `setVisibility(id, to: .visible)` and selects it as
   active in the same action — bringing it back into the main list and on screen in one step.

Backgrounded workspaces are not "closed": they keep every live PTY, agent process, and plugin
webview running, receive `terminal.wait.v1`/`agent.command.v1`/CLI targeting exactly as any
other open workspace does, and are simply absent from the primary catalog list.

## Scope

### Included

- `workspace.sleep.v1` — kills all live terminal + plugin-webview resources for one
  workspace, leaves the catalog untouched, no confirmation for idle/empty workspaces,
  destructive confirmation for running processes.
- `workspace.visibility.set.v1` — sets `.visible`/`.background` on one workspace, persisted,
  with the last-visible-workspace guard and active-workspace handoff.
- Sidebar context-menu entries, sleep indicator, and the "Backgrounded" section.
- `WorkspaceEvent.workspaceVisibilityChanged` fact for the visibility mutation.

### Excluded (this pass)

- Any automatic/idle-triggered sleep (Orca's separate per-agent hibernation GC). Explicit
  user action only, matching the confirmed motivation (deliberate resource reclaim, not a
  background policy) and YAGNI.
- Resuming a live agent session on wake (`--resume` via `AgentSessionResume.swift`). Wake is
  a plain fresh materialization; the operator explicitly chose this over session continuity.
- Any remote/VM suspend hook (Orca's `ephemeralVm.suspendWorkspace()`); Tenon has no
  equivalent remote-environment concept.
- Sleeping/backgrounding at tab or pane granularity. Both actions are workspace-scoped only.
- A public `workspace.wake.v1` intent — there is nothing for it to do that opening a tab does
  not already do.

## Interaction classification

Per `docs/architecture-interaction-boundaries.md`'s ordered law: neither action is a
plugin-to-host declarative registration (not CONTRIBUTION), neither is a fact a plugin
publishes (not EVENT-from-plugin, though the host *emits* one fact as a result), neither is a
long-lived subscription (not RESOURCE/STREAM/TASK), and both must be reachable by CLI and
agent callers exactly like every other `workspace.*` action already is — same-owner DIRECT is
insufficient because it would deny CLI/agent parity, and neither fits the closed SCOPED
FACILITY allowlist (settings/storage/log only). Both resolve to **INTENT**:

- `workspace.sleep.v1` — audience `programmatic` (`{plugin, cli, agent}`), no domain mutation,
  handled by `WorkspaceIntentProvider` calling into the host-owned `SurfacePool`/
  `PluginWebSurfacePool` retain-exclusion, matching how other workspace intents already bridge
  from `TenonCore`'s typed dispatch into `TenonApp`'s host-owned resource pools.
- `workspace.visibility.set.v1` — audience `programmatic`, domain mutation through
  `WorkspaceStore.setVisibility`, mirroring `setWorkspaceAppearance`'s shape exactly.

## Architecture

### Functional core: `TenonCore`

`Workspace.swift`

- add `public enum WorkspaceVisibility: Equatable, Sendable { case visible, background }`
- add `public internal(set) var visibility: WorkspaceVisibility = .visible` to `Workspace`
- add `WorkspaceEvent.workspaceVisibilityChanged(UUID)`
- add `WorkspaceCatalog.setVisibility(_ id: UUID, to: WorkspaceVisibility) -> [WorkspaceEvent]`,
  built on `removeWorkspace`'s active-handoff shape: guard at least one other `.visible`
  workspace remains when setting `.background`; if the target was active, reselect a neighbor
  among the remaining `.visible` workspaces and emit `.workspaceSelected` +
  `.tabSelected`/`.slotFocused` exactly as `removeWorkspace` does; always emit
  `.workspaceVisibilityChanged`.

`WorkspaceStore.swift`

- add `public func setVisibility(_ id: UUID, to visibility: WorkspaceVisibility)`, mirroring
  `setWorkspaceAppearance`.

`CoreIntentName.swift` / `CoreIntentRules.swift`

- add `workspaceSleep = "workspace.sleep.v1"` and `workspaceVisibilitySet =
  "workspace.visibility.set.v1"` with `audiences: programmatic`.

Every rule above (visibility toggling, the last-visible-workspace guard, active-handoff
reselection, event emission) is a pure value-type test in `TenonCoreTests`, no window
required — matching this repo's TDD law.

### Imperative shell: `TenonApp`

`WorkspaceIntentProvider.swift`

- add the `workspace.sleep.v1` handler: resolve the target workspace's slot IDs from
  `WorkspaceStore`'s current catalog, compute the complement against
  `Set(catalog.allSlotIDs)`, call `terminalSurfaces.retainOnly(complement)` and
  `pluginWebSurfacePool.retainOnly(complementWebKeys)`.
- add the `workspace.visibility.set.v1` handler: call `WorkspaceStore.setVisibility`.

`WorkspaceSidebarView.swift`

- filter the main catalog list to `.visible` workspaces.
- add a "Backgrounded" section rendering `.background` workspaces by name; selecting one
  dispatches `setVisibility(id, to: .visible)` followed by workspace selection.
- add the two context-menu items (Sleep, Move to Background) with the enablement rules above.
- track and render the host-local "currently slept" marker set described in the Sleep flow.

`TenonApp.swift`

- Sleep's confirmation check reuses the same running-process inspection tab-close already
  performs (`terminal.prd.md` §6); no new inspection logic.

## Data flow

**Sleep:** sidebar row → confirmation (if needed) → active-workspace handoff (if needed) →
`workspace.sleep.v1` intent → `WorkspaceIntentProvider` → `SurfacePool.retainOnly` +
`PluginWebSurfacePool.retainOnly` (both already terminate what they evict) → no domain event,
host-local sleep-marker updated for UI only.

**Move to Background:** sidebar row → `workspace.visibility.set.v1` intent →
`WorkspaceStore.setVisibility` → `WorkspaceCatalog.setVisibility` (pure mutation, possible
active-handoff) → `WorkspaceEvent.workspaceVisibilityChanged` (+ possibly
`.workspaceSelected`/`.tabSelected`/`.slotFocused`) → `WorkspaceCatalogStore` persists →
`WorkspaceSidebarView` re-renders both the main list and the Backgrounded section.

**Wake (either path):** no dedicated flow. Opening/selecting a tab in the workspace triggers
ordinary SwiftUI view materialization → `SurfacePool.surface(for:workspacePath:)` creates a
fresh surface on demand, same as any never-yet-viewed restored pane.

## Error handling

- `workspace.sleep.v1` on an unknown workspace ID: existing not-found intent error, no state
  change.
- `workspace.visibility.set.v1` targeting `.background` on the last remaining `.visible`
  workspace: refused with a typed error (mirrors `removeWorkspace`'s `workspaces.count > 1`
  guard); no event fires.
- `workspace.visibility.set.v1` on an unknown workspace ID: existing not-found intent error.
- Sleep's process-teardown failures are already handled inside `TerminalSurface.terminate()`
  and are out of scope for this design to change.

## Testing

### Headless core (`TenonCoreTests`)

- `.visible` → `.background` → `.visible` round-trip preserves tabs/slots/UUIDs exactly.
- setting `.background` on the sole `.visible` workspace is refused and emits no event.
- setting `.background` on the active workspace reselects a neighbor and emits
  `.workspaceSelected`/`.tabSelected`/`.slotFocused` in the same shape `removeWorkspace`
  already produces for the same scenario.
- setting `.background` on a non-active workspace does not change `activeWorkspaceID` and
  emits only `.workspaceVisibilityChanged`.
- `WorkspaceCatalog` persistence round-trip includes `visibility`.

### Host (`TenonAppStateTests`)

- `workspace.sleep.v1` against a workspace with N live terminal surfaces and M plugin
  webviews releases exactly those N+M resources and leaves every other workspace's surfaces
  untouched (parallels existing `SurfacePool.retainOnly` tests).
- sleeping the active workspace triggers a workspace switch before teardown, with no surface
  torn down for the newly active workspace.
- sleeping a workspace with no live surfaces is a no-op with no confirmation.
- re-viewing a slept workspace's pane creates a fresh surface with no scrollback and no
  resumed process, exactly like `hasEverBeenViewed(_:)` false-to-true today.

### Sidebar / visual

- `TENON_SIDEBAR_SNAPSHOT` capture with one backgrounded and one slept workspace present,
  confirming the main list excludes the backgrounded one and the sleep indicator renders on
  the slept one.

## Alternatives rejected

**A new `SlotContent` case for "asleep" panes** (mirroring `.agentSession`) is rejected: sleep
deliberately makes zero domain-model change so that a slept workspace is byte-for-byte the
same catalog value as before sleeping, which is both simpler and is what makes "wake behaves
exactly like relaunch" true by construction rather than by extra bookkeeping.

**Automatic `--resume`-based wake continuity** is rejected for this pass per the explicit
product decision: wake should behave identically to quit-and-reopen, not attempt session
continuity. `AgentSessionResume.swift`'s composer remains available for a future, separately
scoped enhancement if this is revisited.

**Keeping backgrounded workspaces visible but visually de-emphasized** (dimmed/collapsed
row) instead of removing them from the list is rejected per explicit product direction: the
list must actually shrink, and the "Backgrounded" section is the dedicated place to find them
again.

**One combined intent with a mode parameter** (`workspace.sleep.v1` accepting a
`background: Bool`) is rejected: Sleep is a host-resource action with no domain mutation and
Move to Background is a pure domain mutation with no resource action — collapsing them would
mean one intent doing two semantically unrelated things depending on a flag, which the
existing `workspace.*` vocabulary never does elsewhere.

## Likely implementation surfaces

Production:

- `Sources/TenonCore/Workspace.swift`
- `Sources/TenonCore/WorkspaceStore.swift`
- `Sources/TenonCore/CoreIntentName.swift`
- `Sources/TenonCore/CoreIntentRules.swift`
- `Sources/TenonApp/WorkspaceIntentProvider.swift`
- `Sources/TenonApp/WorkspaceSidebarView.swift`
- `Sources/TenonApp/SurfacePool.swift` (new call site only, no signature change)
- `Sources/TenonApp/PluginWebSurfacePool.swift` (new call site only, no signature change)
- `Sources/TenonCore/WorkspaceCatalogStore.swift` (persist `visibility`)
- `docs/prds/workspace-shell.prd.md` (new FRs, decision log entry)

Tests:

- `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`
- a new `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift`
- a new `Tests/TenonAppStateTests/WorkspaceSleepTests.swift`
- sidebar snapshot fixture under the existing `PaneViewSnapshotWriter` pattern

## Acceptance criteria

1. Sleeping a workspace kills every live terminal and plugin-webview resource it owns and
   changes nothing else observable in its catalog value.
2. Reopening any pane of a slept workspace materializes a fresh resource with no restored
   scrollback and no resumed process.
3. Sleeping the active workspace switches the active selection first; no visible-unmount
   race or crash.
4. Sleeping a workspace with no live resources requires no confirmation; sleeping one with a
   running process requires the same confirmation tab-close already uses.
5. Move to Background is refused on the last `.visible` workspace and never leaves zero
   visible workspaces.
6. Backgrounding the active workspace reselects a neighbor exactly as closing it would.
7. A backgrounded workspace's live processes are never touched by the backgrounding action
   itself.
8. The main sidebar list excludes `.background` workspaces; the "Backgrounded" section finds
   and restores them to `.visible` + active in one action.
9. `visibility` persists across relaunch; sleep leaves no durable trace (a relaunched app
   cannot distinguish a workspace that was slept from one that simply was not viewed).
10. Both new intents are audience `programmatic` and pass the existing intent-catalog fitness
    tests alongside every other `workspace.*` intent.
