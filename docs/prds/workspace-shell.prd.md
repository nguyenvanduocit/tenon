# PRD — Workspace shell, identity, recents, and restoration

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-001` |
| Lifecycle | `shipped` |
| Owner | Tenon workspace-model and native-shell domains |
| Reviewers | product, native UI, accessibility, persistence, plugin runtime, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-001, T-003, T-027, T-032, T-034, T-097, T-098, T-099 |
| Related PRDs | [`command-surfaces.prd.md`](command-surfaces.prd.md), `spatial-panes.prd.md`, `settings.prd.md`, `plugin-ui.prd.md`, `terminal.prd.md` |
| Acceptance specification | [`workspace-shell.feature`](workspace-shell.feature) |

## 1. Executive summary

### Problem

Tenon is a supervision workspace, so its shell must preserve orientation across many
projects, tabs, and panes. Losing the catalog on relaunch, restoring the wrong active pane,
mixing one workspace's recent items into another, or identifying workspaces by display name
turns navigation into reconstruction. Shell polish also regresses easily when app identity,
titlebar behavior, sidebar utilities, and workspace customization are treated as unrelated
local changes.

Historical task records describe several intermediate implementations. Current source is
the authority: Tenon now has one workspace window and one typed catalog; catalog persistence
is versioned and fail-soft; sidebar layout remains owned by app preferences; recent
workspaces and recently opened content are different stores; and workspace appearance never
replaces its UUID identity.

### Proposed outcome

One native macOS window presents a stable catalog of workspaces. Each workspace owns its
tabs, each tab owns its active pane, and every identity remains stable across selection,
customization, ordering, persistence, and restoration. The sidebar provides direct
workspace navigation, a filtered recent-workspace menu, compact host utilities, and a
closed customization vocabulary. Relaunch reconstructs every valid part of the saved tree
without constructing heavyweight pane resources until they are viewed.

### Why now

The current documentation is spread across eight task outcomes, source comments, tests, and
cross-cutting design rules. Some old claims no longer match source—for example, sidebar
state is not duplicated into the workspace catalog, and implicit background window movement
was replaced by explicit empty-titlebar dragging when tab reorder shipped. This PRD records
the combined shipped contract before further shell work continues.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| user reports about context loss | conversation, 2026-08-09 | high | shipped shell behaviors must be specified together so one fix does not remove another |
| workspace domain | [`Workspace.swift`](../../Sources/TenonCore/Workspace.swift), [`WorkspaceStore.swift`](../../Sources/TenonCore/WorkspaceStore.swift) | high | UUID ownership, selection, tab/pane invariants, mutation events, and workspace-scoped recent attribution |
| persistence implementation | [`WorkspaceCatalogStore.swift`](../../Sources/TenonCore/WorkspaceCatalogStore.swift), [`TenonApp.swift`](../../Sources/TenonApp/TenonApp.swift) | high | versioned DTO restore, launch precedence, coalesced durable writes, quit flush, and lazy composition |
| shell implementation | [`ContentView.swift`](../../Sources/TenonApp/ContentView.swift), [`WorkspaceSidebarView.swift`](../../Sources/TenonApp/WorkspaceSidebarView.swift), [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift) | high | one titlebar/body composition, sidebar ownership, workspace rows, recent menu, and direct selection |
| identity and footer implementation | [`WorkspaceIdentity.swift`](../../Sources/TenonCore/WorkspaceIdentity.swift), [`WorkspaceIdentityViews.swift`](../../Sources/TenonApp/WorkspaceIdentityViews.swift), [`SidebarFooter.swift`](../../Sources/TenonApp/SidebarFooter.swift) | high | closed marks/tints, name normalization, accessibility, and compact utility contract |
| recent stores | [`RecentWorkspaceStore.swift`](../../Sources/TenonCore/RecentWorkspaceStore.swift), [`RecentStore.swift`](../../Sources/TenonCore/RecentStore.swift) | high | distinct recent-workspace and workspace-scoped recent-content lifecycles |
| focused verification | test files listed in section 10 | high | domain, relaunch, hosted view, fitness, and native-window seams exist |
| task archive | T-001, T-003, T-027, T-032, T-034, T-097, T-098, T-099 | medium | original problem statements and evidence; current-source audit supersedes implementation details that drifted |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| What core problem are we solving? | Preserve the operator's project orientation and shell affordances across navigation and relaunch. | user reports and current product behavior |
| Who experiences it? | Anyone supervising work across two or more workspaces, tabs, or panes; keyboard and VoiceOver users are first-class. | shipped shell scope |
| How will we know it worked? | Stable identities, active selections, valid layouts, recents isolation, and shell actions survive their specified transitions and focused tests. | acceptance specification |
| Which constraints cannot move? | one main window, one semantic owner per state, typed DIRECT host calls, fact-only EVENT publication, native design system, and fail-soft restore | normative architecture/current source |
| What remains unknown? | Session-restoration success is not measured in product telemetry, and focus-ring/titlebar feel still requires installed-app observation. | 2026-08-09 |

### Assumptions to validate

| ID | Assumption | Validation method | State |
|---|---|---|---|
| `WS-A-001` | One native window is the right product boundary for the current single-instance surface pools. | product observation before any multi-window proposal | accepted for shipped architecture |
| `WS-A-002` | Five recent-workspace menu entries are enough for quick recovery without making the context menu dominate navigation. | usability observation | shipped, not analytically instrumented |
| `WS-A-003` | A row context menu is sufficiently discoverable for workspace customization. | usability observation and user feedback | partially validated; no keyboard/palette entry point promised |

## 3. Users and jobs

### Primary user

An operator supervising several repositories and long-running agent or terminal workflows.
They revisit the same folders, switch rapidly between workspaces and tabs, and expect a
restart to preserve the map of work even when live processes themselves cannot survive.

### Secondary users and affected actors

- Keyboard and VoiceOver users who require spoken selection, counts, marks, and reachable
  host utilities.
- Plugin authors who consume workspace facts without gaining access to sensitive pane
  contents.
- CLI and agent callers that address workspaces, tabs, and panes by stable UUID.
- Support and test engineers who need deterministic restoration and fail-soft evidence.

### Jobs to be done

- When I relaunch Tenon, I want my valid workspaces, tabs, panes, and selections restored so
  I can resume supervision without rebuilding the layout.
- When I switch away from a tab, I want its focused pane remembered so returning restores
  my exact local context.
- When I reopen a project, I want it offered once and never duplicated just because its URL
  has a different textual form.
- When two projects have similar names, I want marks and semantic accents while tools still
  address them by stable identity.
- When I open an empty pane, I want only that workspace's recent content so another
  project's paths and views never leak into it.

### Product vocabulary

| Term | Meaning in this PRD | Not to be confused with |
|---|---|---|
| Workspace | UUID-addressed project root containing one or more tabs | display name, folder string, or macOS window |
| Catalog | the complete ordered workspace/tab/pane value tree plus active selections | recent-workspace history or runtime surface pools |
| Recent workspace | a remembered folder offered by the sidebar after it is closed | a recently opened pane view |
| Recently opened | content history owned by one workspace UUID and shown in that workspace's empty launcher | one app-global list |
| Restore | validated reconstruction of value state and lightweight placeholders | PTY/process continuation or eager view construction |
| Appearance | optional display name, curated mark, and semantic tint | workspace identity or plugin scope |

## 4. Goals and success measures

### Goals

- `WS-G-001` — A relaunch restores the same valid navigation tree and active context.
- `WS-G-002` — Workspace, tab, and pane identities remain stable through every shell
  mutation that does not explicitly create or destroy them.
- `WS-G-003` — Recent navigation is useful without duplicating open workspaces or crossing
  workspace boundaries.
- `WS-G-004` — Native shell identity and utilities stay compact, accessible, and consistent.

### Success metrics

| ID | Metric | Baseline | Target | Measurement method | Review window |
|---|---|---|---|---|---|
| `WS-M-001` | valid catalog equality after quit/relaunch | historical loss of full tree | exact equality for supported saved values | composition-root relaunch test | every change |
| `WS-M-002` | active-pane preservation across tab switching | historical regression | 100% deterministic | pure core test | every change |
| `WS-M-003` | cross-workspace recent-content leakage | previously possible | zero rows from another workspace | two-workspace core/hosted tests | every change |
| `WS-M-004` | recent-workspace menu duplication | previously offered open folders | zero open folders; up to five closed offers after filtering | core plus source/host review | every change |
| `WS-M-005` | additional main workspace windows | unsafe with current pools | zero | scene fitness test | every change |

### Guardrail metrics

| ID | Regression to prevent | Limit | Measurement method |
|---|---|---|---|
| `WS-GM-001` | one workspace mutation produces one disk write | at most one coalesced write per debounce burst, final state wins | catalog-store tests |
| `WS-GM-002` | restoration creates unseen terminal/web resources | zero surface construction before view demand | composition and pool tests/source audit |
| `WS-GM-003` | sidebar footer regains visual dominance | exactly three controls in a 34-point band, fitting minimum sidebar width | footer geometry and snapshot tests |
| `WS-GM-004` | invalid or future state crashes launch | zero traps; decline whole document or degrade the smallest invalid unit | persistence fault matrix |

## 5. Scope

### In scope

- Singleton native workspace window and shared shell composition.
- App mark, titlebar alignment, sidebar toggle, explicit empty-titlebar behavior, and sidebar
  layout persistence.
- Workspace add, select, remove, recent reopening, naming, marking, tinting, and reset.
- Tab ownership, selection, close invariants, and active-pane preservation.
- Versioned catalog capture, fail-soft restore, launch precedence, write coalescing, and quit
  flush.
- Workspace-scoped recently opened content and deterministic legacy handling.
- Compact Help, Feedback, Settings footer and About version placement.
- Workspace structural facts consumed by the bundled permission-free Workspace Status
  example.

### Non-goals

- Tab launcher, Copy Tab ID, and drag-to-order details; PRD-002 owns them.
- Pane spatial creation, drag, resize, hosting, Copy Pane ID, and attention state; PRD-003
  owns them.
- PTY/process continuity and terminal scrollback restoration; PRD-009 owns terminal
  lifecycle and these are not shipped restore promises.
- Arbitrary workspace icons, arbitrary colors, multiple windows, cloud sync, or cross-device
  session restoration.
- A host-wide command/keybinding for workspace customization. The shipped form is local to
  the workspace row.
- Persisting sidebar visibility/width inside the catalog. App preferences are their sole
  semantic owner.

### Later possibilities

- Instrumented restore-success and time-to-resume measures.
- A separately designed multi-window resource ownership model.
- A public customization entry point only after interaction-boundary classification and
  inventory updates.

## 6. User experience

### Entry points

- App launch opens or focuses the one workspace window with stable scene ID `main`.
- The sidebar row selects a workspace; its secondary menu offers Customize and Remove.
- Secondary-clicking the sidebar body offers Add Workspace and up to five eligible recents.
- The titlebar toggle shows or hides the sidebar; its width is pointer-resizable.
- The tab strip selects a tab; command/launcher and reorder details are specified in
  PRD-002.
- The footer exposes Help, Feedback, and Settings as three compact icon controls.

### Primary navigation flow

1. The user opens Tenon and sees the restored catalog, or one fresh workspace when nothing
   can be restored.
2. Selecting a workspace reveals its remembered active tab and active pane.
3. Selecting a tab reveals that tab's own active pane; switching away does not overwrite it.
4. Every successful typed mutation publishes a new catalog snapshot and the facts that
   already happened.
5. Resource pools reconcile to the live IDs without becoming alternate state owners.

### Workspace creation and recents flow

1. Add Workspace opens a directory-only native panel.
2. The chosen canonical folder becomes a new UUID-addressed workspace with a derived name,
   configured default content, one active tab, and one active pane.
3. The workspace is selected and recorded newest-first in recent-workspace history.
4. The recent menu removes all currently open canonical folders, then shows at most five.
5. If a recent folder becomes open before the click settles, the handler selects it instead
   of creating a duplicate.

### Identity customization flow

1. Customize Workspace opens a native popover on the row.
2. The user may type a name, choose one of twelve curated marks, and choose a semantic
   accent or follow the app accent.
3. Clearing the name means use the derived folder name; Reset restores derived name,
   default folder mark, and inherited app accent.
4. UUID, path, tabs, panes, selections, and plugin scope remain unchanged.

### Relaunch and recovery flow

1. Startup reads at most one supported, bounded catalog document under an exclusive lock.
2. Restore validates DTOs before constructing domain values. Invalid workspaces/tabs are
   dropped; unsupported pane content becomes empty; surviving selections fall back locally.
3. A bare launch returns the restored tree as saved. An explicit launch directory selects a
   matching open workspace or adds it beside the restored tree.
4. Without a restorable tree, the explicit directory—or the home-directory fallback—seeds
   one fresh workspace.
5. Restored titles and valid cwd placeholders are seeded without building a terminal or web
   surface. Live terminal processes are newly created only when viewed.

### Alternate and edge flows

- Removing the last workspace or closing the last tab is a no-op.
- Removing the active workspace selects a surviving neighbor and publishes its tab/focus
  chain; removing an inactive one does not steal selection.
- Unknown UUIDs and no-op identity edits publish nothing.
- Missing/oversized/corrupt/duplicate-key/newer-version catalog documents are declined
  without crashing; newer-version bytes are not rewritten during restore.
- A missing workspace folder removes that workspace only. A missing file, unknown plugin
  view, unknown content kind, or inline live diff degrades that pane to empty.
- A workspace with no recent-content bucket shows no recents, never another workspace's.

### Accessibility and input parity

- Workspace rows announce name, mark, tab count, unseen count, and selected state.
- Mark and accent choice has a selected ring/check or inherited-outline treatment; color is
  not the only signal.
- Icon-only footer controls retain tooltip, keyboard focus treatment, VoiceOver label, and
  stable accessibility identifiers.
- The sidebar toggle and tab selection are keyboard-reachable through their native controls.
- Empty-titlebar drag/double-click behavior and tab drag arbitration are jointly covered by
  PRD-001 and PRD-002; controls layered above the drag area retain their own clicks.

## 7. Requirements

### Functional requirements

| ID | Requirement | Priority | Delivery | Gherkin tag |
|---|---|---|---|---|
| `WS-FR-001` | Tenon **MUST** declare exactly one main workspace `Window` with stable ID `main`; it **MUST NOT** expose a `WindowGroup` or another path that creates a workspace window while surface pools are single-instance. | must | shipped | `@req-ws-fr-001` |
| `WS-FR-002` | The 36-point hidden-titlebar shell **MUST** show the Tenon mark/wordmark, align tabs with traffic lights, preserve interactive controls, and give only empty chrome explicit system drag and configured double-click behavior. | must | shipped | `@req-ws-fr-002` |
| `WS-FR-003` | A catalog **MUST** contain at least one uniquely identified workspace; every workspace **MUST** contain at least one uniquely identified tab; slot IDs **MUST** be catalog-unique; a non-empty tab **MUST** name one of its slots as active and an empty tab **MUST** use no active slot. | must | shipped | `@req-ws-fr-003` |
| `WS-FR-004` | Add Workspace **MUST** accept one directory, derive its default name from the folder, create it with the current default content/sizing, select it, and record it in recent-workspace history only when creation succeeds. | must | shipped | `@req-ws-fr-004` |
| `WS-FR-005` | Selecting a workspace **MUST** reveal that workspace's remembered active tab and active pane, preserve inactive workspace resources by identity, and publish workspace-selected, tab-selected, then slot-focused facts when applicable. | must | shipped | `@req-ws-fr-005` |
| `WS-FR-006` | Removing a workspace **MUST** be refused for the final workspace; otherwise it **MUST** close its slots/tabs, remove it, and select a surviving neighbor only when the removed workspace was active. | must | shipped | `@req-ws-fr-006` |
| `WS-FR-007` | Recent-workspace history **MUST** be newest-first, path-deduplicated, atomically persisted, and capped at eight stored entries; the sidebar **MUST** filter all open canonical folders before presenting at most five closed entries. | must | shipped | `@req-ws-fr-007` |
| `WS-FR-008` | Every tab **MUST** own its active pane independently; selecting another tab and returning **MUST** restore the first tab's active pane and focus fact. | must | shipped | `@req-ws-fr-008` |
| `WS-FR-009` | New-tab, select, cycle, and close operations **MUST** preserve stable tab identity, append/select new tabs, wrap cycle order, select the previous neighbor after closing an active tab, and refuse removal of the final tab. | must | shipped | `@req-ws-fr-009` |
| `WS-FR-010` | Catalog persistence **MUST** use an explicit versioned DTO containing workspace/tab/slot UUIDs, ordering, paths, appearance, supported content records, geometry, active workspace/tab/slot, and lightweight title/cwd placeholders; sidebar preferences **MUST NOT** be duplicated in it. | must | shipped | `@req-ws-fr-010` |
| `WS-FR-011` | Successful workspace-event bursts **MUST** schedule one coalesced durable catalog write whose last snapshot wins, and app termination **MUST** synchronously flush the final live snapshot before completing termination. | must | shipped | `@req-ws-fr-011` |
| `WS-FR-012` | Restore **MUST** validate before constructing domain values, decline an unusable whole document, drop only invalid workspace/tab units when possible, degrade unsupported pane content to empty, and choose the first surviving selection when a saved selection vanished. | must | shipped | `@req-ws-fr-012` |
| `WS-FR-013` | A bare launch **MUST** restore the catalog as saved; an explicit launch directory **MUST** select its canonical-folder match or add it without replacing restored work; absent restore **MUST** seed from the explicit directory or home fallback. | must | shipped | `@req-ws-fr-013` |
| `WS-FR-014` | Restore **MUST NOT** promise PTY or scrollback continuity and **MUST NOT** eagerly construct unseen pane resources; a restored terminal starts a fresh shell on demand using a valid saved cwd placeholder or workspace root fallback. | must | shipped | `@req-ws-fr-014` |
| `WS-FR-015` | Workspace naming **MUST** trim and collapse whitespace, cap at 60 characters, treat empty input as the derived folder name, permit duplicate display names, and leave UUID/root/tree/plugin scope unchanged. | must | shipped | `@req-ws-fr-015` |
| `WS-FR-016` | Workspace appearance **MUST** use the closed twelve-mark vocabulary and existing semantic accent vocabulary; Reset **MUST** restore the derived name, folder mark, and inherited app accent without recreating the workspace. | must | shipped | `@req-ws-fr-016` |
| `WS-FR-017` | A real identity change **MUST** persist compatibly, update every existing host representation through shared formatting, and publish exactly one `workspace.identity-changed` fact; a no-op **MUST** publish nothing. | must | shipped | `@req-ws-fr-017` |
| `WS-FR-018` | Recently opened content **MUST** be recorded against the workspace ID named by the mutation's own events, read only by an explicitly supplied workspace ID, deduplicate/order independently, cap each bucket at six and the store at 32 workspaces, and clear one bucket without changing another. | must | shipped | `@req-ws-fr-018` |
| `WS-FR-019` | On launch, a stale recent-content bucket **MAY** be adopted only by an unclaimed live workspace with the same canonical root; legacy app-global rows **MUST** be discarded rather than guessed into a workspace. | must | shipped | `@req-ws-fr-019` |
| `WS-FR-020` | The sidebar footer **MUST** contain exactly Help, Feedback, and Settings in one 34-point row of 28-point controls; Help/Feedback destinations **MUST** remain unchanged, and version/build **MUST** move to Settings About instead of the primary sidebar hierarchy. | must | shipped | `@req-ws-fr-020` |
| `WS-FR-021` | Sidebar visibility and width **MUST** initialize from and write through app preferences as their single owner; catalog restoration **MUST NOT** overwrite them. | must | shipped | `@req-ws-fr-021` |
| `WS-FR-022` | The bundled permission-free Workspace Status plugin **MAY** consume `workspace.changed` structural facts and show tab/slot counts, but **MUST NOT** receive pane contents through that event. | should | shipped | `@req-ws-fr-022` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `WS-NFR-001` | durability | The catalog document **MUST** be at most 16 MiB on read, use `DurableJSONFile` exclusive locking plus atomic replace, and retain live in-memory state if a write fails. | shipped | persistence store tests/source review |
| `WS-NFR-002` | responsiveness | Catalog writes **MUST** be debounced off domain events rather than SwiftUI rendering; sidebar recent-menu ownership **MUST** stay independent of tab/pane churn so an open menu does not re-layout. | shipped | coalescing and observation tests |
| `WS-NFR-003` | restoration safety | Missing, corrupt, ambiguous, oversized, invalid, or newer-version persistence **MUST NOT** trap launch; restore **MUST** be deterministic for the same bytes and filesystem predicates. | shipped | persistence fault matrix |
| `WS-NFR-004` | privacy | Catalog and recent metadata **MUST** remain machine-local; workspace structural events **MUST NOT** include terminal text, file contents, secrets, or other sensitive pane bodies. | shipped | event payload and persistence review |
| `WS-NFR-005` | accessibility | Workspace and footer controls **MUST** have useful spoken labels, selected/focus state, and non-color signals; controls **MUST** remain usable at the minimum sidebar width. | shipped | hosted identity/footer tests and snapshot |
| `WS-NFR-006` | design | Shell density, typography, semantic colors, geometry, icons, and motion **MUST** follow [`designs.md`](../designs.md) and `TenonTheme`; feature-local tokens and arbitrary symbols/colors are forbidden. | shipped | native source/design review |
| `WS-NFR-007` | boundary | Built-in shell mutations **MUST** call typed `WorkspaceStore` services DIRECT; resulting workspace facts **MUST** use EVENT; this PRD **MUST NOT** add a public intent, capability, principal, or `tenon` path. | shipped | interaction and direct-inventory fitness tests |
| `WS-NFR-008` | compatibility | Unknown JSON fields **MUST** be ignored, missing appearance **MUST** restore as default, unknown mark/tint **MUST** degrade independently, and a newer top-level schema **MUST** be declined without restore-time rewrite. | shipped | persistence/identity migration tests |
| `WS-NFR-009` | ownership | Each semantic **MUST** have one state owner: catalog for workspace/tab/pane values, app preferences for sidebar layout, recent-workspace store for closed-folder history, recent-content store for per-workspace view history, and resource pools for live surfaces only. | shipped | architecture/source audit |
| `WS-NFR-010` | visual verification | Titlebar, sidebar at minimum/default width, identity form, and footer **MUST** receive native hosted or installed-app visual verification; headless logic tests alone are insufficient evidence for pixels and pointer feel. | partial | snapshots exist; installed-app focus/light-appearance gaps remain documented |

## 8. Acceptance specification

The linked Gherkin file is the observable acceptance contract. Requirement IDs stay in tags;
XCTest and implementation names remain in the delivery matrix.

| Requirement group | Feature rules | Evidence seam |
|---|---|---|
| WS-FR-001…003, WS-NFR-006 | one shell and valid catalog | scene/source fitness, core construction tests, native window tests |
| WS-FR-004…009, WS-NFR-002, 005 | workspace/sidebar/tab navigation | pure catalog/store tests, hosted shell, XCUITest |
| WS-FR-010…014, WS-NFR-001, 003, 008, 009 | persistence and relaunch | DTO/store fault tests and composition-root relaunch |
| WS-FR-015…017, WS-NFR-005, 006 | workspace identity | core identity, hosted form, snapshots, accessibility projections |
| WS-FR-018…019, WS-NFR-004 | scoped recent content | two-workspace store and hosted launcher tests |
| WS-FR-020…022, WS-NFR-004…007, 010 | footer and event projection | footer tests/snapshot, shipped-plugin and fitness tests |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Classification | Reason |
|---|---|---|
| SwiftUI sidebar/titlebar → `WorkspaceStore` | DIRECT | same semantic owner inside host; no adapter boundary |
| catalog mutation → plugin notification | EVENT | immutable facts that already happened |
| catalog/recent/app-preference persistence | DIRECT resource ownership | internal typed stores own their file lifecycle; not public finite command APIs |
| bundled Workspace Status registration | CONTRIBUTION plus EVENT consumption | plugin declares host-visible status and reacts to a fact |
| CLI/plugin workspace operations | out of scope here | PRD-007/010/011 own their public intent adapters and inventories |

The workspace meaning exists once in the typed domain. Public adapters may call the same
services but may not duplicate the mutation semantics. Workspace customization, recent
menus, tab selection, and sidebar controls remain local/DIRECT and do not justify a new core
intent.

### Native design-system constraints

- Use `TenonTheme` semantic values and the density hierarchy in [`designs.md`](../designs.md).
- The titlebar is 36 points; footer is 34; compact controls are 28 with six-point radius.
- Unselected workspace tints stay visually quiet; marks, labels, selected state, and counts
  carry identity without depending on hue.
- No arbitrary SF Symbol string or hex is accepted from a workspace customization field.
- Respect Reduce Motion for sidebar transitions and preserve native system window dragging.

### Domain and ownership map

| Concern | Primary files | Domain tag |
|---|---|---|
| catalog values and mutations | `Workspace.swift`, `WorkspaceStore.swift` | `workspace-model` |
| restore/write lifecycle | `WorkspaceCatalogStore.swift`, `DurableJSONFile.swift` | `workspace-model`, persistence support |
| workspace and recent identity | `WorkspaceIdentity.swift`, `RecentWorkspaceStore.swift`, `RecentStore.swift` | `workspace-model` |
| titlebar/sidebar/stage | `ContentView.swift`, `ShellTitleBar.swift`, `WorkspaceSidebarView.swift`, `WorkspaceStageView.swift` | `workspace-model` by current inventory |
| customization/footer | `WorkspaceIdentityViews.swift`, `SidebarFooter.swift` | `workspace-model` |
| composition/termination | `TenonApp.swift` | `workspace-model` plus its section tags |

Retrieval must follow [`domains.md`](../domains.md): start with `@domain:.*workspace-model`,
then search every touched symbol to recover cross-file edges hidden by Swift module scope.

### Data, resource, and lifecycle model

```text
one AppComposition / one Window
└── WorkspaceCatalog (value truth)
    ├── Workspace UUID + path + presentation
    │   └── ordered Tab UUIDs + activeTabID
    │       └── spatial Slot UUIDs + activeSlotID + content
    ├── WorkspaceCatalogStore (versioned, coalesced, durable snapshots)
    ├── RecentWorkspaceStore (closed-folder navigation history)
    ├── RecentStore (workspace-ID-scoped content history)
    └── live pools (terminal/web/agent resources keyed by slot; not catalog truth)
