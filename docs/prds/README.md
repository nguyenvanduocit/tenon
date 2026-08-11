# Tenon PRD and Gherkin coverage catalog

**Lifecycle:** active migration control document

**Created:** 2026-08-09
**Scope:** every first-party product capability, shipped behavior, planned behavior, and
maintained product/engineering document in this repository

## Purpose

Tenon currently describes product behavior across `VISION.md`, design records, source
inventories, plugin manifests, 103 Kanban task files, tests, and retrospective reports. The
same capability is often split across several tasks, while post-shipping corrections can
make an old task's implementation story false. This catalog defines the canonical PRD units
and proves that every known task and source-discovered feature has an owner.

Completion requires both files for every row below:

- `<slug>.prd.md` — product context, requirements, delivery matrix, implementation mapping,
  risks, decisions, and verification receipts;
- `<slug>.feature` — observable acceptance examples tagged with the PRD and requirement IDs.

The templates in [`../../templates/`](../../templates/README.md) are normative for this
migration.

## Canonical PRD set

| ID | Slug | Capability boundary | Current evidence state | Task sources |
|---|---|---|---|---|
| `TENON-PRD-000` | [`product-direction`](product-direction.prd.md) ([Gherkin](product-direction.feature)) | product promise, target operator, supervision outcomes, positioning, product-level success measures, developer velocity, and proportional permission policy | partial; native foundation ships while Attention Inbox/capsules/fan-out and velocity measurements remain to validate | none; `VISION.md`, product-owner direction, and research sources |
| `TENON-PRD-001` | [`workspace-shell`](workspace-shell.prd.md) ([Gherkin](workspace-shell.feature)) | app/window identity, workspace catalog, sidebar, workspace identity, restoration, active pane, and recent-workspace behavior | shipped; current-source audited in canonical PRD/Gherkin | T-001, T-003, T-027, T-032, T-034, T-097, T-098, T-099 |
| `TENON-PRD-002` | [`command-surfaces`](command-surfaces.prd.md) ([Gherkin](command-surfaces.feature)) | Command Palette, `+` launcher, tab launcher, empty-state launcher, product keybindings, Copy Tab ID, tab selection, and tab reordering | shipped in current source; the failed pan-observer account is superseded by a chip-front AppKit surface, with installed human-drag confirmation still owed | T-006, T-008, T-019, T-022, T-039, T-057, T-058, T-096, T-101 |
| `TENON-PRD-003` | [`spatial-panes`](spatial-panes.prd.md) ([Gherkin](spatial-panes.feature)) | spatial canvas, pane creation/placement, pane chrome, sizing, focus, drag/resize, attention, Copy Pane ID, hosting, and accessibility | partial; the pane update-loop investigation retains an open part | T-025, T-026, T-029, T-031, T-059, T-064, T-065, T-076, T-079, T-087, T-088, T-091 |
| `TENON-PRD-004` | [`settings`](settings.prd.md) ([Gherkin](settings.feature)) | application and plugin settings, defaults, persistence, personalization, and the operator's permission switch | shipped; current-source audited in canonical PRD/Gherkin, plugin runtime constraints remain cross-linked to PRD-010 | T-002, T-130 |
| `TENON-PRD-005` | [`plugin-ui`](plugin-ui.prd.md) ([Gherkin](plugin-ui.feature)) | declarative plugin view vocabulary, instances, native chrome components, workspace-scoped view state, drag/drop, and visual verification | shipped; current source supersedes the old body `browserBar` with shared header chrome and proves the headless snapshot despite stale unchecked task boxes | T-004, T-007, T-011, T-012, T-036, T-056, T-063 |
| `TENON-PRD-006` | [`browser-and-open`](browser-and-open.prd.md) ([Gherkin](browser-and-open.feature)) | browser plugin/surface, link detection, open-handler resolution, principal semantics, user-agent behavior, and user choice | partial; audited pair exists, while typed host opener, Browser `url.open.v1` offer, Settings approval, chooser/default UX, and visible failure remain pending | T-005, T-070, T-071, T-072, T-073, T-077 |
| `TENON-PRD-007` | [`cli-control`](cli-control.prd.md) ([Gherkin](cli-control.feature)) | packaged CLI, per-channel local control socket, discovery, invocation, waiting, timeout, and recovery | shipped; current-source audited in canonical PRD/Gherkin, with protocol v3 superseding stale wire-v2 prose | T-009, T-045, T-050, T-051 |
| `TENON-PRD-008` | [`files-and-content`](files-and-content.prd.md) ([Gherkin](files-and-content.feature)) | file explorer, editor, git/diff, smart content placement, directory metadata, images/HTML, file operations, shared rows, and Docs-pane retirement | partial; file-write major/manual-root decisions remain open and the user-directed redundant Docs-pane removal is in progress | T-010, T-014, T-016, T-024, T-028, T-030, T-038, T-054, T-081, T-083, T-085, T-086, T-103 |
| `TENON-PRD-009` | [`terminal`](terminal.prd.md) ([Gherkin](terminal.feature)) | terminal creation/input, command execution, viewport/scrollback, renderer ownership, process lifetime, and pane-close teardown | partial; audited pair exists and explicit app-quit process-tree teardown remains open | T-015, T-035, T-040, T-044, T-084 |
| `TENON-PRD-010` | [`plugin-runtime`](plugin-runtime.prd.md) ([Gherkin](plugin-runtime.feature)) | discovery, manifests, low-friction installation permission policy, trust, capabilities, built-ins, events, resource lifetime, hot reload, logs, and user-plugin placement | partial; simplified local enable/authority review, hard OS isolation, and process-stream descendant containment remain open | T-017, T-018, T-021, T-033, T-037, T-049, T-053, T-062, T-080, T-093, T-130 |
| `TENON-PRD-011` | [`interaction-architecture`](interaction-architecture.prd.md) ([Gherkin](interaction-architecture.feature)) | deterministic interaction classification, intent kernel, two-way communication, DIRECT gates, public inventories, and change protocol | shipped and normative; canonical pair preserves the ordered law and current exact inventories | T-020, T-042, T-078 |
| `TENON-PRD-012` | [`agent-lens`](agent-lens.prd.md) ([Gherkin](agent-lens.feature)) | agent-session discovery, evidence projection, markdown/links, hook-first ingestion, explicit view choice, fleet supervision, and AI milestone timeline | partial; live snapshot readability now re-evaluates while open, while real-provider, link-click, and assembled GUI receipts remain open | T-013, T-048, T-067, T-068, T-069, T-075, T-089, T-102 |
| `TENON-PRD-013` | [`automations`](automations.prd.md) ([Gherkin](automations.feature)) | durable schedules, single-file scripts, visibility/history, Run Now, AI-assisted authoring, and supervised agent fleets | partial; audited pair exists, while installed Canvas/authoring and true-provider fast-command evidence remain open | T-046, T-047, T-060, T-061 |
| `TENON-PRD-014` | [`kanban`](kanban.prd.md) ([Gherkin](kanban.feature)) | bundled board discovery, large-board reads, column/card rendering, moves, modal run tracking, and fixed horizontal layout | shipped; canonical pair maps current plugin, 30 focused tests, mutation proofs, and visual receipts | T-041, T-052, T-055, T-066 |
| `TENON-PRD-015` | [`engineering-quality`](engineering-quality.prd.md) ([Gherkin](engineering-quality.feature)) | build-cache hygiene, test-layer evidence, flake control, domain tags, native interaction verification, accessibility/localization remediation, and coordinator decomposition | partial; shipped quality system is mapped while the remaining native-interaction decision/spikes remain planned | T-023, T-043, T-074, T-082, T-090, T-094, T-095 |
| `TENON-PRD-016` | [`diagnostics-and-resource-monitor`](diagnostics-and-resource-monitor.prd.md) ([Gherkin](diagnostics-and-resource-monitor.feature)) | local health journal, stall/memory evidence, privacy boundary, and planned Chrome-style process resource monitor | partial; bounded diagnostics ship while signed-app feasibility and the read-only Resource Monitor remain planned | T-092, T-100 |
| `TENON-PRD-017` | [`agent-control`](agent-control.prd.md) ([Gherkin](agent-control.feature)) | agent inventory and command composition, power-first progressive trust, bounded public agent identity/state, workspace aliases, explicit-pane start, queued/atomic prompts, structured provider response, finite lifecycle waits, and programmatic coordination across plugin/CLI/agent principals | partial; `agent.inventory.v1`/`agent.command.v1` shipped with cross-agent handoff and both shipped plugins rewired, while provider lifecycle/interaction characterization and the seven coordination contracts remain planned | T-104; source research plus PRD-007/009/012/013 |

