# PRD — Workspace shell, identity, recents, and restoration

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-001` |
| Lifecycle | `shipped` |
| Owner | Tenon workspace-model and native-shell domains |
| Reviewers | product, native UI, accessibility, persistence, plugin runtime, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-14 |
| Related work | T-001, T-003, T-027, T-032, T-034, T-097, T-098, T-099, T-154 |
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
without constructing heavyweight pane resources until they are viewed. Workspace rows can be
reordered directly in the sidebar without changing selection or any resource identity.

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
- Pane display-name override from its header menu, including cancellable Companion naming.

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
- The sidebar row selects a workspace, drags vertically to reorder it, and exposes matching
  Move up/down accessibility actions; its secondary menu offers Customize and Remove.
- Secondary-clicking the sidebar body offers Add Workspace and up to five eligible recents.
- The titlebar toggle shows or hides the sidebar; its width is pointer-resizable.
- The tab strip selects a tab; command/launcher and reorder details are specified in
  PRD-002.
- The footer exposes Help, Feedback, and Settings as three compact icon controls.
- A pane-header secondary click offers Rename and AI Rename; both keep the pane's UUID and
  content in place.

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
   accent or leave the colour automatic — the swatch shows the colour Automatic will use.
3. Clearing the name means use the derived folder name; Reset restores derived name,
   default folder mark, and the automatic colour.
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
| `WS-FR-002` | The 36-point hidden-titlebar shell **MUST** show the Tenon mark/wordmark, align tabs with traffic lights **in the default chrome order** (`WS-FR-035`), preserve interactive controls, and give only empty chrome explicit system drag and configured double-click behavior. The title-bar row itself **MUST** keep its window-drag band in every chrome order. | must | shipped | `@req-ws-fr-002` |
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
| `WS-FR-016` | Workspace appearance **MUST** use the closed twelve-mark vocabulary and existing semantic accent vocabulary; Reset **MUST** restore the derived name, folder mark, and the automatic colour without recreating the workspace. | must | superseded by `WS-FR-032` 2026-08-14 | `@req-ws-fr-016` |
| `WS-FR-023` | A workspace with no chosen accent **MUST** be drawn in a colour derived from its canonical folder by a rule that is stable across launches, equal for every spelling of one folder, and beaten by an explicitly chosen accent; the derived palette **MUST** hold every entry to 3:1 against the sidebar chrome and keep its colours perceptually apart. | must | shipped | `@req-ws-fr-023` |
| `WS-FR-024` | Every workspace row **MUST** draw its own colour whether or not it is the selected row, and selection **MUST** remain legible from the row's fill, text weight, and spoken state rather than from the mark's colour. | must | shipped | `@req-ws-fr-024` |
| `WS-FR-017` | A real identity change **MUST** persist compatibly, update every existing host representation through shared formatting, and publish exactly one `workspace.identity-changed` fact; a no-op **MUST** publish nothing. | must | shipped | `@req-ws-fr-017` |
| `WS-FR-032` | Workspace appearance **MUST** offer the closed 24-mark and 12-semantic-accent vocabularies plus one imported image. Import **MUST** decode and normalize off MainActor to a PNG no larger than 64×64 pixels and 128 KiB, embed that result in catalog and recent-workspace persistence rather than retain a source path, degrade malformed saved image bytes to the selected system mark without losing the workspace, and let Reset clear the imported image with the name and accent. | must | shipped | `@req-ws-fr-032` |
| `WS-FR-033` | `workspace.identity.set.v1` **MUST** expose one finite name/accent/icon patch to `{plugin, cli, agent}` through the normal dispatcher. It **MUST** require an exact workspace UUID in invocation scope, never fall back to selection, route to the same typed identity mutation as the native form, normalize custom image bytes by the same rule, and return the final complete identity after publishing at most one `workspace.identity-changed` fact. | must | shipped | `@req-ws-fr-033` |
| `WS-FR-018` | Recently opened content **MUST** be recorded against the workspace ID named by the mutation's own events, read only by an explicitly supplied workspace ID, deduplicate/order independently, cap each bucket at six and the store at 32 workspaces, and clear one bucket without changing another. | must | shipped | `@req-ws-fr-018` |
| `WS-FR-019` | On launch, a stale recent-content bucket **MAY** be adopted only by an unclaimed live workspace with the same canonical root; legacy app-global rows **MUST** be discarded rather than guessed into a workspace. | must | shipped | `@req-ws-fr-019` |
| `WS-FR-020` | The sidebar footer **MUST** contain exactly Help, Feedback, and Settings in one 34-point row of 28-point controls; Help/Feedback destinations **MUST** remain unchanged, and version/build **MUST** move to Settings About instead of the primary sidebar hierarchy. | must | shipped | `@req-ws-fr-020` |
| `WS-FR-021` | Sidebar visibility and width **MUST** initialize from and write through app preferences as their single owner; catalog restoration **MUST NOT** overwrite them. | must | shipped | `@req-ws-fr-021` |
| `WS-FR-022` | The bundled permission-free Workspace Status plugin **MAY** consume `workspace.changed` structural facts and show tab/slot counts, but **MUST NOT** receive pane contents through that event. | should | shipped | `@req-ws-fr-022` |
| `WS-FR-025` | Folders dropped on the sidebar **MUST** each reach the same outcome as Add Workspace — a workspace opened at that folder under its derived name and recorded in recent history — except that a folder an open workspace is already rooted at **MUST** be selected rather than opened a second time; the drop **MUST** preserve the order the folders arrived in, leave the last one active, collapse repeats of one canonical folder within a single drop, accept Finder's `public.file-url` transport only when AppKit resolves it as `public.folder`, and refuse a dropped file without highlighting the sidebar or opening its parent folder. | must | shipped | `@req-ws-fr-025` |
| `WS-FR-026` | Removing a workspace **MUST** inspect live terminal processes across every pane it owns through the same host close gate as tab close; no live terminal or a complete idle inspection **MUST** remove immediately, while running work, incomplete identity, an unavailable inspection, or a pane/process identity changed during inspection **MUST** present one native destructive confirmation; Cancel **MUST NOT** mutate the catalog and Confirm **MUST** remove the workspace. | must | shipped | `@req-ws-fr-026` |
| `WS-FR-027` | A terminal pane whose agent session is resolved exactly — the provider's own hook named that session for this surface and the process group it declared still owns the terminal's foreground — **MUST** be captured with that session beside its terminal record, and **MUST** be restored as the recorded-session reading with its resume offer; a reading below exact confidence, without a session id, or without a transcript **MUST NOT** be captured; a captured session whose transcript is unreadable at restore **MUST** degrade that pane to a terminal with its saved working directory rather than to an empty pane. | must | shipped | `@req-ws-fr-027` |
| `WS-FR-028` | A pane-header secondary click and the pane's VoiceOver actions **MUST** offer Rename and AI Rename. Manual Rename **MUST** be typed on the pane's own title — no surface presented over the shell — where Return commits, Escape restores, and clicking away commits; it **MUST** normalize and cap the label at 60 characters, persist it separately from a terminal's dynamic title, prefer it in pane/tab/process-monitor chrome, and treat an empty value as return to the automatic content title without changing pane UUID, owner, content, geometry, or surface. | must | shipped | `@req-ws-fr-028` |
| `WS-FR-029` | AI Rename **MUST** snapshot the app's Companion profile, run its selected installed agent as one bounded turn, and accept only a title from the provider's machine-readable JSON channel and the shared title schema; Claude + Haiku remains the compatible default. The user **MUST** be able to cancel, and removing the pane through close-pane, close-tab, workspace removal, or shutdown **MUST** cancel its Swift task and terminate the CLI process; switching tabs **MUST NOT** cancel it. | must | shipped | `@req-ws-fr-029` |
| `WS-FR-030` | A rename **MUST** be reported by the pane being renamed and **MUST NOT** present any surface over the shell: a running generation **MUST** read as `Naming…` on that pane's title while the pane stays usable, a validated title **MUST** return the title to normal presentation, and a failure **MUST** read as `Rename failed` with the provider's message as its tooltip and **MUST** clear itself after a bounded linger without an operator gesture. Rename state **MUST** be per pane, so concurrent generations on different panes cannot displace one another, and the pane's own name **MUST** remain what the rename actions start from while a state is being reported in its place. | must | shipped | `@req-ws-fr-030` |
| `WS-FR-031` | A primary drag of at least six points beginning on a sidebar workspace row **MUST** reorder that workspace live by row midpoint, use no pasteboard payload, restore the original order when released outside the admitted horizontal band, and preserve active workspace/tab/pane selection, roots, content, and surface identity. Each row **MUST** expose Move workspace up/down only where that move exists, speak its position and completion, persist the resulting catalog order, and publish `workspace.moved` only for a real move. | must | shipped | `@req-ws-fr-031` |
| `WS-FR-035` | The shell **MUST** draw its two movable chrome strips — the tab strip and the plugin status strip — in one stated order, each occupying exactly one of the title bar's content zone and the foot row. Reordering **MUST** move a strip whole: pixels, pointer ownership, reorder and close gestures, drop targeting, launcher, and accessibility actions. It **MUST NOT** move the traffic lights, identity zone, resource monitor or quick commands, and **MUST NOT** disturb any workspace, tab, pane, selection or live surface. Exactly one implementation of each strip **MUST** exist. Stated cost: tabs at the foot spend 10 points more of the window on chrome (36+1+1+34 against 36+1+1+24). | must | shipped | `@req-ws-fr-035` |
| `WS-FR-034` | While the sidebar is collapsed, the title bar's identity zone **MUST** read the active workspace's name instead of the Tenon wordmark, truncate it at the tail rather than dropping it, and carry the full name in its tooltip and accessibility label. A blank or absent name, and the expanded sidebar — where the workspace list already names the active workspace — **MUST** read the wordmark, which keeps being dropped whole when the zone is too narrow for it. | must | shipped | `@req-ws-fr-034` |
| `WS-FR-036` | An expanded sidebar row whose workspace holds agent panes **MUST** name them under the workspace name instead of counting tabs: the still line reads the workspace's own path, head-truncated so its most identifying (deepest) component stays on screen, and a count of the remaining agent panes. The line **MUST** hold still — a path too wide for the row is truncated at its head, and the full path is available from its tooltip — and the row **MUST NOT** schedule any timed work for it; no per-pane attention glyph is drawn on this line. A row that holds agent panes **MUST** offer a disclosure toggle, its own click target separate from the row's, that opens or closes the row's full account — naming **every** agent pane in catalog order, each with the name it answers to and a glyph for the state its own `PaneActivity` machine holds — growing the row in place under the line it belongs to. Clicking the toggle **MUST NOT** select the workspace, and selecting the workspace **MUST NOT** open or close the account. The account **MUST** stay exactly as the toggle last left it regardless of which workspace is selected, until the toggle is clicked again or the workspace's last agent pane leaves, which **MUST** close it. Choosing an agent pane from the open account **MUST** bring its workspace, its tab and that pane forward in a single typed mutation and give it the keyboard. The row's own click target and the toggle's **MUST** each stay reachable at every point of their own area — neither may claim the other's clicks. A collapsed (rail) row **MUST** offer the same panes from its context menu, since the rail has no room for the toggle and that menu is its only route to them; an expanded row's context menu **MUST NOT** repeat them, since the still line and its account already name them inline. The row's spoken label **MUST** name every agent pane once, regardless of whether the account is open. A row with no agent pane **MUST** read its tab count exactly as before and offers no toggle. No state may be recomputed here: the account's glyph reads the one attention vocabulary. | must | shipped | `@req-ws-fr-036` |

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
| `WS-NFR-012` | Chrome-order visual verification | Both chrome orders **MUST** be photographable offscreen, whole-shell, on a headless machine: `TENON_CHROME_SNAPSHOT` with `_ORDER`, `_SIDEBAR` and `_SIZE`. A row that is on screen at all times cannot be signed off from a view-tree assertion, which says a row has the right *shape* and nothing about its geometry. The window's bottom resize gutter **MUST** be measured rather than reasoned about — `scripts/internal/foot-strip-edge-probe.swift`, exit 0 — because no headless test can see it. | shipped | `ShellChromeSnapshot`, the foot-edge probe, and both orders captured at 1100×620 |
| `WS-NFR-011` | AI rename bounds | Pane-title synthesis **MUST** stay off `MainActor`, accept at most a 12 KiB content excerpt, retain at most 64 KiB stdout and 8 KiB stderr, stop after 60 seconds, and expose no pane content in its workspace event. | shipped | generator/coordinator tests and interaction inventory |

## 8. Acceptance specification

The linked Gherkin file is the observable acceptance contract. Requirement IDs stay in tags;
XCTest and implementation names remain in the delivery matrix.

| Requirement group | Feature rules | Evidence seam |
|---|---|---|
| WS-FR-001…003, WS-NFR-006 | one shell and valid catalog | scene/source fitness, core construction tests, native window tests |
| WS-FR-004…009, WS-NFR-002, 005 | workspace/sidebar/tab navigation | pure catalog/store tests, hosted shell, XCUITest |
| WS-FR-031, WS-NFR-005, 007 | workspace sidebar reorder | pure reorder/catalog/store/persistence tests plus installed-app pointer verification |
| WS-FR-025 | opening a workspace by dropping its folder | pure planner tests plus mounted AppKit pasteboard/destination tests |
| WS-FR-026 | process-safe workspace removal | shared coordinator branches, sidebar-adapter fitness, and a hosted native-window alert test |
| WS-FR-010…014, WS-NFR-001, 003, 008, 009 | persistence and relaunch | DTO/store fault tests and composition-root relaunch |
| WS-FR-027 | an agent pane comes back reading its own session | pure capture-eligibility tests plus the catalog document's record/restore rules |
| WS-FR-028…029, WS-NFR-011 | manual and AI pane naming | core mutation/persistence, Companion Claude/Codex JSON parsing, coordinator cancellation, and native menu tests |
| WS-FR-015…017, WS-FR-032…033, WS-NFR-005, 006 | workspace identity | core identity, hosted form/import, intent contract/provider, snapshots, accessibility projections |
| WS-FR-018…019, WS-NFR-004 | scoped recent content | two-workspace store and hosted launcher tests |
| WS-FR-020…022, WS-NFR-004…007, 010 | footer and event projection | footer tests/snapshot, shipped-plugin and fitness tests |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Classification | Reason |
|---|---|---|
| SwiftUI sidebar/titlebar → `WorkspaceStore` | DIRECT | same semantic owner inside host; no adapter boundary |
| native workspace identity form → `WorkspaceStore` | DIRECT | built-in SwiftUI reaches the typed same-owner identity mutation |
| CLI/plugin/agent workspace identity patch | INTENT | finite unicast request/reply across a public principal boundary |
| catalog mutation → plugin notification | EVENT | immutable facts that already happened |
| catalog/recent/app-preference persistence | DIRECT resource ownership | internal typed stores own their file lifecycle; not public finite command APIs |
| pane Rename → `WorkspaceStore.renameSlot` | DIRECT | focused host chrome and one typed semantic owner |
| pane AI Rename process | host-private RESOURCE/TASK, then DIRECT | bounded independently-running process owned by the pane; validated result enters the same typed mutation |
| pane label changed → observers | EVENT | `workspace.slot-identity-changed` is an ID-only fact that already happened |
| bundled Workspace Status registration | CONTRIBUTION plus EVENT consumption | plugin declares host-visible status and reacts to a fact |
| CLI/plugin workspace operations | out of scope here | PRD-007/010/011 own their public intent adapters and inventories |

The workspace meaning exists once in the typed domain. Public adapters call the same
services and may not duplicate mutation semantics. The native customization form, recent
menus, tab selection, and sidebar controls remain local/DIRECT; the separately authorized
CLI/plugin/agent customization route is the finite `workspace.identity.set.v1` INTENT.

### Native design-system constraints

- Use `TenonTheme` semantic values and the density hierarchy in [`designs.md`](../designs.md).
- The titlebar is 36 points; footer is 34; compact controls are 28 with six-point radius.
- Every workspace mark carries its own hue; marks, labels, selected state, and counts still
  carry identity without depending on hue, so colour is added as a channel and never the
  only one.
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
    │       └── spatial Slot UUIDs + activeSlotID + content + optional custom title
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
- AI Rename sends a bounded pane-content brief only after the explicit AI Rename gesture;
  the resulting workspace event contains IDs only, never the brief or generated title.

### Compatibility

- Schema version 1 is the current catalog format.
- Optional appearance and optional pane custom title are backward-compatible; missing values
  restore their automatic presentation.
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
| WS-FR-031, WS-NFR-005, 007 | shipped | [`WorkspaceReorder.swift`](../../Sources/TenonCore/WorkspaceReorder.swift), `WorkspaceCatalog.moveWorkspace`, `WorkspaceStore.moveWorkspace`, and the sidebar row gesture/accessibility actions | `WorkspaceReorderTests`, `WorkspaceOrderTests`, persistence round trip, direct/event/domain fitness | SwiftUI's pointer gesture cannot be driven reliably by the headless host; installed-app drag feel remains manual |
| WS-FR-010…014, WS-NFR-001, 003, 008…009 | shipped | `WorkspaceCatalogSnapshot`, `WorkspaceCatalogStore`, startup/stop composition | `WorkspaceCatalogPersistenceTests`, `WorkspaceCatalogRelaunchTests`, restored-pane tests | no product telemetry for field restore failures |
| WS-FR-015…017, WS-FR-032…033 | shipped | `WorkspaceIdentity`, catalog mutations/schema, native identity form/import, core intent catalog/provider | `WorkspaceIdentityTests`, `WorkspaceIdentityFormTests`, `WorkspaceIntentProviderTests`, catalog fitness | file-picker and popover behavior remain an installed-app check; popover under high catalog churn not measured live |
| WS-FR-018…019 | shipped | `RecentStore`, event-derived attribution, explicit `workspaceID` threading | `RecentStoreTests`, `WorkspaceRecentLauncherTests` | SwiftUI invalidation timing is structurally covered, not separately instrumented |
| WS-FR-020 | shipped | `SidebarFooter`, `AppVersion`, Settings About | `SidebarFooterTests`, sidebar snapshots | Settings About placement lacks a window screenshot |
| WS-FR-022, WS-NFR-004, 007 | shipped | `plugins/workspace-status`, workspace event projection | `ShippedPluginsTests`, interaction/direct inventory fitness | payload privacy remains source-contract tested, not telemetry monitored |
| WS-FR-025 | shipped | [`WorkspaceFolderDrop.swift`](../../Sources/TenonCore/WorkspaceFolderDrop.swift), `WorkspaceStore.openDroppedFolders`, mounted `WorkspaceFolderDropZone` / AppKit destination | `WorkspaceFolderDropTests` (9 assertions, three mutations killed); `WorkspaceFolderDropAdapterTests` (mounted shipping zone, Finder transport, entry/exit/perform lifecycle) | no automated pointer journey starts in Finder; the native pasteboard and destination callback boundary is hosted directly |
| WS-FR-026 | shipped | `ShellCloseCoordinator`, `ContentView` native alert, sidebar and title-bar gesture adapters | `WorkspaceCloseConfirmationTests` (shared branches, exact sidebar wiring, hosted `NSWindow` sheet and Cancel button) | real-PTY running process remains covered by inspector/teardown tests; no installed-app context-menu journey was claimed because local Accessibility automation was unavailable while production stayed open |
| WS-FR-027 | shipped | [`AgentPaneSessionCapture.swift`](../../Sources/TenonApp/AgentPaneSessionCapture.swift), `WorkspaceCatalogSnapshot.document`/`restore`, and both catalog save sites in `AppComposition` | `AgentPaneSessionCaptureTests` (9 assertions; the `.exact` guard killed a mutation that admitted `.inferred`), `WorkspaceCatalogPersistenceTests` (capture shape, restore, and both degraded forms, red before the change) | eligibility is asserted against the resolver's verdict, not against a real agent: no automated relaunch drives a live PTY through quit and back |
| WS-FR-028…029, WS-NFR-011 | shipped | `PaneTitle`, catalog mutation/schema, `PaneRenameCoordinator`, `CompanionPaneTitleGenerator`, pane menu and modal overlay | `PaneTitleTests`, `PaneRenameTests`, `SpatialCanvasInteractionTests`, direct/event/resource inventory gates, 900×600 offscreen capture of the shipping modal | installed-app pointer feel and live provider-account runs remain manual; process arguments, structured-channel parsing, and cancellation are automated |
| WS-FR-035, WS-NFR-012 | shipped | [`ShellChromeOrder.swift`](../../Sources/TenonCore/ShellChromeOrder.swift) (the pure rule), [`ShellTabStrip.swift`](../../Sources/TenonApp/ShellTabStrip.swift) (the one strip, taking its row's edge), [`ShellFootBar.swift`](../../Sources/TenonApp/ShellFootBar.swift), [`ShellChromeOccupant.swift`](../../Sources/TenonApp/ShellChromeOccupant.swift) (the one chooser), `ShellTitleBar`, `ContentView` | `ShellChromeOrderTests` (9, headless — placement, edge derivation, and the preferences round trip); `ShellChromeLayoutTests` (8 — foot height, sidebar-footer collinearity, gutter clearance, and the source sweeps that hold "one strip, one chooser"); `TabStripReorderTests` (23, real windows — including a reorder, a press, and a drag-region read at the foot, and one test that presses the same three fractions in both orders and demands the same tabs); `ShellChromeSnapshot` at both orders | the 26-pt chip clears the measured 3.1-pt resize gutter by 0.9 pt at a 34-pt row — thin, and why the probe exists; a live hardware drag on an installed build in the foot order is still owed |
| WS-FR-034 | shipped | [`ShellIdentityLabel.swift`](../../Sources/TenonApp/ShellIdentityLabel.swift) and `ShellTitleBar.identityRow` | `ShellIdentityLabelTests`; `TENON_TITLEBAR_SNAPSHOT` photographs the shipping row collapsed, expanded, and with a name too long for the zone | the zone is ~90 pt after the traffic-light inset, so a long name is read from its tooltip rather than the bar |
| WS-FR-036 | shipped | [`WorkspaceAgentTagline.swift`](../../Sources/TenonApp/WorkspaceAgentTagline.swift) (the pure join and the drawn state vocabulary), [`AgentPaneRoster.swift`](../../Sources/TenonApp/AgentPaneRoster.swift) (agent-ness, synchronous, for every workspace), `WorkspaceSidebarView`'s `WorkspaceAgentTaglineView` (the still line) / `accountToggle` (the one control that opens or closes the account, a sibling button beside the row's own — never nested in it) / `WorkspaceAgentList` + `WorkspaceAgentListLayout` (the account and its way in, `WorkspaceStore.focusSlot`, and `isActive` muting its rows the same way the row's own name mutes) / `AgentStateIndicator` / `PulsingDot`, `WorkspaceRowAnnouncement`, two added sinks on `AgentHookLensBus` (`AgentPaneRoster`, and `SurfacePool.noteAgentTurnFinished(for:)` reached through `TerminalSurface.noteAgentTurnFinished()` on a root-session `Stop`), `SurfacePool.surfaceToken(for:)` | `WorkspaceAgentTaglineTests` (9, headless — roster filtering, the terminal-content guard, catalog ordering, the title chain, every state copied out of a machine driven to it, and the drawn vocabulary; two mutations killed); `AgentPaneRosterTests` (13 — subagent refusal, incarnation guard, eviction, the known gap pinned, and `AgentHookLensBus.isRootTurnBoundary`); `PaneAttentionTests` (the hook-driven finish reaching the same state a real OSC 133 one would); `WorkspaceIdentityFormTests` (the spoken list, that a row with no agent speaks what it always spoke, the list's one-row-per-pane density mounted through `NSHostingView`, and that it sizes to its own content rather than a fixed width); `WorkspaceTests` already pins the cross-workspace half of `focusSlot` the list's click depends on; `TENON_SIDEBAR_SNAPSHOT` at 232 and 110, staging four states through the real machine and printing what each one reached | at 110 pt a row that also carries the unseen capsule has ~7 pt left and shows its glyph without text — which is what the toggle, available at that width too, is for; an agent that exits leaving its shell alive keeps its line, because no installed hook reports a session ending; whether clicking the toggle actually opens the account, and never also selects the workspace, is an installed-app check, since a test can mount the list but cannot press a button; and whether a live hook server actually delivers `Stop` for an interactive session the way the composed fixtures assume is likewise installed-app-only — all three in the decision log |
| WS-FR-023…024 | shipped | `WorkspaceTint`, `WorkspaceMark`, identity form Automatic swatch | `WorkspaceTintTests`, `WorkspaceIdentityFormTests`, sidebar snapshots at both bounds | a pure path→colour rule cannot keep a whole sidebar distinct: eight workspaces collide about once, and the popover is the remedy |

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
| an AI title run outlives the pane it describes | medium | high | catalog-liveness cancellation plus process termination and stale presentation token |
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
| 2026-08-17 | Agent-ness for a sidebar row comes from a new observable roster fed by the hook bus, not from `AgentSessionRegistry`. | the registry is an `actor` and a view body cannot `await` one; and the only synchronous reader of the same stream, `AgentLensPool.ingest`, routes to per-pane models that exist only for a MOUNTED pane — precisely the set a background workspace's row can never be in. The roster stores the pane and its surface incarnation and nothing an agent said, so it is a third reader of one stream rather than a second judgement | reading `boundPanes()` from the row, or storing agent-ness on `WorkspaceSlot` where the catalog would persist a runtime fact |
| 2026-08-17 | One writer, not two: the roster is fed by hooks alone, with no second write at the agent launch site. | the launch writer was specified to cover the window before an agent's first tool call, and that window does not exist here. `AgentSessionRegistry` lags because its own `record` refuses an event with no session payload; this roster asks only for a pane id and a surface token, and `SessionStart` is installed and reaches the bus unfiltered. A second path to a fact already covered would be two paths for one job, and it would still miss the agent nobody launched through Tenon | a `note(slotID:surfaceToken:)` call in `AgentLaunchExecutor` |
| 2026-08-17 | An agent that exits leaving its shell alive keeps its line until the pane is rebuilt. | no installed hook reports a session ending — `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop` — and `Stop` is a turn boundary. The check that would settle it is `AgentCallerAdmission`'s process-group comparison, which costs an FFI read plus a `getpgid` per agent pane on a body that re-renders at the attention poll's cadence. T-141 is what unmeasured per-pane work on that path costs, so the gap is stated and pinned by a test rather than closed by a guess | inferring the ending from the pane's title, or from `Stop` |
| 2026-08-17 | The line names one pane and holds still; every pane, and the way into it, is in the popover a hover opens. | a sidebar row is redrawn constantly and by design — hover writes the row's own state, and its entries are recomputed whenever a pane's title or attention state changes, which is exactly while an agent is working — so any motion held in that row's SwiftUI state is re-entered by every one of those redraws. The operator watched both consequences: a moving title restarted whenever they hovered, and a title crossing the row left it blank for the row's width once per cycle. Holding the line still removes the class rather than the symptom, and the popover carries what one line cannot: all of the panes, their states, and a click that hands one the keyboard. The T-141 rule holds absolutely now — a sidebar of any size schedules nothing for this line | a marquee whose crossing lives in Core Animation instead (accurate, and still one line naming one pane at a time); a rotation on a stable anchor; naming a count instead of the work, which is the tab count under a new name |
| 2026-07-26 | Store catalog through a versioned DTO rather than `Codable` domain types. | hostile/stale bytes cannot reach domain preconditions | direct domain decoding |
| 2026-07-26 | Bare launch restores exactly; explicit directory selects/adds without replacing. | CLI/project launch intent must coexist with recovery | always seed from cwd |
| 2026-08-09 | Workspace UUID is identity; name/mark/tint are presentation. | duplicate names and resets must not disturb scope/tree | display-name identity |
| 2026-08-09 | Recent content is scoped by mutation event workspace ID; canonical root is adoption fallback only. | off-selection mutations must be attributed correctly | selected-workspace/global history |
| 2026-08-09 | Legacy app-global recent rows are discarded. | their workspace cannot be inferred without recreating leakage | speculative migration |
| 2026-08-09 | Sidebar layout remains in app preferences, not catalog persistence. | one owner per semantic | T-027 wording that could imply duplication |
| 2026-08-09 | Only explicit `WindowDragArea` moves the window. | interactive titlebar/tab gestures retain pointer ownership | T-034's older implicit background-drag account |
| 2026-08-10 | Every row draws its workspace's colour, selected or not. | recognition serves the workspace one is not in yet, so a colour shown only on selection is shown only once it is no longer needed; selection is carried by fill and text as it is in every native sidebar, and holding unselected marks back costs contrast they cannot spare (2.89:1 at 72% opacity) | "unselected workspace tints stay visually quiet" |
| 2026-08-10 | An unchosen accent means automatic — a colour derived from the workspace's folder — rather than the app accent. | differentiation that must be assigned by hand, and then remembered as a mapping, is still something to remember; a derived default makes an uncustomised catalog already distinct, and the five named accents remain for anyone settling a colour deliberately | nil accent inherits the Settings accent |
| 2026-08-14 | The deliberate accent vocabulary expands from five to twelve semantic choices; Automatic still uses the ten-hue derived palette. | the operator asked for materially more deliberate choices, while changing the derived palette would disturb the colour every untouched workspace already remembers. Two balanced rows fit the compact 320-point form without a scroller and keep selection redundant in shape. | the five named accent limit in `WS-FR-016`; altering the derived palette |
| 2026-08-14 | An uploaded workspace icon is copied as a bounded normalized PNG into identity persistence, never retained as a file path. | upload means the result must survive moving or deleting the source. Decoding, pixel bounds, and thumbnailing happen before bytes enter the catalog; invalid restored bytes cost only the bitmap and fall back to the selected closed symbol. | source-path references or arbitrary image bytes in workspace state |
| 2026-08-14 | Native identity editing stays DIRECT; `workspace.identity.set.v1` is the one public adapter for CLI/plugin/agent customization. | built-in SwiftUI and external principals have different boundaries but one semantic owner. Exact workspace scope prevents a background caller from recolouring whichever project the operator selected most recently. | selection fallback or a second CLI-specific identity service |
| 2026-08-12 | A file dropped on the sidebar is refused, never read as the folder containing it. | the sidebar accepts `public.folder` alone, so AppKit shows a refusal before any Tenon code runs. Opening a dropped file's parent would be right for a file inside a project and wrong for one on the Desktop, and the two are indistinguishable at the moment of the drop; refusing keeps "what a workspace is rooted at" a thing the operator states rather than a thing Tenon infers | T-138's alternative of deriving the parent folder |
| 2026-08-12 | Several folders in one drop all open, in arrival order, with the last one active. | it is what a run of `addWorkspace` calls already does, so a drop of one folder and a drop of five agree about where the operator lands; silently taking the first and discarding the rest would throw away something the operator handed over | opening only the first dropped folder |
| 2026-08-14 | Workspace rows use the same live midpoint reorder model as header tabs, rotated vertically, and never enter the pasteboard. | the row itself is the only truthful preview of its destination; stable UUID identity makes active selection and every owned tab/pane travel with it, while a local gesture cannot accidentally become a Finder/plugin drop route | commit only on release, a pasteboard drag, or a second workspace-order state owner in the view |
| 2026-08-13 | A terminal pane running an agent is captured with that session and comes back reading it, and eligibility is the lens's own `.exact` verdict rather than a second rule. | the pane→session binding lives in memory and dies with the process, so the pane that was doing the work is precisely the pane that comes back with no route to its transcript, its summary, or its resume. Reusing the resolver the live pane already consulted means a restart can never claim more about a pane than the pane was showing — a cwd-and-mtime guess that survives a quit is indistinguishable from a fact, so `.inferred` is refused. A pane whose agent has exited and handed the shell back fails the process-group half of that verdict and stays a terminal, which is what the person was looking at when they quit | "a pane holding a terminal restores as a bare terminal" |
| 2026-08-13 | The captured session travels beside the `terminal` record instead of replacing its type. | the pane's fallback is then real rather than blank: a transcript deleted between quit and launch leaves the terminal it always was, in its own saved directory, and a build that has never heard of the field reads the type it already knows. The `agentSession` content kind keeps its own stricter answer — a pane opened as a reading has nothing to be but empty when the reading is gone | recording an agent pane as the `agentSession` content type |
| 2026-08-13 | A pane custom title is optional presentation on the pane UUID, and AI Rename is a pane-owned host-private task whose validated JSON enters the same rename mutation. | dynamic content titles remain available by clearing the override; one identity and one mutation path survive manual/AI naming, while catalog liveness supplies one teardown authority for every way the pane can die | storing names in surface pools or adding a public rename intent |
| 2026-08-14 | A rename reports on the pane's own title; the rename modal was deleted rather than kept for the manual branch. | the modal dimmed the whole shell and trapped focus to say one word about one pane, which is the opposite of what a supervision surface is for — the operator renaming a pane is usually watching the work in it. Pane state belongs beside the pane's attention dot and header contributions, and putting it there also removes the single-presentation bottleneck: two panes can name themselves at once because each phase is keyed by its own pane | keeping the modal for the text field, or a second window-level surface for AI progress |
| 2026-08-14 | A failed generation says so on the title for a bounded linger and then withdraws itself; retry is the menu item that started it. | with no dialog there is nothing to dismiss, so a failure that waited for a gesture would sit on a pane's header indefinitely and read as the pane's name. The linger is long enough to be read and short enough that the pane returns to saying what it IS; the provider's sentence rides the tooltip because a 34-point strip is not where a CLI error is read | a persistent failure state with an inline Try Again control on the strip |
| 2026-08-14 | The generating state is a static glyph and a word, not an animated spinner. | an animated glyph writes `stringValue` on an `NSTextField` ten times a second, and every write invalidates its intrinsic size and re-solves the header strip on the main thread. That is the exact churn T-091 and T-141 were opened for in this tree, and `Naming…` already says the pane is working | an `NSProgressIndicator` or a braille-frame timer in the header |
| 2026-08-10 | The derived palette is ten hues spaced by eye, not twelve spaced evenly. | an even wheel puts three hues in the greens where discrimination is weakest; the snapshot showed them reading as one colour while every count- and contrast-based test passed. ΔE 25.1 against 16.7, for about a third of a workspace more collisions | evenly spaced twelve-hue wheel |
| 2026-08-16 | The workspace row is as tall as the collapsed rail leaves it wide — `WorkspaceSidebarLayout.rowHeight` derives from `collapsedRowWidth` (38 pt) instead of naming its own number. | collapsed, a workspace is a mark and nothing else, so the row *is* the shape its fill draws: at 46 pt over 38 pt of width the selected and hovered rail read as stripes. The same height also returns the expanded row to `designs.md`'s two-line utility row band (36–40 pt), which 46 sat outside of, and derivation means widening the rail or its inset keeps the mark square rather than quietly making it a rectangle again | a 46 pt row height carried as a literal |
| 2026-08-16 | A row of swatches spans the popover's content width, with the leftover width spread between the marks as `WorkspaceIdentityFormMetrics.columnSpacing(for:)`; marks and tints share one grid builder, and Upload Custom Icon spans the same width. | fixed columns occupied only what they contained — 266 pt of 292 under the marks, 232 pt under the tints — so 60 pt piled against the right inset and the tint row read as having stopped early, which is what the operator photographed. Deriving the gap keeps the deliberate column counts (8 marks over 3 even rows, 13 tints over 2 balanced rows) while making the width the row is laid out from the width it gives back | a wider popover, a stub last row of tints, or per-grid spacing constants |

## 13. Verification receipts

- `WorkspaceTests` pins catalog invariants, workspace/tab selection, last-item guards, event
  ordering, and active pane per tab.
- 2026-08-14, `WS-FR-031`: `WorkspaceReorderTests` pins midpoint insertion, destination
  translation, horizontal cancellation, and spoken position. `WorkspaceOrderTests` pins
  real/no-op store publication, active workspace/tab/pane preservation, and persistence of
  the chosen order. The shipping SwiftUI gesture remains an installed-app pointer check.
- 2026-08-17, `WS-FR-036`: the sidebar's tab count became the work its agents are doing.
  `WorkspaceAgentTaglineTests` pins the join headlessly, and a mutation was killed to prove it
  has teeth: dropping the terminal-content guard took
  `testAPaneThatStoppedBeingATerminalIsNotNamedHoweverStaleTheRosterIs` red.
  `AgentPaneRosterTests` (10) did the same for the roster — dropping the surface-incarnation
  comparison and admitting subagent hooks each killed exactly the test written for it. Full
  suite **2358 / 0**.
  What the pictures added that no test could: the first render photographed `working` and
  `idle` as the same hollow ring. Two separate faults, both real. The indicator was a mini
  `ProgressView`, which draws as a plain ring in a still frame — replaced by a filled dot that
  pulses, so the filled/hollow pair distinguishes them without depending on motion. And the
  snapshot fixture itself was wrong: it set three changing screen fingerprints and stopped, so
  the activity poll running through the render's 390 ms layout pass drove the pane to `idle`
  before the shutter. `StubTerminalSurface.screenKeepsChanging` is what a screen still moving
  actually is. The fixture now prints the state each pane reached beside the one it staged,
  because a picture cannot be read back for its states.
- 2026-08-17, `WS-FR-036`, second pass (T-179): the operator watched a live row and reported
  two things the suite could not see — a title crossing the row left the row blank for the
  row's own width once per cycle, and the crossing restarted whenever they hovered. The second
  is structural: a row is redrawn on hover and on every title or attention change in it, and a
  crossing held in that row's SwiftUI state is re-entered by each redraw. So the motion is
  gone. The line names the first agent pane with a `+N` for the rest and truncates at its tail,
  and a hover opens `WorkspaceAgentList` — every pane, its state, and a click that calls
  `WorkspaceStore.focusSlot`, which brings a background workspace's tab and pane forward in one
  mutation. The same panes are in the row's context menu, so choosing one is not a
  pointer-only route. `WorkspaceAgentTaglineTests` lost the four rotation-arithmetic tests with
  the rule they asserted; `WorkspaceIdentityFormTests` gained
  `testTheHoveredAgentListDrawsOneRowPerPaneAtItsStatedDensity`, mounted through
  `NSHostingView` at 1, 3 and 6 panes — mutation-checked by drawing only the first entry, which
  took it red on both the 3-pane and 6-pane measurements. Full suite **2359 / 0**, and
  `WorkspaceIdentityFormTests` **19 / 0**. The sidebar snapshot at 232 pt
  shows four rows each naming their agent with a truncated title and a state glyph, and the
  three agentless rows still reading `1 tab`. What no headless run can reach: that a hover
  opens the popover at all, and that the pointer crossing into it keeps it open.
- 2026-08-18, `WS-FR-036`, third pass (T-179): the operator's live pointer found what the
  second pass's own decision log had already flagged as unreachable headlessly — the popover
  it shipped animated in slowly enough to feel wrong on an ordinary hover, went visibly
  inconsistent when the pointer crossed several rows quickly, and its anchor on the tagline
  swallowed clicks meant for the row's own `select`. Root cause read from the source, not
  guessed: the row carried *two* independent `.popover(isPresented:)` bindings in one view
  subtree — the agent list on the tagline, the customisation form on the button underneath —
  and SwiftUI drives at most one active popover per view. The two raced for the anchor on
  every hover, which is what made the system's own show/hide animation look like it was
  fighting itself, and put a popover-anchor view directly over a click the outer `Button` was
  supposed to receive. Operator's call on the shape (not this task's): drop the popover
  outright at the expanded width, where a fixed-position `.popover` fights a list of rows that
  are constantly redrawn anyway. The row's account now grows in place, under the line, at
  `WorkspaceSidebarLayout.reorderAnimation` (0.12 s, an existing constant, not a new one) — the
  same duration a reorder already uses, chosen so a pointer crossing several rows never
  outruns it. The rail keeps the popover, since it has no width to grow into, but now behind
  one `.popover(item:)` anchored on the row's own button — `WorkspaceRowPopover` (`.agents`,
  `.customize`), the single piece of state a row's two on-demand surfaces now share, closing
  the identity-churn source rather than papering over its symptom. `WorkspaceAgentList` gained
  `fixedWidth` (default `true`, unchanged for the rail's popover; `false` inline, where the row
  itself bounds the width and the popover's fixed 260 pt would overflow or clip). New:
  `testTheInlineAgentListDoesNotForceThePopoverWidth`, headless, pinning that `fixedWidth:
  false` sizes to content instead of staying pinned to the popover's width. Full suite
  **2360 / 0**. Still true from the second pass, now for two shapes instead of one: whether a
  hover actually opens either account, and whether every point on an expanded row's line still
  answers a click, are installed-app checks — no headless run can hover a pointer or click one.
- 2026-08-19, `WS-FR-036`, fourth pass: the operator found a second reflow bug in the third
  pass's own fix, this time with no popover involved — the expanded row's account still opened
  and closed on hover, and closing a row the pointer had just left shifted every row below it
  at the exact moment the operator's pointer was travelling toward one of them, so a click meant
  for the next workspace missed. Hover-driven open/close is withdrawn outright rather than
  layered under a new control: `WorkspaceRow` now offers one disclosure toggle per row (a
  chevron at the trailing edge, drawn only where `agentEntries` is non-empty) as a sibling
  button beside the row's own `select` button — not nested inside it, since a button nested in
  a button's label only ever fires the outer one, and firing the toggle must never select the
  workspace. `isShowingAgentsInline` is now written from exactly one place, the toggle's own
  action, and it is no longer reset when the sidebar collapses to the rail: a pin now records a
  deliberate operator choice rather than transient hover state, so it survives the row
  disappearing into the rail and reappearing at the expanded width. The rail lost its popover
  outright — `WorkspaceRowPopover` (`.agents`/`.customize`), `holdAgents`, `openAgents`,
  `closeAgents`, and the 180 ms dismissal grace are all deleted, since nothing drives them any
  more. The rail's context menu (already required by this same requirement) is now the only way
  to reach a rail row's panes without returning to the expanded width; the row's own
  accessibility identity moved from the row's outer container onto its `select` button
  specifically, because a container holding two focusable children (the toggle sits beside it)
  does not adopt a label placed on the container itself — an identity left there would silently
  never be spoken. `WorkspaceAgentList` lost `fixedWidth`: the popover was its only caller ever
  passing `true`, so the parameter is gone rather than kept for a mode nothing calls any more,
  and `WorkspaceAgentListLayout.width` (260 pt) went with it.
  `WorkspaceIdentityFormTests`' two popover-vs-inline tests became one
  (`testTheAgentListDrawsOneRowPerPaneAtItsStatedDensity`, height only, the width assertion
  dropped with the fixed width it measured) plus a new
  `testTheAgentListSizesToItsOwnContentNotAFixedWidth`, asserting a longer title measures wider
  than a shorter one now that nothing pins either to 260 pt. Full suite **2379 / 0**;
  `TENON_SIDEBAR_SNAPSHOT` at 232 and 110 pt shows the toggle beside every row naming an agent
  and no toggle on the three that do not. Still true, now for a click instead of a hover:
  whether tapping the toggle actually opens the account, and whether it ever also fires
  `select`, is an installed-app check — no headless run can press a button.
- 2026-08-19, `WS-FR-036`, fifth pass (T-186): the operator found two more mismatches, both
  fed by the same root cause. (a) A row's agent-account text stayed full-weight even when its
  workspace lost `isActive` and its own name dimmed to muted — the list read as belonging to
  whichever workspace was selected rather than the one it actually hung under. `AgentListRow`
  now takes the row's own `isActive` (threaded through `WorkspaceAgentList`) and mutes its
  title with the exact same rule the workspace name already uses. (b) An interactive agent
  (`claude`, `codex`, `opencode` run as a REPL, not `-p`) that had genuinely finished a turn
  still read `idle`, indistinguishable from a prompt that never had anything to say — because
  the only finish signal `PaneActivity` had, `commandFinishedCount`, rises from OSC 133's
  "a foreground shell command exited", and an interactive agent never exits its shell's
  foreground between turns; only the whole session quitting would trip it. `AgentHookLensBus`
  gains a third sink (`TerminalSurface.noteAgentTurnFinished()`, reached through
  `SurfacePool.noteAgentTurnFinished(for:)`): a root-session `Stop` event — `isRootTurnBoundary`,
  the same subagent guard `AgentPaneRoster.ingest` already applies to the same stream — bumps
  the pane's own finish counter exactly as a real OSC 133 finish would, so `PaneActivity`
  cannot tell the two apart and needed no change itself. New:
  `testAnAgentsHookDrivenFinishReachesTheSameStateARealCommandFinishWould`
  (`PaneAttentionTests`, proves the stuck-idle state before the fix and the reached
  `finishedUnseen` after it, through the real machine), `testARootSessionsStopIsATurnBoundary` /
  `testASubagentsStopIsNotThePanesTurnBoundary` / `testAMidTurnHookIsNotATurnBoundary`
  (`AgentPaneRosterTests`, the extracted predicate). Full suite **2383 / 0**. Not committed.
  Same session, immediate follow-up (c): the account's row title also read at the workspace
  name's own 11 pt, so it carried no size signal that it is the row's nested detail rather than
  a peer of the name above it — dropped to 10 pt (`AgentListRow`, `WorkspaceSidebarView.swift`),
  one step under the name, weight left at `.regular` against the name's bold/semibold so the two
  now differ on both axes. `swift build` clean; a full-suite re-run landed 1/2383 failing while
  a concurrent peer session's unrelated `xcodebuild -configuration Release` build held the
  machine at a 4-7 load average (confirmed via `ps aux`) and stretched the run to 3377 s against
  a normal ~155 s — the failing test's own name was lost to a `tail -15` pipe on that run. A
  targeted re-run of the three files this pass and the one before it touch —
  `PaneAttentionTests` / `AgentPaneRosterTests` / `WorkspaceIdentityFormTests` — was clean at
  **44 / 44** outside that contention. No test in this suite asserts an exact SwiftUI font size
  and this edit is one `CGFloat` literal, so the full-suite failure reads as load-induced flake
  rather than caused by it — **stated as unconfirmed, not silently assumed clean**: the full
  suite has not been re-run end to end since without a concurrent build sharing the machine.
- 2026-08-19, `WS-FR-036`, sixth pass: the operator flagged, from a live screenshot of an
  expanded row, that its context menu listed the same two agent panes already visible on the
  open inline account right below it — the menu's own comment already named the reason it
  exists ("the rail's only way", since "the rail has no room for the toggle"), but the code
  offered it unconditionally at every sidebar width, not only the one that comment justified.
  `WorkspaceRow`'s `.contextMenu` now gates the `ForEach(agentEntries)` and its `Divider` on
  `isCollapsed`; an expanded row's menu keeps only Customise/Remove. Restated in the
  requirement text and split the accessibility scenario in two — one for the rail's menu
  (only route to a row's panes at that width), one for the expanded row's (offers none, since
  the still line and its account already speak them). No headless test covers SwiftUI
  `.contextMenu` content (no `ViewInspector` in this tree), so this is source-and-PRD only,
  consistent with every other click/hover claim already marked installed-app-only in this
  requirement's log; `swift build` and the full suite were re-run clean after the edit.
- 2026-08-19, `WS-FR-036`, seventh pass: the still line stopped naming the first agent pane
  and started reading the workspace's own path earlier in this same session — a path is fixed
  regardless of what a pane is doing, so the line reads the same in a screenshot taken a minute
  apart, where a rotating pane name would not. That swap shipped without a decision-log entry;
  restated here rather than left unrecorded. The operator then flagged the leading state glyph
  it kept from the pane-name line as noise beside a path that never changes state — a glyph
  answering "what is the state of a fact this line no longer names" reads as decoration, not
  information. `WorkspaceAgentTaglineView` drops the `AgentStateIndicator` (and the
  `accessibilityReduceMotion` read it alone needed); the `+N` remaining-pane count stays, since
  that is still live information the line carries. The account list's own row keeps its glyph —
  `AgentListRow` names each pane by its own title, where a state glyph still answers a real
  question. `swift build` clean. Two full-suite runs read 2387 tests with 2 failures (1
  unexpected) then 1 failure (0 unexpected); both times the one named failure was
  `PluginBuiltinsTests.testProcessStreamDeliversOwnedOutputBackToRuntime`, a `posix_spawn`
  timing test in an unrelated file this pass never touches, and it passed clean in 0.022 s run
  alone — full-suite contention, not this change. The suites this pass actually reaches —
  `WorkspaceIdentityFormTests`, `PaneAttentionTests`, `AgentPaneRosterTests`,
  `WorkspaceAgentTaglineTests`, `DomainTagFitnessTests` — ran **60 / 60**. Not committed.
- 2026-08-17, `WS-FR-034`: `ShellIdentityLabelTests` pins the one rule at five inputs —
  collapsed with a name, with a name of only whitespace, with no workspace, and expanded —
  red first at `("Tenon", false)` against `("tenon", true)`, green after. The pixels were
  taken through the new `TENON_TITLEBAR_SNAPSHOT`, which mounts the shipping `ShellTitleBar`
  over a real store and host: collapsed reads `tenon`, expanded reads `Tenon`, and
  `interviewassistant-monorepo` truncates to `intervie…` without crowding the sidebar toggle
  or the divider.
- 2026-08-17, `WS-FR-035`: the tab strip was extracted whole out of `ShellTitleBar` into
  `ShellTabStrip`, which takes the window edge its row is attached to and consumes it in
  exactly three places: the fill behind its trailing stretch (`WindowDragArea` in the
  title-bar band, plain chrome at the foot), a launcher popover's preferred side, and the
  room that popover may grow into. Everything else is identical by construction rather than
  by two views agreeing, and `ShellChromeLayoutTests` sweeps `Sources/TenonApp` to hold that:
  one file draws `TabStripSurface(`, one file chooses between the strips.
- 2026-08-17, `WS-FR-035`: the drag-region overrides on `TabStripSurface.SurfaceView` are
  **kept unconditional**, against a measurement that says they do nothing at the foot (a
  mirror of `drag-region-probe.swift` placed a control at y=3 in a 300-pt window; the region
  was the top ~32 pt and skipped it whatever the class). Tabs-on-top is the default and stays
  shipped, so the carve-out is load-bearing for the majority configuration; a rule that only
  applied in one configuration would be a second behaviour to keep in step, and deleting it
  would re-open T-101, which took three shipped fixes.
- 2026-08-17, `WS-FR-035`: `acceptsFirstMouse` stays `true` at both edges rather than being
  scoped to the title bar. Scoping it would make the same control behave differently for
  where it is drawn, which is the one thing this requirement forbids. Residual hazard, stated:
  a click that activates a background window can land on a 24-pt ✕ and close that tab.
- 2026-08-17, `WS-NFR-012`: the foot tab row is 34 pt, which is `SidebarFooterLayout.height`,
  so the rule above it and the rule above the sidebar footer are one line across the window
  instead of a 2-pt kink. Measured consequence: `foot-strip-edge-probe.swift` reports the
  window's bottom 3.1 pt hit-testing to `NSThemeFrame`, and a centred 26-pt chip clears it by
  0.9 pt. Thin, and chosen anyway because 34 pt is the height an already-shipped row at the
  same window edge uses. If a future macOS widens the gutter the probe fails and the answer
  is 36 pt plus the kink.
- 2026-08-17, `WS-FR-035`: `LauncherMenu`'s list ceiling stopped being computed from
  `window.frame.maxY - titleBarHeight`. That number assumed every launcher hangs under the
  title bar — already false for the empty-grid anchor, which was reading it from out on the
  canvas — and a strip at the foot opens upward, where measuring downward from the window's
  top claims a whole window of room that is not on the screen. The arithmetic moved to
  `LauncherListHeight.ceiling(anchor:opening:visibleFrame:chrome:)` and every anchor now
  states its own screen rect and direction.
- 2026-08-17, `WS-FR-035`: the tab-strip drop band shrank. It used to be reported over the
  whole title-bar right zone, so a pane released over the resource monitor or the quick
  commands made a tab; it is now the strip plus its own trailing fill, and travels with the
  strip. No requirement pinned the larger band and no test covered it — every band test
  injects the rect directly — so this ships as a decision rather than a requirement edit.
- 2026-08-16, `WS-NFR-006`, `WS-NFR-010`: `WorkspaceIdentityFormTests` reads back the
  pixels the popover drew and requires a swatch row to leave the same space before its
  first mark as after its last, and less than a swatch of either. Red first at 7 pt against
  67 pt, green after. Two metrics assertions that only forbade overflow were replaced by
  the density floor they were standing in for. Suite 2279 / 0; snapshots taken through
  `TENON_IDENTITY_SNAPSHOT` on both sides of the change.
- `WorkspaceCatalogPersistenceTests` covers schema round-trip, launch precedence, bounded
  durable writes, coalescing, flush, and the fail-soft matrix.
- `WorkspaceCatalogRelaunchTests` exercises the real composition root across stop/relaunch.
- 2026-08-13, T-145: `AgentPaneSessionCaptureTests` pins which live pane may become a saved
  session — `.exact` only, a session id, a transcript the value type accepts — and the walk
  that skips shells and exited surfaces; `WorkspaceCatalogPersistenceTests` pins the record
  shape, the restored reading, and the two degraded forms. Both assertions on the new behaviour
  were red before the change; the confidence guard killed a mutation admitting `.inferred`.
  What no test reaches: a real agent running through a quit and a relaunch, which is a live-PTY
  journey the suite cannot drive.
- `RecentWorkspaceStoreTests`, `RecentStoreTests`, and `WorkspaceRecentLauncherTests` cover
  canonical paths, filtering order, isolation, adoption, clearing, and hosted launcher scope.
- `WorkspaceIdentityTests` and `WorkspaceIdentityFormTests` cover name/appearance invariants,
  migration, hosted geometry, symbols, and spoken projections.
- 2026-08-14, T-154 (`WS-FR-032`, `WS-FR-033`): the identity suites pin the expanded
  24-mark/12-accent vocabularies, one-event atomic mutation, catalog/recent persistence, and
  fail-soft corrupt custom data. The shipping form and image importer are mounted headlessly;
  the inspected 320-point offscreen render shows the complete balanced grids, upload control,
  and no clipping. `WorkspaceIntentProviderTests` pins exact UUID scope, shared normalization,
  and complete output. Final full suite: **2233 / 0**. No installed file-picker gesture or
  live socket round trip was driven.
- 2026-08-13: `PaneTitleTests` covers normalization, identity preservation, movement, and old/new
  catalog round trips. `PaneRenameTests` pins the default Haiku/JSON/no-tools Claude invocation,
  Codex JSONL agent-message parsing, rejection of non-event output, untrusted bounded prompt
  framing, pane-removal cancellation, closed-stdin safety, and process-group termination even
  when a parent and grandchild ignore `SIGTERM`;
  `SpatialCanvasInteractionTests` pins the native header-menu vocabulary and shared VoiceOver
  route. Live provider account requests and installed-app pointer feel remain manual
  verification.
- 2026-08-14, T-146 (`WS-FR-030`, restated `WS-FR-028`): the rename modal is deleted; renaming
  is reported and typed on the pane's own title. `PaneRenameTests` pins the words each phase
  puts there, per-pane ownership across a teardown, the self-clearing failure, and the inline
  commit/clear/cancel path; `SpatialCanvasInteractionTests` drives the shipping card — menu →
  editable title → reconfigure → Return — and pins that the open field is not pane-drag
  surface. `PaneRenameArchitectureFitnessTests` pins the absence of any presented rename
  surface and the stage's phase read. Full suite **2203 / 0**; **6 / 6 mutations caught**, one
  per run with `cmp`-verified restores: generating losing its title, a failure that never
  withdraws, a teardown cancelling every pane, a reconfigure overwriting a half-typed name, the
  field treated as drag surface, and the stage dropping its invalidating read. The offscreen
  render is what settled the glyph: `TENON_PANE_RENAME_SNAPSHOT=/tmp/pane-rename.png swift run
  tenon` photographs all three states at once, and the first form's `⟳` was an unreadable smudge
  at the glyph column's 9 points while `Naming…` beside it was legible — so a generating pane
  keeps its content glyph and carries the state in amber. What no test reaches: a real keyboard
  in a real window (`makeFirstResponder`, the caret, click-away commit against a live PTY).
- 2026-08-10, T-112: `WorkspaceTintTests` pins the derived colours against relaunch, folder
  spelling, palette coverage, WCAG 3:1 on the sidebar chrome, and a CIELAB floor between any
  two palette entries; `WorkspaceIdentityFormTests` carries the end-to-end path→mark colour
  and the chrome value the core suite assumes. Full suite green. The palette's shape came
  from a sidebar snapshot, not from a test: an evenly spaced twelve-hue wheel passed every
  assertion while drawing three greens that read as one colour.
- `SidebarFooterTests` and sidebar snapshots cover destinations, geometry, accessible names,
  minimum width, and removal of version from the sidebar.
- 2026-08-16, T-168: `SidebarResizeTests` **8 / 0**, red first at both new assertions
  (`46.0` against the 36–40 pt band, and against the rail's 38 pt). The picture is the
  evidence the test cannot give: in the 48 pt rail snapshot the selected row's fill measures
  **38.0 pt tall by 38.0 pt wide** — read off the PNG, not judged by eye — and the 232 pt and
  110 pt shots show the mark, name, and tab count uncut at the shorter height. Full suite
  **2291 tests, 8 failures**, all eight in another session's in-flight Agent Lens work
  (`AgentCLIRetryTests`, `AgentReadingOptionsTests`, `AgentSessionTimelineTests` over their
  modified `AgentSessionTimeline.swift` / `AgentTimelineSynthesis.swift`); both sidebar
  suites passed inside that same run.
- `MainWindowSingletonTests`, interaction/direct-inventory fitness tests, and native window
  XCUITests guard the scene/boundary/titlebar contracts.
- 2026-08-12, T-138: `WorkspaceFolderDropTests` **9 / 0**, red first at 7 of 9 against a
  stub that returned no actions. The decision is proved by mutation, one at a time, each
  restored byte-identically: dropping the directory guard turns **3** red, dropping the
  same-drop dedupe **1**, and matching an open workspace on raw `URL` equality instead of
  `RecentWorkspaceStore.folderKey` **1** — the last one is the case a fixture had to be
  forced into, because `URL(fileURLWithPath:)` asks the filesystem and hands back the same
  trailing-slash URL the drop carries. The folders are real directories in a temp tree, so
  the one filesystem question the rule asks is answered by the filesystem.
- 2026-08-13: `WorkspaceFolderDropAdapterTests` mounts the shipping sidebar zone and drives
  AppKit's `NSDraggingDestination` lifecycle with pasteboard items carrying only
  `public.file-url`; folder entry/exit, file refusal, mixed ordering, and the mutation into
  `WorkspaceStore` are covered at the native boundary.
- 2026-08-13: `WorkspaceCloseConfirmationTests` covers the shared tab/workspace gate's
  branches, including stale inspection and changed pane/process identities; drives the typed
  sidebar removal action behaviorally through that coordinator; and mounts the shipping alert modifier in an
  `NSWindow`, observes the native `Remove Workspace?` sheet and buttons, and presses Cancel.
- Historical aggregate test counts in task files are receipts for their moment, not a claim
  that the present full suite was rerun for this documentation change.

## 14. Change history

| Date | Change | Author |
|---|---|---|
| 2026-08-09 | Created canonical shipped-state PRD from current source, eight task records, manifests, and focused tests. | Codex |
| 2026-08-12 | Added `WS-FR-025`: a folder dropped on the sidebar opens a workspace at it, an already-open folder is selected instead, and a dropped file is refused. | Claude (T-138) |
| 2026-08-13 | Added `WS-FR-027`: a pane running an agent is captured with its session and comes back reading it, degrading to its terminal when the transcript is gone. | Claude (T-145) |
| 2026-08-13 | Corrected `WS-FR-025`'s native transport from `public.folder` to Finder's `public.file-url` plus semantic folder filtering; added mounted AppKit evidence. Added `WS-FR-026` for the shared process-safe tab/workspace close gate and native workspace confirmation. | Codex |
| 2026-08-13 | Added `WS-FR-028…029`: persistent manual pane names and cancellable Companion JSON naming owned by pane lifetime; Claude + Haiku is the compatible default and Codex JSONL is also supported. | Codex |
| 2026-08-14 | Added `WS-FR-031`: workspace rows reorder directly in the sidebar with matching VoiceOver actions, persistence, and `workspace.moved` facts. | Codex |
| 2026-08-17 | Added `WS-FR-036`: a sidebar row names the agent panes its workspace holds, one at a time with their attention states, in place of its tab count. | Claude (T-178) |
| 2026-08-17 | Restated `WS-FR-036` on operator report: the line holds still and names the first agent pane with a count of the rest, and a hover opens the full list of panes with a click that focuses one. The rotation and the scrolling title are withdrawn — the 2026-08-17 row above about elapsed-reference-time phasing is superseded by the row about the still line. | Claude (T-179) |
| 2026-08-19 | Restated `WS-FR-036` on operator report: hover-driven open/close is withdrawn — closing a row on hover-out reflowed the rows below it under a pointer already travelling toward one of them, missing the click. A per-row disclosure toggle, a click target of its own beside `select` rather than nested in it, opens or closes the account instead; it is pinned exactly as the operator left it, independent of which workspace is selected, until clicked again. The rail's popover is withdrawn with the hover that drove it — its context menu is now the rail's one route to a row's panes. Supersedes the second and third passes' hover framing above. | Claude (T-185) |
