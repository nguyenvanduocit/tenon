# PRD — Declarative plugin UI, pane chrome, instances, and visual verification

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-005` |
| Lifecycle | `shipped` |
| Owner | plugin-contributions, pane-chrome, row-list, plugin-host, and workspace-model domains |
| Reviewers | product, native UI, accessibility, plugin runtime, security, performance, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-004, T-007, T-011, T-012, T-036, T-056, T-063 |
| Existing designs | [`design-plugin-views.md`](../design-plugin-views.md), [`design-plugin-view-instances.md`](../design-plugin-view-instances.md), [`design-pane-header.md`](../design-pane-header.md) |
| Acceptance specification | [`plugin-ui.feature`](plugin-ui.feature) |

## 1. Executive summary

### Problem

A replaceable plugin cannot depend on a bespoke host screen for every card, form, tree,
browser, dashboard, or board it needs. Giving JavaScript native SwiftUI/AppKit objects or
free-form CSS would instead break isolation, visual consistency, accessibility, lifecycle
ownership, and the ability to validate contributions before rendering. A second problem is
identity: the same view type may exist in several panes and workspaces, so singleton state or
global-workspace routing makes panes leak state into one another.

### Proposed outcome

Plugins publish bounded pure values. A typed body tree, shared row vocabulary, modal value,
and flat pane-header value are decoded in TenonCore and rendered with Tenon's native design
system. User actions return through the view's select/submit callbacks; product mutations then
use canonical intents. Instanced views key JavaScript state and host resources by the owning
pane UUID, reconcile from the workspace catalog, and retain state across tab switches, moves,
and healthy reloads.

Pointer drag/drop is a same-instance contribution affordance with a keyboard-accessible
alternative. A real-host offscreen snapshot writes any plugin pane to PNG without a window or
Screen Recording permission, closing the gap between tree-shape tests and actual geometry.

### Why now

Historical task state has drifted. T-011's body `browserBar` no longer exists; Browser now
publishes the same universal pane `header` vocabulary used by every view. T-063 still shows
unchecked task boxes although `PluginViewSnapshot` and its tests are current. This PRD records
the live contract so future changes do not resurrect a duplicate chrome component or discard
visual verification as unfinished.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| body vocabulary | [`PluginViewNode.swift`](../../Sources/TenonCore/PluginViewNode.swift), runtime decoder and renderer | high | current cases, tokens, state identity |
| pane header | [`PaneHeaderItem.swift`](../../Sources/TenonCore/PaneHeaderItem.swift), [`PaneHeader.swift`](../../Sources/TenonCore/PaneHeader.swift), AppKit renderer/layout | high | flat vocabulary, bounds, routing, drag band |
| instances | plugin runtime/host reconciliation, workspace catalog | high | desired/open instance lifecycle and projection |
| rows | runtime models, `TreeRowsView`, Files/Changes tests | high | shared row schema and native rendering |
| drag/drop | [`PluginViewDrag.swift`](../../Sources/TenonCore/PluginViewDrag.swift), host router, Kanban | high | exact scope and payload rules |
| snapshot | [`PluginViewSnapshot.swift`](../../Sources/TenonApp/PluginViewSnapshot.swift), snapshot tests | high | real-host headless rendering ships |
| tasks/designs | T-004/T-007/T-011/T-012/T-036/T-056/T-063 and design docs | medium | historical intent; T-011/T-063 status is superseded by source |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Let replaceable plugins express useful, native, bounded UI without native object access or feature-specific host screens. |
| Primary users? | plugin authors and operators using plugin-owned panes in multiple workspaces |
| Success? | independent instances, native consistent rendering, safe actions, no state/resource leaks, visual defects observable before shipping |
| Fixed constraints? | CONTRIBUTION boundary, semantic tokens, one pane header/list renderer, catalog-owned lifetime, explicit intents for effects |
| Unknown? | no current product gap; each new component still needs representative installed/offscreen visual review |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `PUI-A-001` | The current primitives/components cover normal plugin layouts without CSS. | author feedback and new-plugin audits | supported by shipped plugins |
| `PUI-A-002` | 900×620 plus narrow/wide snapshot variants expose material geometry defects. | snapshot review protocol | adopted; per-feature variants required |

## 3. Users, jobs, and vocabulary

The primary user is a plugin author—including an AI author—who needs to build a Files tree,
browser, dashboard, board, or status view from a small governed vocabulary. The affected
operator expects every copy to stay with its pane/workspace, every control to feel native, and
the pane to remain draggable and accessible.

- Compose layout and status UI without waiting for a bespoke host component.
- Publish rows, body, header, and one modal through one view contribution.
- Open the same instanced view in several panes without shared address/root/draft/resource.
- Move cards by pointer while retaining button/menu/keyboard routes.
- Render a real plugin pane offscreen before trusting layout code or shape tests.

| Term | Meaning | Not to be confused with |
|---|---|---|
| view type | `(pluginID, viewID)` registration | one pane instance |
| view instance | pane UUID for an instanced type | SwiftUI appearance instance |
| body | recursive `PluginViewNode` tree | pane header or row list |
| header | flat `PaneHeader` value in the pane's 34-point chrome | a plugin-drawn toolbar body |
| rows | shared `TreeRowItem` vocabulary | a limited fallback renderer |
| modal | one plugin-owned sheet value | another app window |

## 4. Goals, measures, scope, and bounds

- `PUI-G-001` — Plugins compose native panes from pure validated values.
- `PUI-G-002` — Pane/workspace identity deterministically owns state and resources.
- `PUI-G-003` — One action and rendering model remains accessible and capability-safe.
- `PUI-G-004` — Geometry joins shape/logic as required verification evidence.

Targets: zero cross-instance state/resource collisions; zero public native objects; zero
malformed-node host crashes; one header/list renderer for built-in and plugin values; zero
cross-instance drops; every shipped plugin view has a shape test and representative snapshot or
installed visual receipt.

Key bounds include body numeric clamps and value limits, box width 60…1200, progress 0…1,
drag payload 1…256 characters, header item/entry/segment caps, identifiers ≤64, labels ≤200,
badges ≤24, tooltips ≤1024, text fields ≤2048, one flexible header item, and fixed leading/
trailing item budgets.

In scope: body/row/header/modal publication, parsing, native rendering, action callbacks, state
identity, instances/workspace routing, drag/drop, web-surface references, gallery, snapshot.
Non-goals: arbitrary SwiftUI/AppKit/WebKit objects, free CSS/HTML UI, plugin-authored
accessibility IDs, cross-pane drag transfer, using CONTRIBUTION as authority, lifecycle intents,
or a reintroduced `browserBar` body node.

## 5. User experience

`tenon.views.register` declares a singleton or instanced type. `views.set` publishes header plus
body or rows and optionally a modal. Body wins when both body and items exist. Unknown style
tokens fall back; malformed nodes/items are skipped with a plugin diagnostic rather than blanking
the entire pane. Interactive buttons, rows, menus, header controls, and drops use the existing
select route; committed text uses submit.

The pane draws one header. Static items remain drag surface; interactive items have native focus,
tooltips, hit areas, and routing. The layout preserves close control, north resize edge, and a
contiguous drag band, folding eligible items into one host-owned overflow menu when necessary.
Browser navigation chrome is three icon buttons plus a flexible text field in this header; the
old body `browserBar` is historical.

For instanced views the catalog, not visibility, defines lifetime. Switching tabs or moving a
pane preserves its UUID/state. Closing the pane emits close and releases only its resources.
Workspace-dependent views query their pane owner; selecting another workspace does not reroot
inactive panes.

## 6. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `PUI-FR-001` | Plugins **MUST** register and publish UI as bounded declarative CONTRIBUTION values; the host **MUST** validate, snapshot, diff, and render them. | shipped | `@req-pui-fr-001` |
| `PUI-FR-002` | The body vocabulary **MUST** provide recursive stacks, box, scroll, grid, text, image, spacer, and divider primitives. | shipped | `@req-pui-fr-002` |
| `PUI-FR-003` | The body vocabulary **MUST** provide card, badge, button, stat, keyValue, progress, field, and textfield components. | shipped | `@req-pui-fr-003` |
| `PUI-FR-004` | A webview node **MUST** name only a host-owned surface ID; navigation **MUST** occur through declared browser intents. | shipped | `@req-pui-fr-004` |
| `PUI-FR-005` | Style, weight, color/tint, scroll axis, and button style **MUST** use closed semantic tokens with documented fail-soft defaults. | shipped | `@req-pui-fr-005` |
| `PUI-FR-006` | Numeric/text/tree values **MUST** be bounded/clamped; one malformed or unknown node **MUST** be skipped with a diagnostic without killing the plugin or whole view. | shipped | `@req-pui-fr-006` |
| `PUI-FR-007` | Stateful nodes **MUST** retain identity across whole-tree republish by authored field action/surface ID, with duplicate authored IDs kept distinct. | shipped | `@req-pui-fr-007` |
| `PUI-FR-008` | `views.set` **MUST** accept body or rows; body **MUST** win when present and legacy rows **MUST** remain first-class. | shipped | `@req-pui-fr-008` |
| `PUI-FR-009` | Rows **MUST** support stable ID, label, detail, accessory, kind, depth, icon, disclosure, selection, path, menu, and inline editing through the shared native row renderer. | shipped | `@req-pui-fr-009` |
| `PUI-FR-010` | Row click/menu selection **MUST** reach select, while committed edit text **MUST** reach submit exactly once. | shipped | `@req-pui-fr-010` |
| `PUI-FR-011` | A view **MAY** publish one modal with title/body/dismiss action; omission/dismissal **MUST** close it and route one dismiss selection. | shipped | `@req-pui-fr-011` |
| `PUI-FR-012` | The flat header vocabulary **MUST** be exactly dot, label, badge, image, spinner, iconButton, toggle, segmented, menu, and textfield. | shipped | `@req-pui-fr-012` |
| `PUI-FR-013` | Header admission **MUST** enforce item, identifier, display, option, duplicate, reserved-ID, and one-flex bounds equally for built-in and plugin producers. | shipped | `@req-pui-fr-013` |
| `PUI-FR-014` | Header select/submit routing **MUST** derive from the published item kind; plugin JSON **MUST NOT** set host accessibility IDs. | shipped | `@req-pui-fr-014` |
| `PUI-FR-015` | Header layout **MUST** preserve close/resize controls and a usable contiguous drag band, shrinking/folding into one host-owned overflow control as needed. | shipped | `@req-pui-fr-015` |
| `PUI-FR-016` | Browser chrome **MUST** use the shared header; the historical body `browserBar` **MUST NOT** return as a second chrome path. | shipped | `@req-pui-fr-016` |
| `PUI-FR-017` | A view registration **MUST** explicitly declare instanced behavior; instance identity **MUST** be the owning pane UUID. | shipped | `@req-pui-fr-017` |
| `PUI-FR-018` | Instanced set/select/submit/open/close callbacks **MUST** carry that instance ID; JavaScript state **MUST** remain keyed per instance. | shipped | `@req-pui-fr-018` |
| `PUI-FR-019` | Singleton views **MUST** retain one section with no instance callbacks/ID and remain backward compatible. | shipped | `@req-pui-fr-019` |
| `PUI-FR-020` | Workspace catalog enumeration **MUST** be the authoritative desired instance set across all workspaces, tabs, and panes. | shipped | `@req-pui-fr-020` |
| `PUI-FR-021` | Reconciliation **MUST** publish active=desired before callbacks, close/release removed instances, open new ones, and remain idempotent/reentrancy-safe. | shipped | `@req-pui-fr-021` |
| `PUI-FR-022` | Reload/enable **MUST** reopen desired instances on the active generation; failed replacement **MUST** preserve last good generation/resources; stale callbacks **MUST NOT** mutate it. | shipped | `@req-pui-fr-022` |
| `PUI-FR-023` | Closing one instance **MUST** release only resources keyed to its installation/view/instance; moving or hiding it **MUST NOT**. | shipped | `@req-pui-fr-023` |
| `PUI-FR-024` | Workspace-dependent instances **MUST** resolve `workspace.pane.owner.v1` and filter workspace facts by that owner rather than global selection. | shipped | `@req-pui-fr-024` |
| `PUI-FR-025` | Switching the selected workspace **MUST NOT** mutate inactive instance root/state; returning **MUST** restore its prior state. | shipped | `@req-pui-fr-025` |
| `PUI-FR-026` | Shell projection **MUST** select exact plugin/view/instance identity and **MUST NOT** fall back by display name or another plugin's section. | shipped | `@req-pui-fr-026` |
| `PUI-FR-027` | Drag source/drop target **MUST** be transparent body wrappers and deliver target action plus source payload through select. | shipped | `@req-pui-fr-027` |
| `PUI-FR-028` | A drop **MUST** be admitted only within the exact same plugin, view, and instance; malformed/cross-scope envelopes **MUST** fire nothing. | shipped | `@req-pui-fr-028` |
| `PUI-FR-029` | Empty/over-256 payload or empty target action **MUST** degrade to ordinary rendering without draggable/droppable behavior. | shipped | `@req-pui-fr-029` |
| `PUI-FR-030` | Every drag operation **MUST** retain a button/menu/keyboard/VoiceOver-accessible alternative. | shipped | `@req-pui-fr-030` |
| `PUI-FR-031` | The snapshot command **MUST** boot the real host/inventory/runtime/view, use throwaway plugin state, wait on the exact section, render with native pane chrome, write PNG, and exit without a window. | shipped | `@req-pui-fr-031` |
| `PUI-FR-032` | Snapshot target, workspace, and size **MUST** be configurable; invalid/no contribution **MUST** fail with actionable diagnostics. | shipped | `@req-pui-fr-032` |
| `PUI-FR-033` | The bundled View Gallery **MUST** exercise the current vocabulary as a singleton, workspace-independent example. | shipped | `@req-pui-fr-033` |
| `PUI-FR-034` | View publication **MUST NOT** grant sensitive authority; finite filesystem/workspace/browser/terminal/OS effects **MUST** cross canonical intents. | shipped | `@req-pui-fr-034` |
| `PUI-FR-035` | Instance open/close **MUST** remain host reconciliation facts/callbacks and **MUST NOT** become lifecycle intents. | shipped | `@req-pui-fr-035` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `PUI-NFR-001` | native design | All plugin UI **MUST** resolve through TenonTheme/design-system tokens; feature-local colors/fonts/CSS **MUST NOT** enter the public schema. | shipped | `@req-pui-nfr-001` |
| `PUI-NFR-002` | accessibility | Controls **MUST** have native keyboard/focus/VoiceOver behavior, readable labels/tooltips, non-color-only state, and input parity. | shipped/continuous visual | `@req-pui-nfr-002` |
| `PUI-NFR-003` | security | Plugins **MUST NOT** receive native objects or mint host accessibility IDs; drag scope is correctness containment, not hostile-local-app authentication. | shipped | `@req-pui-nfr-003` |
| `PUI-NFR-004` | boundedness | Trees, rows, headers, modal, strings, options, geometry, and drag payloads **MUST** enforce central bounds before rendering/routing. | shipped | `@req-pui-nfr-004` |
| `PUI-NFR-005` | lifecycle | Generation and instance teardown **MUST** cancel callbacks/resources exactly once and reject stale publication. | shipped | `@req-pui-nfr-005` |
| `PUI-NFR-006` | determinism | Pure decode/identity/reconcile/drag rules **MUST** produce the same values for the same input snapshot. | shipped | `@req-pui-nfr-006` |
| `PUI-NFR-007` | performance | Lazy rows/grids/scroll content and identity-preserving republish **MUST** avoid rebuilding offscreen or stateful native resources unnecessarily. | shipped | `@req-pui-nfr-007` |
| `PUI-NFR-008` | compatibility | Additive fields/tokens **MUST** fail soft; singleton/items plugins **MUST** remain compatible; removed `browserBar` **MUST** stay explicitly superseded. | shipped | `@req-pui-nfr-008` |
| `PUI-NFR-009` | visual evidence | Shape tests **MUST NOT** be accepted as geometry evidence; representative real-host PNG or installed visual receipts **MUST** accompany layout-sensitive changes. | shipped process | `@req-pui-nfr-009` |
| `PUI-NFR-010` | architecture | Public UI remains CONTRIBUTION plus owner callbacks; resources use typed host ownership and product effects use INTENT. | shipped | `@req-pui-nfr-010` |

## 7. Acceptance and architecture

[`plugin-ui.feature`](plugin-ui.feature) maps all 45 requirements. Core decoder/value,
runtime/host instance, AppKit/SwiftUI header/renderer, workspace-scoping, drag, shipped-plugin,
and offscreen PNG tests are separate evidence seams.

| Interaction | Classification | Constraint |
|---|---|---|
| register/set UI | CONTRIBUTION | plugin-owned declarative state |
| select/submit/open/close callback | owner-scoped contribution fact | no provider resolution |
| desired instance enumeration/reconcile | DIRECT | workspace/host same owner |
| web/native resource retention | RESOURCE lifecycle | installation+instance ownership |
| product effect after action | INTENT | exact cross-owner finite operation |

## 8. Delivery matrix, risks, and decisions

| Requirements | Source/evidence | State |
|---|---|---|
| 001…016 | value decoders, body/row/header renderers/tests | shipped |
| 017…026 | instance host/runtime/workspace tests | shipped |
| 027…030 | drag core/host/Kanban tests | shipped |
| 031…033 | `PluginViewSnapshot`, snapshot/gallery tests and documented command | shipped despite stale T-063 boxes |
| 034…035/NFR set | boundary/fitness/accessibility/visual evidence | shipped, continuous review |

Risks include vocabulary growth into CSS, state identity collision, visibility-driven teardown,
header controls consuming drag/resize space, cross-plugin drop leakage, and tests missing geometry.
Central tokens/bounds, pane UUID ownership, catalog reconciliation, header solver invariants, exact
drag scope, and real-host snapshots mitigate them.

Decisions: composition over bespoke components; body and rows remain peers; pane header replaces
body `browserBar`; instance ID is pane UUID; catalog not appearance owns lifetime; drag is optional
pointer affordance; snapshot source proves T-063 shipped and supersedes its unchecked task state.

## 9. Verification receipts and change history

| Date | Worktree | Result | Exclusions |
|---|---|---|---|
| 2026-08-09 | current dirty tree, documentation audit | current body/header/instance/drag/snapshot source and tests mapped | no new PNG generated in this documentation-only pass |

Initial canonical PRD created 2026-08-09 to reconcile the complete live UI contract and historical
task drift.