```

Successful mutations replace the catalog value, rotate `snapshotID`, reconcile pools, note a
catalog save, record eligible recents, and emit facts. Restore runs before UI composition and
does not produce facts or rewrite its input. Quit captures the final live catalog plus
lightweight placeholders, flushes it, then shuts down plugin and surface resources.

### Security and privacy

- Persistence contains local paths, UUIDs, view identifiers, geometry, and presentation
  metadata. It may be sensitive and remains in the application-support state root.
- Recently opened content never crosses workspace scope and transient file/diff rows are not
  rehydrated into the recent launcher.
- Free-tier workspace events expose counts and structure, not terminal/file contents.
- Workspace customization grants no filesystem, terminal, network, or plugin authority.

### Compatibility

- Schema version 1 is the current catalog format.
- Optional appearance is backward-compatible; default appearance is omitted from writes.
- Unsupported content degrades per pane, whereas an unsupported top-level semantic version
  declines the document.
- Old app-global recent-view rows have no defensible owner and are deliberately discarded.

## 10. Delivery plan

### Requirement delivery matrix

| Requirements | Delivery | Current implementation | Evidence | Known gap |
|---|---|---|---|---|
| WS-FR-001…003, WS-FR-005…009 | shipped | [`TenonApp.swift`](../../Sources/TenonApp/TenonApp.swift), [`Workspace.swift`](../../Sources/TenonCore/Workspace.swift), shell views | `MainWindowSingletonTests`, `WorkspaceTests`, workspace tab-order and native flow tests | full installed-app accessibility journey remains manual |
| WS-FR-002, WS-FR-021, WS-NFR-005…006, 010 | shipped/partial visual | `ContentView`, `ShellTitleBar`, `WindowChrome`, preferences, theme | app-preference tests, sidebar/titlebar snapshots, real-window drag tests | fixed dark theme has no light variant; focus ring not captured |
| WS-FR-004, 006…007 | shipped | `WorkspaceStore`, `RecentWorkspaceStore`, `WorkspaceSidebarView` | `RecentWorkspaceStoreTests`, `WorkspaceTests` | menu labels/settlement primarily source and human observed |
| WS-FR-010…014, WS-NFR-001, 003, 008…009 | shipped | `WorkspaceCatalogSnapshot`, `WorkspaceCatalogStore`, startup/stop composition | `WorkspaceCatalogPersistenceTests`, `WorkspaceCatalogRelaunchTests`, restored-pane tests | no product telemetry for field restore failures |
| WS-FR-015…017 | shipped | `WorkspaceIdentity`, catalog mutations/schema, native identity form | `WorkspaceIdentityTests`, `WorkspaceIdentityFormTests`, sidebar/form snapshots | popover under high catalog churn not measured live |
| WS-FR-018…019 | shipped | `RecentStore`, event-derived attribution, explicit `workspaceID` threading | `RecentStoreTests`, `WorkspaceRecentLauncherTests` | SwiftUI invalidation timing is structurally covered, not separately instrumented |
| WS-FR-020 | shipped | `SidebarFooter`, `AppVersion`, Settings About | `SidebarFooterTests`, sidebar snapshots | Settings About placement lacks a window screenshot |
| WS-FR-022, WS-NFR-004, 007 | shipped | `plugins/workspace-status`, workspace event projection | `ShippedPluginsTests`, interaction/direct inventory fitness | payload privacy remains source-contract tested, not telemetry monitored |

### Phases

| Phase | Outcome | State |
|---|---|---|
| domain foundation | stable workspace/tab/pane identity and active selection | shipped |
| native shell | one window, app mark, titlebar, sidebar, footer | shipped |
| persistence | fail-soft catalog restore and durable write lifecycle | shipped |
| identity and scope | customization and workspace-scoped recent content | shipped |
| evidence completion | installed-app accessibility/focus/appearance review | partial/manual |

### Migration and rollout

- Existing schema-1 catalogs restore without appearance; missing appearance becomes default.
- Legacy app-global recent-view rows are discarded on first read rather than guessed.
- Restore does not rewrite input. The next actual mutation or orderly quit writes current
  state using the current schema.
- No destructive migration or user prompt is required for the shipped state.

## 11. Dependencies, risks, and mitigations

| Risk | Likelihood | Impact | Mitigation/owner |
|---|---|---|---|
| a new shell feature introduces another state owner | medium | high | enforce WS-NFR-009 and architecture review |
| a malformed catalog reaches domain preconditions | low | high | DTO validation, final catalog validity gate, fault matrix |
| UI menu/popover shifts during catalog churn | medium | medium | isolate menu owner from catalog churn; native observation |
| workspace name is mistaken for identity | medium | high | UUID-only APIs and duplicate-name tests |
| per-workspace recents silently become global again | medium | high | no unscoped accessor; two-workspace mutation tests |
| eager restore causes process/memory spikes | medium | high | pure restore plus slot-keyed lazy pools |
| singleton window becomes limiting | medium | medium | treat multi-window as a new resource-ownership PRD, not a scene declaration tweak |

## 12. Open questions and decisions

### Open questions

| ID | Question | Owner | State |
|---|---|---|---|
| `WS-Q-001` | Should customization gain a keyboard/palette entry point? | product + interaction architecture | open; no current promise |
| `WS-Q-002` | What field metric can report restore failure without exposing paths or workspace content? | product + privacy | open |
| `WS-Q-003` | Should a future theme add verified light appearance before shell screenshots claim both modes? | native design | open |

### Decision log

| Date | Decision | Reason | Supersedes |
|---|---|---|---|
| 2026-07-26 | Store catalog through a versioned DTO rather than `Codable` domain types. | hostile/stale bytes cannot reach domain preconditions | direct domain decoding |
| 2026-07-26 | Bare launch restores exactly; explicit directory selects/adds without replacing. | CLI/project launch intent must coexist with recovery | always seed from cwd |
| 2026-08-09 | Workspace UUID is identity; name/mark/tint are presentation. | duplicate names and resets must not disturb scope/tree | display-name identity |
| 2026-08-09 | Recent content is scoped by mutation event workspace ID; canonical root is adoption fallback only. | off-selection mutations must be attributed correctly | selected-workspace/global history |
| 2026-08-09 | Legacy app-global recent rows are discarded. | their workspace cannot be inferred without recreating leakage | speculative migration |
| 2026-08-09 | Sidebar layout remains in app preferences, not catalog persistence. | one owner per semantic | T-027 wording that could imply duplication |
| 2026-08-09 | Only explicit `WindowDragArea` moves the window. | interactive titlebar/tab gestures retain pointer ownership | T-034's older implicit background-drag account |

## 13. Verification receipts

- `WorkspaceTests` pins catalog invariants, workspace/tab selection, last-item guards, event
  ordering, and active pane per tab.
- `WorkspaceCatalogPersistenceTests` covers schema round-trip, launch precedence, bounded
  durable writes, coalescing, flush, and the fail-soft matrix.
- `WorkspaceCatalogRelaunchTests` exercises the real composition root across stop/relaunch.
- `RecentWorkspaceStoreTests`, `RecentStoreTests`, and `WorkspaceRecentLauncherTests` cover
  canonical paths, filtering order, isolation, adoption, clearing, and hosted launcher scope.
- `WorkspaceIdentityTests` and `WorkspaceIdentityFormTests` cover name/appearance invariants,
  migration, hosted geometry, symbols, and spoken projections.
- `SidebarFooterTests` and sidebar snapshots cover destinations, geometry, accessible names,
  minimum width, and removal of version from the sidebar.
- `MainWindowSingletonTests`, interaction/direct-inventory fitness tests, and native window
  XCUITests guard the scene/boundary/titlebar contracts.
- Historical aggregate test counts in task files are receipts for their moment, not a claim
  that the present full suite was rerun for this documentation change.

## 14. Change history

| Date | Change | Author |
|---|---|---|
| 2026-08-09 | Created canonical shipped-state PRD from current source, eight task records, manifests, and focused tests. | Codex |
