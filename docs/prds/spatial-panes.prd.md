# PRD — Spatial panes, chrome, focus, attention, and resource lifetime

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-003` |
| Lifecycle | `partial` |
| Owner | Tenon spatial-canvas, pane-chrome, attention, workspace-model, and terminal-surface domains |
| Reviewers | product, native UI, accessibility, performance, plugin runtime, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-13 |
| Related work | T-025, T-026, T-029, T-031, T-059, T-064, T-065, T-076, T-079, T-087, T-088, T-091 |
| Existing designs | [`design-pane-slots.md`](../design-pane-slots.md), [`design-pane-header.md`](../design-pane-header.md), [`design-pane-hosting.md`](../design-pane-hosting.md) |
| Acceptance specification | [`spatial-panes.feature`](spatial-panes.feature) |

## 1. Executive summary

### Problem

Tenon puts several terminals, files, agent views, and plugin surfaces on one tab. A pane is
therefore more than a rectangle: it has stable identity, live resources, focus, chrome,
attention state, accessibility meaning, and placement across tabs. When any one of those
concerns owns geometry independently, invalid overlap can appear, content can restart during
a drag, controls can steal the header's grab surface, or focus can oscillate forever.

The historical record also contains two dangerous documentation traps. T-059 describes one
invalid-drag settlement policy, while current source distinguishes move and resize behavior.
T-091 records a measured 100% CPU/11 GB non-converging SwiftUI update loop, but the exact
trigger has never been reproduced. Current mitigations and bounds are real; claiming the root
cause fixed would not be.

The trap under that trap, measured 2026-08-12 (T-141): **"the app hangs" is a symptom shared by
several unrelated defects**, so a fix verified against one stall says nothing about the next.
One 18-minute run opened eight incidents whose main threads were in four different places — a
5 Hz attention poll rendering every pane's screen to text (83%, now fixed), a SwiftUI layout
loop in Agent Lens, `AttributedString`/`memmove` churn, and one thread simply idle in
`mach_msg2_trap`. Read every incident in a run before naming a cause, and take the main-thread
block by the name in its header rather than by position.

### Proposed outcome

Every tab presents a deterministic 12×12 spatial canvas. Pure core transactions decide valid
creation, split, close, move, swap, and resize; AppKit owns high-frequency pointer capture and
renders only valid proposals. Pane UUID ties geometry/content to its live resources, so
moving or hiding a pane does not recreate it. One host-owned header presents identity,
attention, actions, Copy Pane ID, and bounded built-in/plugin contributions while retaining a
guaranteed drag band. Focus and attention are single state machines with explicit
model↔AppKit rules.

### Why now

Pane behavior spans twelve task records, three design documents, several split coordinators,
and hundreds of focused tests. User reports have already shown that context loss in one area
causes regressions elsewhere. A canonical PRD must state the complete shipped contract and
the still-open update-loop investigation before more pane or shell work continues.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| current geometry source | [`SpatialLayout.swift`](../../Sources/TenonCore/SpatialLayout.swift), [`Workspace.swift`](../../Sources/TenonCore/Workspace.swift) | high | grid invariants, immutable transactions, creation/duplicate/close/move/resize rules |
| current AppKit canvas | [`SpatialInteraction.swift`](../../Sources/TenonApp/Canvas/SpatialInteraction.swift), [`SpatialCanvasNSView.swift`](../../Sources/TenonApp/Canvas/SpatialCanvasNSView.swift), [`SpatialSlotCardView.swift`](../../Sources/TenonApp/Canvas/SpatialSlotCardView.swift) | high | hit testing, preview/commit, menus, drag ghost, Copy Pane ID, accessibility |
| pane chrome contract | [`PaneHeader.swift`](../../Sources/TenonCore/PaneHeader.swift), [`PaneHeaderItem.swift`](../../Sources/TenonCore/PaneHeaderItem.swift), [`design-pane-header.md`](../design-pane-header.md) | high | one header, bounded two-slot value schema, drag/accessory layout, action routing |
| focus and lifecycle | [`PaneFocusRouting.swift`](../../Sources/TenonApp/PaneFocusRouting.swift), [`SurfacePool.swift`](../../Sources/TenonApp/SurfacePool.swift), [`PaneContentHost.swift`](../../Sources/TenonApp/Canvas/PaneContentHost.swift) | high | bounded focus settlement, lazy surface materialization, one-way size ownership |
| attention implementation | [`PaneActivity.swift`](../../Sources/TenonCore/PaneActivity.swift), [`PaneAttentionProjection.swift`](../../Sources/TenonApp/PaneAttentionProjection.swift), [`PaneAttentionNotifier.swift`](../../Sources/TenonApp/PaneAttentionNotifier.swift) | high | deterministic attention, viewed rule, shared projections, background notification |
| pane-owner public adapter | [`CoreIntentCatalog.swift`](../../Sources/TenonCore/CoreIntentCatalog.swift), [`WorkspaceIntentProvider.swift`](../../Sources/TenonApp/WorkspaceIntentProvider.swift) | high | finite read-only owner query for plugin/CLI/agent over the same catalog |
| focused tests | suites listed in section 10 | high | pure, hosted AppKit/SwiftUI, integration, accessibility, and real pointer seams |
| T-091 process sample and runbook | [T-091](../../.kanban/tasks/T-091-a-pane-never-spins-the-update-loop.md), 2026-08-07/08 | high for observed incident; low for unproven cause | measured lazy-layout self-feed, candidate path removal, automatic sampling, but no reproduction/root-cause proof |
| remaining task archive | T-025, T-026, T-029, T-031, T-059, T-064, T-065, T-076, T-079, T-087, T-088 | medium | original decisions/evidence; current source supersedes drifted implementation narratives |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| What core problem are we solving? | Arrange many live work surfaces without invalid geometry, resource churn, focus loops, or inaccessible chrome. | product behavior and incidents |
| Who experiences it? | Operators supervising several concurrent panes, plus plugin authors and public intent callers that address panes. | shipped scope |
| How will we know it worked? | The displayed preview can commit, stable IDs retain resources, focus settles, attention clears only by viewing, and all input modes reach equivalent actions. | Gherkin and focused evidence |
| Which constraints cannot move? | pure spatial core, one host header, typed DIRECT native mutations, classified public intents, stable UUID/resource join, native design system | normative docs/current source |
| What remains unknown? | The production trigger and proven root cause of T-091's non-converging update loop. Also unnamed: the `AttributedString`/`memmove` stalls in incidents `0002`/`0008`, and why 3 of 8 incidents recorded no `sample.txt` at all. | open T-091 criteria; T-141 incident sweep |

### Assumptions to validate

| ID | Assumption | Validation method | State |
|---|---|---|---|
| `SP-A-001` | A 12×12 grid with 3×3 minimum balances deterministic layout and useful pane size. | installed-app observation before grid changes | shipped product decision |
| `SP-A-002` | Four points of travel distinguish pane pickup from header click. | mouse/trackpad observation plus AppKit tests | shipped; human feel remains observational |
| `SP-A-003` | The candidate lazy-layout path removed from Agent Lens was sufficient to reduce incident likelihood. | reproduce T-091 runbook and inspect automatic sample | unvalidated; must not be called a fix |

## 3. Users and jobs

### Primary user

An operator watching multiple terminals, agents, files, diffs, and plugin panels at once.
They need to reshape the workspace quickly while preserving live processes and knowing which
pane needs attention. They may alternate among pointer, keyboard, VoiceOver, and CLI/agent
addressing.

### Secondary users and affected actors

- Plugin authors contributing pane bodies and bounded header items.
- CLI/agent clients resolving pane ownership or invoking public pane intents.
- Accessibility users who need spoken position, state, and non-drag alternatives.
- Performance/support engineers diagnosing renderer, update-loop, and process lifetime.

### Jobs to be done

- When my supervision layout changes, I want to move or resize panes without restarting
  their work or ever seeing an impossible overlap.
- When I need another view of the same content, I want Duplicate to create a new pane near
  the one I chose rather than affecting some focused pane elsewhere.
- When another tool needs a pane address, I want Copy Pane ID directly in pane chrome.
- When work finishes out of sight, I want one consistent signal that remains until I truly
  view the pane.
- When a plugin adds pane controls, I want them to share the native header without removing
  the pane's grab surface or close behavior.

### Product vocabulary

| Term | Meaning in this PRD | Not to be confused with |
|---|---|---|
| Pane / slot | one UUID-addressed rectangular content owner in a tab | its AppKit/SwiftUI view instance or terminal process |
| Canvas | 12×12 logical layout projected into current pixels | an arbitrary freeform floating coordinate plane |
| Transaction | immutable baseline, proposal, affected IDs, kind, and validity | the ephemeral pointer preview |
| Header | the single 34-point host chrome strip for pane identity/state/actions | a toolbar drawn inside pane content |
| Viewed | app frontmost + selected workspace + pane displayed in active tab | merely selected workspace, existing surface, or window focus alone |
| Materialized | a live native resource exists for a pane after first display | restored placeholder or catalog presence |

## 4. Goals and success measures

### Goals

- `SP-G-001` — Every pane gesture shows only a valid, committable or authoritative baseline
  layout.
- `SP-G-002` — Stable pane identity preserves content/resource lifetime across geometry and
  navigation changes.
- `SP-G-003` — Pane chrome exposes actions, controls, status, and accessibility without
  sacrificing drag/resize affordances.
- `SP-G-004` — Focus and attention converge on one truthful owner.
- `SP-G-005` — Pane update work remains bounded and any future stall records actionable
  evidence automatically.

### Success metrics

| ID | Metric | Baseline | Target | Measurement method | Review window |
|---|---|---|---|---|---|
| `SP-M-001` | invalid geometry rendered during drag/resize | user-observed overlap/red preview | zero | coordinator + hosted canvas tests | every change |
| `SP-M-002` | resource recreation from move/tab switch/focus | historical risk | zero | surface/web/editor lifecycle tests | every change |
| `SP-M-003` | focus transitions after pane creation without user input | unbounded oscillation | bounded and settled on new pane | production-wiring focus tests | every change |
| `SP-M-004` | cross-surface attention disagreement | independent UI logic risk | zero; all projections read one machine | attention projection tests | every change |
| `SP-M-005` | idle pane body evaluations after settlement | prior non-converging incident | count stops increasing in bound harness | update-turn test | every change |

### Guardrail metrics

| ID | Regression to prevent | Limit | Measurement method |
|---|---|---|---|
| `SP-GM-001` | pane becomes too small to use | at least 3×3 logical cells | exhaustive geometry tests |
| `SP-GM-002` | contributed header removes grab surface | minimum 64-point drag band while foldable items remain; fixed accessory/close reservations | header layout sweep |
| `SP-GM-003` | unseen panes allocate terminal resources | zero surface/PTY/renderer before first display | lifecycle and relaunch tests |
| `SP-GM-004` | attention poll churns observable UI | no publication when machine output is unchanged | attention tests |
| `SP-GM-005` | unknown pane owner query leaks content | response limited to workspace UUID/path and tab UUID | intent schema/provider tests |

## 5. Scope

### In scope

- Pane creation, exact empty-canvas placement, split, duplicate, close, focus, move, swap,
  cross-tab move, resize, fill-width, named fractions, and cycle sizing.
- Pointer preview/commit/cancel/stale arbitration and drag presentation.
- Default maximum width for future pane creation and automatic horizontal close absorption.
- Flat pane menu including Copy Pane ID and its accessibility action.
- One host-owned header with bounded native/plugin items, folding, routing, and drag bands.
- Per-pane attention state, rollups, non-color vocabulary, and background notification.
- Lazy surface materialization, retention, teardown, placeholder rendering, and host sizing.
- Read-only public pane-owner intent.
- Current update-loop mitigation, convergence bound, diagnostics handoff, and explicit open
  status of the root-cause investigation.

### Non-goals

- Tab launcher/reorder, workspace persistence policy, or terminal process-tree teardown;
  PRD-002, PRD-001, and PRD-009 own them.
- A public duplicate, move, swap, resize, fill-width, Copy Pane ID, or attention mutation
  intent without a separately justified cross-owner use case.
- Plugin access to `NSView`, `WorkspaceSlot`, terminal surfaces, or geometry transactions.
- Arbitrary nested plugin UI inside pane chrome.
- Claiming T-091 resolved until the real incident is reproduced and a falsifiable root cause
  is demonstrated.

### Later possibilities

- Public move/resize intents only with a concrete bounded use case and inventory update.
- Measured occlusion/GPU savings for already-materialized hidden panes.
- A reproducible T-091 fixture using the real Agent Lens/live-content trigger.

## 6. User experience

### Entry points

- Right-click or Option-Return on empty canvas opens the shared launcher for that exact free
  region; VoiceOver exposes one Fill Empty Region action per distinct region.
- Pane header single-click/drag moves; double-click fills width; secondary click opens the
  flat pane menu.
- Pane border drag resizes; secondary click offers 1/3, 1/2, Full; double-click cycles those
  destinations.
- Interactive header controls act within their pane; close remains a dedicated host control.
- Public callers may resolve a pane's owner through `workspace.pane.owner.v1`.

### Pane creation flow

1. The creation path asks the spatial core for the largest valid empty rectangle near the
   anchor, or splits the named pane when no free region exists.
2. The current creation maximum may narrow only the new pane and keeps the clicked cell
   inside it; declined width remains empty.
3. A new UUID and content value are committed atomically and become active.
4. Model focus schedules a responder move after rendering; stale/host-generated responder
   callbacks cannot reclaim focus.

### Move and resize flow

1. A header press travels four points before becoming a pane pickup. The live card remains
   mounted; one snapshot of the whole pane becomes the floating drag thumbnail.
2. Empty-grid movement snaps to logical cells. Hovering a pane divides it into four
   directional drop regions. A routed tab target may move the pane across tabs.
3. A valid preview is derived from the original snapshot. Stale baselines cancel instead of
   overwriting newer catalog state.
4. Mouse-up commits exactly the valid displayed proposal; Escape/detach/cancel restores the
   authoritative baseline and responder.
5. Current-source settlement is asymmetric: an invalid move target clears its preview and
   rolls back if released there; an invalid resize candidate retains the last valid resize.

### Pane menu and Copy ID flow

The header menu is flat and ordered `Split`, `Stack`, `Duplicate`, separator, `Copy Pane ID`,
separator, `Close`. Split/Stack/Duplicate disable when geometry cannot honor them. Every
action targets the clicked pane, not whichever pane is active. Copy writes only the raw UUID
through the same route used by the pane's VoiceOver custom action. The former Change Type
submenu does not exist; content change remains a typed launcher/public-intent operation.

### Header contribution flow

The host always draws glyph, attention, title, close, layout, hit testing, cursor, folding,
and overflow. A built-in pane writes a typed `PaneHeader` DIRECT into the host store. A plugin
publishes the same bounded value as part of its existing view CONTRIBUTION. A header control
focuses its pane, then built-in actions use typed commands and plugin actions return as the
existing select/submit EVENT for that exact plugin/view/instance. Close intentionally does
not focus first.

### Attention flow

Live terminal observations feed one pure state machine at a fixed cadence. A finish or exit
while unviewed sets the persistent unseen bit; quietness alone never requests attention.
Pane header, active-pane tab dot, tab bolding, workspace count, and global count all project
the same machine. Only a real viewed transition clears unseen. A background burst produces
at most one system notification whose activation focuses its first pane.

### Resource and hosting flow

An unviewed pane owns catalog value and may show restored title/cwd placeholders, but has no
terminal surface, PTY, or renderer buffers. First display materializes one resource and
flushes queued input. That resource survives focus, tab/workspace switches, view rebuilds,
and geometry changes, then terminates exactly when the slot leaves the catalog or content
ownership requires replacement. The canvas assigns content frame; pane content publishes no
intrinsic/min/max sizing options back upward.

### Accessibility and input parity

- Each pane speaks a one-based grid position/extent while its exact UUID/rect remains only in
  the non-spoken accessibility identifier.
- Attention has spoken words and state-specific symbols under Differentiate Without Color.
- Empty regions and Copy Pane ID have accessibility custom actions.
- Header interactive rects receive their click/menu/cursor; static items remain drag surface;
  close and resize edges always win their reserved regions.
- Pointer-only resize/move operations retain keyboard or named-menu alternatives where the
  product currently promises them; freeform drag itself is not exposed as a public intent.

## 7. Requirements

### Functional requirements

| ID | Requirement | Priority | Delivery | Gherkin tag |
|---|---|---|---|---|
| `SP-FR-001` | Every tab layout **MUST** use a 12×12 logical grid; panes **MUST** stay in bounds, remain at least 3×3, have unique IDs, and never overlap. | must | shipped | `@req-sp-fr-001` |
| `SP-FR-002` | Pane UUID **MUST** be the stable join among geometry, typed content, live native resources, plugin instance, titles, focus, and attention; geometry/navigation changes **MUST NOT** mint a replacement or restart the resource. | must | shipped | `@req-sp-fr-002` |
| `SP-FR-003` | Pane creation **MUST** use the best valid empty region near the named/clicked anchor when available, otherwise split the named pane on a valid axis; an exact empty-canvas launch **MUST** reserve the clicked region rather than another gap. | must | shipped | `@req-sp-fr-003` |
| `SP-FR-004` | The optional default maximum width **MUST** use the existing 1/3, 1/2, Full vocabulary, constrain every future creation path and automatic horizontal growth after close, never shrink a surviving pane, never exceed available space, keep a clicked cell inside a new pane, and leave manual resize unrestricted. | must | shipped | `@req-sp-fr-004` |
| `SP-FR-005` | Split/Stack **MUST** target the named pane, create a new stable pane to its right/below when valid, preserve the original content/resource, and focus the new pane. | must | shipped | `@req-sp-fr-005` |
| `SP-FR-006` | Closing a pane **MUST** deterministically absorb its geometry into a valid neighbor when possible, except that horizontal absorption stops at the SP-FR-004 maximum and leaves declined width empty; it **MUST** preserve unrelated panes and choose a valid active pane. When the final pane leaves a tab, that empty tab **MUST** close if another tab survives; a workspace's required final tab remains as an empty placeholder. | must | shipped | `@req-sp-fr-006` |
| `SP-FR-007` | Duplicate **MUST** create a new pane with the clicked pane's content value and a new UUID, prefer free space near that pane, otherwise split it on a valid axis, focus the copy, and be disabled when no valid placement exists. | must | shipped | `@req-sp-fr-007` |
| `SP-FR-008` | The pane header menu **MUST** be flat and ordered Split, Stack, Duplicate, Copy Pane ID, Close with separators; it **MUST NOT** include Change Type, and every action **MUST** target the clicked pane without first focusing for Close. | must | shipped | `@req-sp-fr-008` |
| `SP-FR-009` | Copy Pane ID **MUST** remain directly reachable from the header menu and accessibility action, use one shared route, and copy only the raw pane UUID. | must | shipped | `@req-sp-fr-009` |
| `SP-FR-010` | Double-clicking bare pane header **MUST** grow that pane horizontally to the nearest blocking panes or canvas edges without moving/shrinking neighbors; an already full band **MUST** be a no-op. | must | shipped | `@req-sp-fr-010` |
| `SP-FR-011` | A border secondary click **MUST** offer 1/3, 1/2, and Full of the canvas on the border's axis, keep the opposite edge fixed, reuse coupled resize rules, and disable impossible/no-op destinations. | must | shipped | `@req-sp-fr-011` |
| `SP-FR-012` | A border double-click **MUST** cycle Full → 1/2 → 1/3 → Full on that border's axis, skip refused sizes, and leave a pane unchanged when none is valid. | must | shipped | `@req-sp-fr-012` |
| `SP-FR-013` | Header move **MUST** remain a click before four points of travel, keep the live card mounted, and carry a one-time snapshot of the complete pane including chrome after pickup. | must | shipped | `@req-sp-fr-013` |
| `SP-FR-014` | A pane drag **MUST** support snapped valid empty-grid movement, four-edge placement beside another pane, and routed cross-tab placement while preserving pane identity/content/resource; cancel or canvas detachment **MUST** restore baseline and presentation. | must | shipped | `@req-sp-fr-014` |
| `SP-FR-015` | An invalid pane move target **MUST** clear its move preview/target and roll back if released there; an invalid resize candidate **MUST** keep the last valid resize preview; invalid geometry **MUST NEVER** be rendered or committed. | must | shipped; supersedes T-059's uniform settlement wording | `@req-sp-fr-015` |
| `SP-FR-016` | A spatial commit **MUST** match operation kind, valid proposal, exact active baseline, and actual affected-ID set; stale/mismatched/no-op transactions **MUST** leave catalog state unchanged. | must | shipped | `@req-sp-fr-016` |
| `SP-FR-017` | Focus routing **MUST** suppress responder callbacks caused by host-driven focus, drop queued commands whose pane is no longer active, ignore overlay restoration, accept genuine pointer focus, and settle newly created pane focus in bounded transitions. | must | shipped | `@req-sp-fr-017` |
| `SP-FR-018` | Every pane **MUST** draw exactly one 34-point host-owned header with glyph, attention, title, close, and at most one leading/trailing contribution pair; pane content **MUST NOT** draw a second chrome bar. | must | shipped | `@req-sp-fr-018` |
| `SP-FR-019` | Header admission/layout **MUST** enforce item/text/identity bounds, unique IDs across both slots, one flexible item, reserved host identity, close/resize/accessory exclusion, deterministic folding, reachable overflow, and a usable drag band. | must | shipped | `@req-sp-fr-019` |
| `SP-FR-020` | Built-in headers **MUST** use typed DIRECT values/actions; plugin headers **MUST** use the existing bounded view CONTRIBUTION and return actions through existing select/submit EVENT routes scoped to their live plugin/view/instance; header changes **MUST NOT** rebuild pane content. | must | shipped | `@req-sp-fr-020` |
| `SP-FR-021` | Pane attention **MUST** distinguish working, idle, finished-unseen, seen, and exited; quietness alone **MUST NOT** create unseen, a real finish/exit while unviewed **MUST**, and later output **MUST NOT** acknowledge it. | must | shipped | `@req-sp-fr-021` |
| `SP-FR-022` | A pane is viewed only while the app is frontmost, its workspace is selected, and it is displayed in the active tab; pane/tab/workspace/titlebar projections **MUST** read the same machine, and a background unseen burst **MUST** produce at most one notification. | must | shipped | `@req-sp-fr-022` |
| `SP-FR-023` | A never-viewed pane **MUST** own no terminal surface, PTY, or renderer; first display **MUST** materialize once and flush queued input; the resource **MUST** survive hiding/moving/focus and terminate exactly when its slot leaves the catalog. | must | shipped | `@req-sp-fr-023` |
| `SP-FR-024` | Pane content **MUST** accept the canvas-assigned frame and publish no sizing options upward; an unchanged hosted lazy pane **MUST** converge to a bounded update count. This requirement covers a pane's own hosting view; the stage above it is `SP-FR-027`. | must | shipped | `@req-sp-fr-024` |
| `SP-FR-025` | `workspace.pane.owner.v1` **MUST** accept one pane UUID, search the whole catalog including unselected/paged workspaces, and return only owning workspace UUID/path and tab UUID to plugin, CLI, or agent callers; malformed/unknown panes **MUST** fail deterministically. | must | shipped | `@req-sp-fr-025` |
| `SP-FR-026` | Each pane **MUST** speak useful one-based grid position/extent, focused state, and attention words; exact UUID/geometry **MUST** remain available non-verbally to tests/tools; non-color shapes and accessible empty-region/Copy ID actions **MUST** exist. | must | shipped | `@req-sp-fr-026` |
| `SP-FR-027` | The canvas **MUST** answer the size it is proposed, so measuring the stage never reaches AppKit's fitting-size path and never sweeps Auto Layout across the card tree. A canvas that answers nothing sends that question to AppKit, whose sweep dirties the text fields it walks and re-arms the measurement that caused it. | must | shipped | `@req-sp-fr-027` |
| `SP-FR-028` | A pane's pinned title **MUST** be settable across the public principal boundary by `workspace.pane.title.set.v1`, scoped to the pane it names and refused when scope names none, so an agent working in a pane can label its own tab. It **MUST** reach the same `renameSlot` the rename UI and the Companion title generator call DIRECT, bound by the same `PaneTitle` rule, and an empty or whitespace-only title **MUST** clear the pin rather than fail. | must | shipped | `@req-sp-fr-028` |
| `SP-FR-028` | `workspace.tab.close.v1` **MUST** close the tab named by invocation scope, with every pane under it, as a `.destructive` contract confirmed under `.policy`. It **MUST NOT** infer a tab from the selection, and it **MUST** refuse a workspace's only tab with `dev.tenon.core.close-refused` rather than report a success that removed nothing. | must | shipped | `@req-sp-fr-028` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `SP-NFR-001` | determinism | Spatial geometry and interaction decisions **MUST** be pure/deterministic for the same value inputs and perform no I/O on the high-frequency drag path. | shipped | exhaustive core/coordinator tests |
| `SP-NFR-002` | atomicity | Preview is ephemeral; only a validated whole transaction **MAY** mutate the catalog. Failure/cancel/stale input **MUST** leave no partial geometry or event. | shipped | workspace transaction and hosted stale-gesture tests |
| `SP-NFR-003` | performance | Attention polling at 200 ms **MUST NOT** republish unchanged machines; content hosts **MUST NOT** request intrinsic sizing; header/focus refresh **MUST NOT** rebuild unchanged pane roots. | shipped | attention, hosting, canvas cache tests |
| `SP-NFR-004` | resource lifetime | Live resources **MUST** be keyed by pane UUID, retained across non-destructive transitions, and released exactly once after ownership ends. | shipped | surface/web/plugin lifecycle suites |
| `SP-NFR-005` | accessibility | Pointer-only discovery **MUST** have menu/accessibility alternatives where specified; state and selection **MUST NOT** depend only on color; useful labels **MUST NOT** speak raw UUID/grid tuples. | shipped | accessibility projection/hosted tests |
| `SP-NFR-006` | design | Pane chrome, gutter, focus, borders, typography, density, icons, colors, and geometry **MUST** follow [`designs.md`](../designs.md), `TenonTheme`, and the pane-header contract; no feature-local token is permitted. | shipped | design fitness/snapshots |
| `SP-NFR-007` | boundary | Native pane gestures/menus **MUST** call typed services DIRECT; committed facts use EVENT; plugin chrome uses CONTRIBUTION; live views use RESOURCE/DIRECT; only classified finite public operations use INTENT. | shipped | interaction and direct-inventory fitness |
| `SP-NFR-008` | security | Plugins **MUST NOT** receive host view objects, geometry transactions, terminal resources, or another instance's header actions; pane-owner read **MUST** expose only its bounded structural response. | shipped | runtime/provider/header route tests |
| `SP-NFR-009` | input ownership | Resize edges, close, interactive header items, bare drag band, body surface, and empty canvas **MUST** have disjoint deterministic hit/menu/cursor ownership. | shipped | point-sweep AppKit tests |
| `SP-NFR-010` | maintainability | Spatial math, interaction decisions, AppKit canvas mounting, card hit-testing, representable bridging, header solving, focus routing, and attention projection **MUST** remain separate responsibility owners with current domain tags. | shipped | source/domain fitness; T-095 owned by PRD-015 for cross-cutting audit |
| `SP-NFR-011` | incident evidence | A sustained main-runloop stall **MUST** record a bounded automatic process sample outside the main thread, once per stall occurrence, without collecting pane contents beyond diagnostic stack/process metadata. | shipped, and the recorded sample is what identified the T-121 root cause | diagnostics tests and T-091/T-121 runbook |
| `SP-NFR-012` | verification honesty | Tests and docs **MUST** distinguish measured production evidence, deterministic bounds, candidate mitigation, and human-only behavior; no green harness may be represented as a reproduced fix for T-091. | shipped documentation constraint | review gate |
| `SP-NFR-013` | main-thread cost | The attention poll runs on the main thread at a fixed cadence over every open pane, so it **MUST** obtain each pane's screen as a fingerprint and **MUST NOT** render it to text; a caller that needs the characters asks for them by name. | shipped | `@req-sp-nfr-013` |

## 8. Acceptance specification

| Requirement group | Feature rules | Evidence seam |
|---|---|---|
| SP-FR-001…007, SP-NFR-001…002 | valid creation/split/duplicate/close | pure spatial/workspace suites |
| SP-FR-008…016, SP-NFR-006, 009 | menu, Copy ID, drag/resize | coordinator, hosted AppKit, and XCUITest |
| SP-FR-017, SP-NFR-003…004 | focus/resource settlement | production-wiring focus and pool lifecycle tests |
| SP-FR-018…020, SP-NFR-006…010 | one header and routing | schema/layout/store/projection/plugin-route and hosted canvas tests |
| SP-FR-021…023, SP-NFR-003…005, 011, 013 | attention and lazy lifetime | pure state, projection/notifier, lifecycle, relaunch tests, and a poll that counts how often it asked a screen for its characters |
| SP-FR-024, SP-NFR-003, 011…012 | update convergence and incident status | pane hosting/update-bound tests plus T-091 diagnostics/runbook |
| SP-FR-027 | the canvas answers its own size | pane hosting tests measuring whether the question reaches Auto Layout |
| SP-FR-028 | an agent labels its own pane | provider tests over a real `WorkspaceStore`, asserting the catalog's `customTitle` rather than a view |
| SP-FR-025…026, SP-NFR-005, 007…008 | owner intent/accessibility | intent catalog/provider and accessibility tests |
| SP-FR-028 | tab close is destructive, scoped, and refuses the last tab | intent catalog/provider tests over `WorkspaceStore.closeTab` |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Classification | Reason |
|---|---|---|
| native pane gesture/menu/header action → typed workspace/app service | DIRECT | same semantic owner inside host |
| `SpatialLayout` and coordinator calculations | DIRECT | pure same-owner value functions |
| committed workspace/focus/action facts | EVENT | facts already happened |
| plugin pane body/header declaration | CONTRIBUTION | plugin declares bounded host-rendered state |
| terminal/web/editor/plugin instance lifetime | RESOURCE plus DIRECT pool/store | caller-owned lifetime outlives initial construction |
| plugin/CLI/agent pane-owner or workspace command | INTENT | finite request/reply across independent owner boundary |

Core public audiences are exactly plugin, CLI, and agent for `workspace.pane.owner.v1` and
the other programmatic workspace intents. Copy Pane ID, Duplicate, fill-width, named resize,
and attention acknowledgement remain local host interactions and add no public contract.

### Native design-system constraints

- Logical grid is invisible structure; rendering uses the established gutter, panel, chrome,
  line, focus, and semantic attention values.
- Header height is 34 points everywhere. A second content toolbar may exist only when it
  belongs to content inside the pane, not as duplicate pane chrome.
- Multi-pane focus chrome appears when ownership is ambiguous; a single full-bleed pane stays
  visually calm.
- Attention uses both words and shapes; color is reinforcement.

### Domain and ownership map

| Concern | Primary source | Domain |
|---|---|---|
| layout values/transactions | `SpatialLayout.swift`, workspace mutations | `workspace-model` / spatial core |
| pointer decisions | `Canvas/SpatialInteraction.swift` | `spatial-canvas` |
| AppKit canvas/cards/overlays | `Canvas/SpatialCanvasNSView.swift`, `SpatialSlotCardView.swift`, `SpatialCanvasOverlays.swift` | `spatial-canvas` |
| SwiftUI bridge/content host | `SpatialCanvasRepresentable.swift`, `PaneContentHost.swift` | `spatial-canvas` |
| header schema/layout/routing | `PaneHeader*.swift`, `PaneHeaderLayout.swift`, `PaneHeaderStore.swift` | `pane-chrome` |
| focus | `PaneFocusRouting.swift`, `SurfacePool.swift` | `terminal-surface`, `workspace-model` |
| attention | `PaneActivity.swift`, `PaneAttentionProjection.swift`, `PaneAttentionNotifier.swift` | `attention` |
| public adapter | `WorkspaceIntentProvider.swift`, core intent catalog | intent provider/catalog domains |

Follow the two-step domain retrieval rule in [`domains.md`](../domains.md): domain search
starts the set; symbol search recovers the cross-file edges.

### Data, resource, and lifecycle model

```text
WorkspaceSlot UUID
├── GridRect + SlotContent in WorkspaceCatalog       value truth
├── SpatialLayout transaction                         pure proposal/validation
├── SpatialCanvas interaction preview                 ephemeral AppKit state
├── pane header + attention + focus projections       keyed host state
└── terminal/web/editor/plugin instance               live resource, lazy and retained
```

The resource is never stored inside `SlotContent`. A pane move changes geometry under the
same UUID. A duplicate copies the content value under a new UUID and therefore receives a new
resource. Closing/removing the slot ends ownership and pool reconciliation releases the
resource exactly once.

### Security and privacy

- Pane Copy ID exposes the raw UUID only to the local pasteboard at explicit user action.
- Pane-owner intent exposes structural ownership/path, not content or live objects.
- Plugin header actions are routed only to the current installation, plugin, view, instance,
  and item that declared them; retired generations receive nothing.
- System notification bodies use pane title/count and local slot ID activation metadata;
  terminal text is not copied into them.

### Compatibility

- Public pane-owner intent is versioned `v1`; schema changes require the normative inventory
  and architecture change protocol.
- Unknown/invalid header items fail soft at value admission; supported siblings remain.
- The automatic pane-width maximum is optional and unknown persisted values degrade to
  unlimited.

## 10. Delivery plan

### Requirement delivery matrix

| Requirements | Delivery | Current implementation | Evidence | Known gap |
|---|---|---|---|---|
| SP-FR-001…007, SP-NFR-001…002 | shipped | `SpatialLayout`, `NewPaneSizing`, workspace mutations | `SpatialLayoutTests`, `NewPaneSizingTests`, `WorkspaceTests`, `WorkspaceDuplicateSlotTests` | installed-app creation feel remains observational |
| SP-FR-008…016, SP-NFR-006, 009 | shipped | split AppKit canvas/coordinator/card/overlays | `SpatialCanvasGestureTests`, extensive `SpatialCanvasInteractionTests`, real canvas XCUITest | current move-invalid policy supersedes unchecked T-059 text and should be reviewed explicitly |
| SP-FR-017 | shipped | `PaneFocusRouting`, `SurfacePool` guards | `PaneFocusSettlementTests`, hosted focus/drag tests | no field telemetry for focus transitions |
| SP-FR-018…020 | shipped | header schema, layout, stores, projections, action routes | pane header schema/layout/store/projection/plugin-route suites and fitness tests | complex plugin headers still need snapshot sampling |
| SP-FR-021…022 | shipped | `PaneActivity`, projections, notifier, 200 ms poll | `PaneActivityTests`, `PaneAttentionTests`, accessibility tests | manual long-command multi-pane observation remains open in T-029 |
| SP-FR-023, SP-NFR-004 | shipped | lazy `SurfacePool`, placeholder seed, pool reconciliation | `SurfaceLifecycleTests`, restored pane/relaunch tests | hidden viewed-pane GPU reduction is partial/unquantified |
| SP-FR-024, SP-NFR-003, 011…012 | shipped | no sizing options, lazy-list shape fitness, update bound, stall sampler | `PaneHostingSizingTests`, `PaneUpdateTurnBoundTests`, diagnostics tests | incident reproduced and sampled under T-121 |
| SP-FR-027 | shipped | `SpatialCanvasView.sizeThatFits` | `PaneHostingSizingTests` | measured offscreen; not yet observed in the installed app |
| SP-FR-025 | shipped | core intent catalog + workspace provider + catalog owner join | core intent/catalog/provider tests across unselected/paged workspace | no known gap |
| SP-FR-028 | shipped | `CoreIntentCatalog.workspaceTabClose` + `WorkspaceIntentProvider.closeTab` over `WorkspaceStore.closeTab` | `PaneProcessAndTabCloseContractTests`, `PaneProcessAndTabCloseIntentTests` | `workspace.pane.split.v1` still discards the pane it creates — see the 2026-08-12 decision-log entry; that half of T-132 is not delivered |
| SP-FR-026, SP-NFR-005 | shipped | card/canvas accessibility and attention vocabulary | attention accessibility and hosted canvas tests | complete VoiceOver installed-app journey remains manual |
| SP-NFR-010 | shipped | coordinator responsibility split and domain tags | domain/fitness suites; detailed cross-cutting work moves to PRD-015 | none for current shape |

### Phases

| Phase | Outcome | State |
|---|---|---|
| spatial core | valid deterministic value transactions | shipped |
| AppKit interaction | native drag/resize/menu/copy/accessibility | shipped |
| chrome and lifecycle | one bounded header, stable resources, focus/attention | shipped |
| incident containment | sizing cleanup, convergence bound, automatic stall sample | shipped |
| incident closure | real reproduction, root cause, falsifiable regression | open |

### Migration and rollout

- Existing pane UUIDs/layouts remain valid; no data migration is introduced by this PRD.
- The old uniform T-059 invalid-preview story is historical. Current move and resize
  settlement is specified separately in SP-FR-015.
- The old `Change Type` header submenu and second content-drawn pane chrome are superseded.
- T-091 remains partial until its open criteria are met; mitigation rollout must retain the
  stall sampler and runbook.

## 11. Dependencies, risks, and mitigations

| Risk | Likelihood | Impact | Mitigation/owner |
|---|---|---|---|
| invalid preview and commit policies drift | medium | high | one coordinator + core transaction validation + SP-FR-015 tests |
| header accessories consume drag/resize/close regions | medium | high | pure solver reservations and point sweeps |
| pane content refresh recreates PTY/web view | medium | critical | UUID resource join and content-key/header separation |
| focus callbacks form another cycle | low | critical | two routing guards and bounded transition tests |
| attention clears from selection instead of viewing | medium | high | three-condition projection and one clearing path |
| T-091 recurs without reproducible evidence | medium | critical | automatic stall sample, current-build runbook, no overclaiming |
| public pane API expands around local gestures | medium | high | interaction classification and inventory gate |

## 12. Open questions and decisions

### Open questions

| ID | Question | Owner | State |
|---|---|---|---|
| `SP-Q-001` | What exact live Agent Lens/content transition starts T-091? | performance/native UI | open; requires current-build GUI reproduction |
| `SP-Q-002` | Should invalid move retain the last valid target like resize, or deliberately clear/rollback as current source does? | product/native interaction | open product review; current behavior is canonical until changed |
| `SP-Q-003` | Should an already-materialized hidden terminal reduce GPU work further without teardown? | terminal/performance | partial research only |

### Decision log

| Date | Decision | Reason | Supersedes |
|---|---|---|---|
| 2026-07-25 | Geometry lives in pure 12×12 transactions; pane UUID joins values/resources. | deterministic validation and resource continuity | view-owned split tree |
| 2026-07-27 | Pane menu is flat Split/Stack/Duplicate/Copy ID/Close; content type switching leaves chrome. | direct utilities and one content vocabulary | Change Type submenu |
| 2026-08-02 | One host header accepts bounded leading/trailing values from built-ins/plugins. | density, native ownership, one renderer | double chrome bars |
| 2026-08-05 | Named border sizes reuse the same resize transaction and opposite-edge semantics. | menu/double-click/drag parity | separate resize math |
| 2026-08-06 | Focus commands reread live model and suppress host-generated responder events. | break the measured bidirectional focus cycle | unguarded focus mirroring |
| 2026-08-08 | Pane content publishes no sizing options and a convergence bound stays permanent. | canvas already owns size; content-derived ideal measurement is unnecessary | default `NSHostingView` sizing options |
| 2026-08-09 | Invalid move clears/rolls back; invalid resize retains last valid preview. | current source and tests are authoritative | T-059's uniform “hold last valid” narrative |
| 2026-08-09 | T-091 is mitigated/observable, not closed. | no real reproduction or proven root cause exists | any implication that the sizing cleanup fixed the incident |
| 2026-08-12 | `workspace.tab.close.v1` refuses a workspace's only tab instead of emptying it. | `WorkspaceCatalog.closeTab` has always kept the last tab (`Workspace.swift:613`, pinned by `WorkspaceTests.swift:209`), and it signals that by returning no events. A pass-through adapter would therefore have answered success while removing nothing — the failure mode a scripted caller looping over tabs hits first. `dev.tenon.core.close-refused` is the same code the pane-close contract already declares for a refused removal. | the assumption in T-132 that tab close is a straight pass-through |
| 2026-08-12 | `workspace.pane.split.v1` still returns nothing, and widening it is NOT deferred on cost — it is a **major mint** this task's file set cannot carry. | Its output is a closed object with no properties. Adding `paneID` is "add any top-level input/output field to a closed object", which `docs/design-intent-bus.md:620-624` answers "same major? no", `FC-NFR-009` states as "closed schemas MUST not widen inside one major", and `IAR-NFR-008` repeats. `filesystem.directory.list.v2` is the standing precedent and its v1 was removed outright. So the correct change is `workspace.pane.split.v2`, and that reaches `plugins/core-commands/{manifest.json,main.js}`, `plugins/file-explorer/{manifest.json,main.js}` — both name `workspace.pane.split.v1` in `uses`, so an unmigrated manifest breaks their split commands — plus `FileExplorerPluginTests`, `CoreCommandsPluginTests`, `design-command-palette.md`, `design-pane-slots.md`, and `architecture-interaction-boundaries.md`. None of those is in T-132's claimed file set. | T-132's criterion (d), which names `workspace.pane.split.v1` and assumes a same-major edit |
| 2026-08-13 | A pane-level mutation that leaves a tab empty closes that tab whenever another tab survives. `workspace.pane.close.v2` and `dev.tenon.core-commands.pane.close.v2` replace their v1 contracts. | Empty source tabs were residue from closing or moving a final pane, not durable working state. The model applies the rule once across close, move, and reservation cleanup; the required last tab remains because every workspace must keep one tab. The extra tab removal changes observable side-effect meaning, so same-major evolution is forbidden and both superseded v1 paths are deleted. | SP-FR-006's rule that every final-pane close leaves an empty tab |
| 2026-08-13 | Automatic horizontal close absorption reads the live pane-width preference and stops growing at that width; declined columns remain empty canvas. Existing over-limit panes and manual resize remain untouched. | close reflow previously bypassed the creation sizing policy and could widen the survivor straight to the full canvas | creation-only maximum-width semantics |
| 2026-08-12 | The attention poll asks a pane for a screen *fingerprint*, and `PaneActivity.Observation` carries `screen: Int` instead of `text: String`. | The machine's only use of a screen is `IdleDetector.record`, which is one `==`. Paying for that with `GhosttySurface.renderedText` — one Swift `String` per row appended a `Character` at a time, plus one ICU regular expression per row to trim trailing blanks — put **83% of a stalled main thread** inside that getter in incident `0005-87f24878`, reached from `AppComposition.startAttentionPolling` → `SurfacePool.pollActivity`. At the shipped 200 ms cadence a headless count is 40 renders per 8 panes per 5 turns, 1600 a minute. `renderedText` stays exactly as it is for `pane.read`, `terminal.wait.v1` and `agents.run`, which read the characters. | the assumption that one observation type can serve both the poll and the readers |
| 2026-08-11 | The canvas answers the size it is proposed; silence is not neutral, it routes the question to AppKit. | a `sample` of the stalled process put 2395 of 3461 main-thread samples in `_ZStackLayout.sizeThatFits` → `AppKitPlatformViewHost.fittingSize` → `_populateEngineWithConstraintsForViewSubtree`, and the sweep dirtied the `NSTextField`s it measured | the 2026-08-09 reading that the root cause was unproven |

## 13. Verification receipts

- 2026-08-12, T-141, `SP-NFR-013`: **red first, with the number in the failure message** —
  `testTheActivityPollNeverRendersAScreenAsText` reported `("40") is not equal to ("0")` across
  8 panes and 5 poll turns before the change, and 0 after. Scope green: `PaneAttentionTests`
  **11 / 0**, `PaneActivityTests` **24 / 0**, `IdleDetectorTests` **3 / 0**,
  `SurfaceLifecycleTests` **11 / 0**, `TerminalIntentProviderTests` **17 / 0**,
  `PaneUpdateTurnBoundTests` **5 / 0**. Full suite **2070 tests, 1 failure**, outside this task's
  file set: `DomainTagFitnessTests.testNoTagIsIsolatedFromTheCodeAroundIt` moved 8 → 9 on
  `PluginStreamProcess.swift`, an untracked new file in T-140's lane, and was left alone.
  What this receipt does **not** claim: the freeze in incident `0009-642b2192` is a different
  defect and is untouched here. `PaneUpdateTurnBoundTests` was rewritten in this change to mount
  the shipping `AgentSessionView` rather than a hand-written imitation of it — the imitation
  omitted `.textSelection(.enabled)` and the mount-time bottom scroll, which is what
  `0009`'s stack walks through — and the mounted test **passes**, so the layout-loop hypothesis
  built from that stack is recorded as unconfirmed rather than as a finding.
- 2026-08-12, T-141, `SP-NFR-013`, **installed-app receipt**: driven through `tenon-cli` against
  the 18:08 build. 24 panes built by `workspace.pane.split.v1` — four more than incident
  `0005-87f24878` held — each running a shell loop printing a timestamp every 50 ms, so every
  screen changes between consecutive polls. `sample` over 5 s: main thread **3262 samples**,
  `renderedText` appears **0 times in the whole file**, and the incident's own call chain now
  reads `startAttentionPolling` (`TenonApp.swift:934`) → `pollActivity` (`SurfacePool.swift:229`)
  → `screenFingerprint` (`GhosttySurface.swift:1188`) → `Hasher._combine`, at **5 samples =
  0.15%**. The same chain measured **83.2%** (1905 / 2289) in `0005`. App CPU 17–20% under that
  load with RSS stable at 82–115 MB; no new health event and no new incident directory was
  written during the run. Regressions checked on the same panes: `terminal.viewport.read.v1`
  still returns real characters (37 × 22), and `terminal.wait.v1 --for tui-idle` answers `met`
  in 0.43 s on a quiet pane. One correction to this session's own record: a first pass at the
  load used bash `while … done` against the operator's fish shell, so the panes sat idle and an
  earlier 0.24% figure described no load at all; the numbers above are the re-run.
- 2026-08-12, T-132, `SP-FR-028`: `PaneProcessAndTabCloseContractTests` 3 / 0 and
  `PaneProcessAndTabCloseIntentTests` 6 / 0, both **red first** — the contract half on
  "workspace.tab.close.v1 is not in the closed core inventory", the provider half on
  "no provider binding for workspace.tab.close.v1". Three behaviours are separately asserted:
  a two-tab workspace loses the scoped tab and every pane under it; the same call against a
  one-tab workspace comes back `dev.tenon.core.close-refused` with the tab still there; and an
  unscoped call comes back `dev.tenon.core.tab-not-found` without guessing at the selection.
  ⚠️ Not covered: no test drives tab close through the real dispatcher's `.policy`
  confirmation, so what is proved is the provider's behaviour and the contract's declared
  effects, not that a CLI caller is actually prompted.
- Geometry/workspace suites cover valid grids, placement, split, absorption, fill-width,
  fraction resize, cycles, duplicate, stale baselines, affected IDs, and atomic no-ops.
- Hosted AppKit canvas tests cover empty anchors, drag thumbnail, cross-tab routing,
  invalid/stale/cancel behavior, menu ordering, Copy Pane ID, hit-testing, cursor ownership,
  focus restoration, header controls, and accessibility identifiers/values.
- Header suites cover schema bounds, admission, solver geometry/folding/overflow, native store
  lifecycle, built-in projections, plugin instance routing, and generation retirement.
- Attention/lifecycle suites cover the pure state machine, viewed projection, notification
  coalescing, lazy surface creation, queued text, retention, exact release, and relaunch.
- Pane hosting/update-bound suites prove current no-sizing and convergence contracts.
- 2026-08-11, T-121: the stall was reproduced in the installed 0.1.0 app and sampled while it
  ran. `beatSequence` held at 3147538 for over five minutes — the main runloop completed no
  turn at all — while footprint climbed 550 → 2810 MB at ~500 MB/min at 100% CPU; it does not
  recover. `sample` put **2395 of 3461 main-thread samples** in
  `_ZStackLayout.sizeThatFits` → `PlatformViewLayoutEngine.sizeThatFits` →
  `AppKitPlatformViewHost.fittingSize` → `_populateEngineWithConstraintsForViewSubtree`, with
  `-[NSTextFieldCell _invalidateEffectiveFont]` (92) inside the measuring pass, and a further
  981 in `LazySubviewPlacements.updateValue()` → `LazyLayoutViewCache.updatePrefetchPhases()`,
  whose `Update.Action` buffer copies whole on every append. `SP-FR-027` answers the first;
  the incident record is at
  `~/Library/Application Support/Tenon/diagnostics/incidents/2cb0ff1f-…/0001-ded16be7/`.
- 2026-08-11, `SP-FR-027`: `PaneHostingSizingTests` 7 / 0 and full suite **1879 / 0**. The
  production pin was red before the change. Its control pair measures the mechanism rather
  than the source — a representable declaring no size is queried through Auto Layout, one
  declaring it is queried zero times — and `testAnsweringZeroIdealStillFillsTheStage` rebuilds
  `ContentView.swift:99`'s infinite frame to prove the canvas still receives every remaining
  point; mutating its answer to `.zero` turns that test red at 0.0 against an expected 277.0.
  NOT VERIFIED: the fix has not been observed in a running app, because installing over the
  running Tenon would destroy the panes of every other session working in it.
- Historical aggregate test counts remain dated receipts, not a claim that this documentation
  change reran the full repository suite.

## 14. Change history

| Date | Change | Author |
|---|---|---|
| 2026-08-09 | Created canonical PRD from current spatial/header/focus/attention/resource source, twelve tasks, and focused tests; recorded T-059 supersession and T-091 partial status. | Codex |
| 2026-08-11 | Added SP-FR-027 after T-121 reproduced the stall and sampled it; moved SP-FR-024 and the T-091 row off partial. | Claude |
| 2026-08-13 | Extended the pane-width policy to cap automatic horizontal close absorption without locking manual resize. | Codex |
| 2026-08-14 | Added SP-FR-028: the pinned pane title became a public capability so the Agent Harness briefing (`SET-FR-030`…`034`) could describe a rename that exists. | Claude |