## Task coverage audit

Every task from T-001 through T-103 appears exactly once in the canonical PRD set. A task
record is evidence and history, not the canonical requirements document. “Done” in the
Kanban board is treated as an implementation claim until the owning PRD maps each requirement
to current source and relevant tests.

| Board state observed 2026-08-09 | Tasks |
|---|---|
| Done | T-001…T-070; T-072…T-089; T-092…T-099; T-102, subject to current-source audit |
| Doing | T-071, T-101, T-103 |
| Blocked/partial | T-091 |
| Backlog/planned | T-090, T-100 |

## Source-discovered feature coverage

The task archive is not exhaustive. These shipped surfaces were found in current source or
bundled manifests and must be specified even though they have no standalone task card.

| Source feature | Canonical PRD | Current evidence |
|---|---|---|
| Copy raw Tab UUID from the tab launcher and accessibility action | PRD-002 | `LauncherMenu`, `ShellTitleBar`, interaction fitness and XCUITest |
| Copy raw Pane UUID from pane chrome/context menu | PRD-003 | spatial canvas/card source and hosted interaction tests |
| A tab strip surface that answers `mouseDownCanMoveWindow` for the chips, so a title-bar drag reorders instead of moving the window | PRD-002 | `TabStripSurface`, `TabReorder.press`, `WindowChrome`, focused UI tests |
| Empty titlebar area explicitly drags the window | PRD-001/002 | `WindowDragArea` and focused UI test |
| bundled Clock schedule/status example | PRD-013/010 | `plugins/clock` manifest and runtime tests |
| bundled Hello Palette example intents | PRD-002/010 | `plugins/hello-palette` manifest and palette/runtime tests |
| bundled View Gallery native vocabulary example | PRD-005 | `plugins/view-gallery` and snapshot/view tests |
| bundled Workspace Status contribution | PRD-001/005 | `plugins/workspace-status` and contribution tests |
| current `SlotContent` inventory after the retirement of the redundant docs pane: terminal, changes, automation, file, plugin view, diff, empty; saved state naming a retired kind degrades fail-soft | PRD-003/008/009/013 | `Sources/TenonCore/Workspace.swift`; T-103 shipped 2026-08-09 |
| all versioned core intents in `CoreIntentName` | PRD-006…011 as semantically owned; exhaustive inventory remains PRD-011 | `Sources/TenonCore/CoreIntentCatalog.swift` and catalog fitness tests |
| Herdr-informed semantic agent control gap: list/get/start/rename/prompt/respond/wait with progressive standing trust | PRD-017, with full rich-evidence history retained by PRD-012 and schedule/fleet composition retained by PRD-013 | `references/herdr` source audit; Tenon implementation is planned |

## Legacy documentation ownership

Existing documents remain authoritative until their replacement PRD and Gherkin file pass
review. Then the old file is either reduced to a compatibility pointer or retained as clearly
labelled historical evidence; it is never silently deleted.

| Existing document | Canonical owner |
|---|---|
| `VISION.md`, `docs/competitive-landscape.md`, `docs/research-human-agent-supervision.md`, `docs/naming.md` | PRD-000 |
| `docs/design-command-palette.md` | PRD-002 |
| `docs/design-pane-slots.md`, `docs/design-pane-header.md`, `docs/design-pane-hosting.md` | PRD-003 |
| `docs/design-plugin-settings.md` | PRD-004, with runtime constraints in PRD-010 |
| `docs/design-plugin-views.md`, `docs/design-plugin-view-instances.md` | PRD-005 |
| `docs/design-open-handlers.md` | PRD-006 |
| `docs/design-cli.md` | PRD-007 |
| `docs/design-editor.md`, `docs/design-terminal-teardown.md` | PRD-008 and PRD-009 respectively |
| `docs/design-plugin-builtins.md`, `docs/design-plugin-host-capabilities.md`, `docs/plugin-author-guide.md`, `docs/plugin-migration-v0.2.md`, `docs/research-plugin-runtimes.md`, `docs/research-reference-terminals.md` | PRD-010, with historical research preserved |
| `docs/architecture-interaction-boundaries.md`, `docs/design-intent-bus.md` | PRD-011; normative source remains intact unless the reviewed replacement explicitly assumes authority |
| `docs/design-agent-lens.md` and the Agent Lens generated report | PRD-012 |
| `docs/design-automations.md` | PRD-013 |
| `docs/design-diagnostics.md`, process-resource-monitor spec | PRD-016 |
| `docs/designs.md`, `docs/domains.md`, `docs/development.md`, `docs/operations.md`, `docs/tdd.md`, system/code/architecture review reports, and `Tests/TenonUITests/README.md` | PRD-015 as cross-cutting constraints/evidence; normative sources remain intact |
| `docs/README.md` | this catalog becomes its PRD/Gherkin coverage source; the existing page remains the broad documentation entry point |

Generated HTML reports, `CHANGELOG.md`, agent instruction files, and Kanban/remember archives
are immutable evidence or control artifacts, not product requirements. They must be linked
from an owning PRD but are not rewritten as if they were current requirements.

## Traceability contract

1. PRD IDs are stable and never reused.
2. Functional requirements use `<SLUG>-FR-###`; non-functional requirements use
   `<SLUG>-NFR-###`.
3. Every Gherkin file carries `@prd-TENON_PRD_NNN` and every scenario carries one or more
   lowercase `@req-<requirement-id>` tags.
4. Every shipped requirement maps to current source and at least one evidence seam. The seam
   may be pure core, hosted AppKit/SwiftUI, XCUITest, integration, performance, visual/manual,
   or a combination justified by the requirement.
5. A scenario describes observable behavior. XCTest names and implementation symbols belong
   in the PRD's delivery matrix, not in Given/When/Then prose.
6. A historical task outcome that disagrees with current source is marked superseded in the
   PRD decision log. Current source plus current tests win.

## Migration order

1. PRD-002 command surfaces — closes the active context drift around launcher, Copy Tab ID,
   and tab reorder/window drag.
2. PRD-001 and PRD-003 — shell/workspaces and spatial panes establish the host interaction
   foundation.
3. PRD-008 and PRD-009 — files/content and terminal lifecycle.
4. PRD-005, PRD-010, and PRD-011 — plugin UI, runtime, and interaction architecture.
5. PRD-006, PRD-007, PRD-012, PRD-013, PRD-014, and PRD-017 — browser/open, CLI,
   Agent Lens, automations, Kanban, and semantic agent control.
6. PRD-000, PRD-004, PRD-015, and PRD-016 — product direction, settings, quality, and
   diagnostics/planned resource monitor.

The migration is complete only when all 18 PRDs and all 18 Gherkin files exist, parse, cover
their mapped tasks/source features, and their delivery matrices have been audited against the
current tree.
