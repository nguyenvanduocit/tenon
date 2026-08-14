# PRD — Workspace Kanban board, safe card moves, and agent-run supervision

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-014` |
| Lifecycle | `shipped` |
| Owner | bundled `dev.tenon.kanban` plugin; plugin-ui, filesystem-intent, terminal, and workspace boundaries |
| Reviewers | product, plugin UI, accessibility, filesystem safety, terminal/agent, performance, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-041, T-052, T-055, T-066 |
| Acceptance specification | [`kanban.feature`](kanban.feature) |

## 1. Executive summary

### Problem

Tenon's `.kanban/board.md` is shared coordination state for people and agents, but the source format
alone is slow to scan and unsafe to mutate casually. The real board exceeds one inline filesystem
page, Done grows without limit, multiple writers can change it during a read or move, and a partial
rewrite would corrupt the coordination record. Earlier list/tree rendering also failed the actual
visual job: columns collapsed or squeezed, cards floated vertically, and controls truncated.

Starting an agent from a task creates another supervision problem. Opening a terminal is insufficient
if the board cannot show which pane owns the run, whether it exited, what it is doing now, and how to
return to it without retaining unbounded scrollback or background polling after the detail closes.

### Proposed outcome

The bundled Kanban plugin discovers the board belonging to each pane's owning workspace, reads it
through bounded invalidation-aware pages, and renders native fixed 260-point columns in a horizontal
scroller. Cards expose clipped identity/title/meta, adjacent move buttons, same-instance drag/drop,
and More. More opens a window-level modal with current task-file details and a bounded live view of
an agent pane started for that task.

Every move re-reads the current board, relocates exactly the rendered task line, and atomically
commits bounded pages so other bytes and concurrent edits survive. Per-pane serialization, stale-
read suppression, explicit failures, watch debounce, and teardown make the feature safe under
multi-agent use. The entire product feature remains a plugin: UI is CONTRIBUTION, board changes are
EVENT, watching/timing are RESOURCE, and finite filesystem/workspace/terminal work is INTENT.

### Why now

The four historical tasks are complete but their contract is scattered across a 946-line plugin,
2,000+ lines of focused tests, host plugin-UI designs, mutation notes, and visual receipts. This pair
records the current implementation—not the superseded inline-detail/list layout—so future UI or
filesystem changes cannot make the board unreadable, regress large-board support, or remove keyboard
move controls while retaining pointer drag.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| shipped manifest/source | [`plugins/kanban`](../../plugins/kanban/) | high | current declarations, bounds, parsing, rendering, move/run lifecycle |
| focused tests | `KanbanPluginTests`, plugin view/drag/modal tests | high | 30 current end-to-end headless contracts and mutation seams |
| filesystem paging | filesystem provider/catalog tests, T-052/T-055 | high | invalidation-aware reads and staged atomic writes |
| visual evidence | T-055/T-066 receipts and plugin snapshot infrastructure | medium/high | fixed columns, horizontal overflow, modal geometry |
| task history | T-041/T-052/T-055/T-066 | medium | intended outcome and superseded list/inline-detail shapes |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Make a shared agent board readable, safely movable, and useful for supervising work without host-specific Kanban code. |
| Primary users? | people and agents coordinating work in a workspace that follows aio-kanban v3 files |
| Success? | correct workspace board, readable columns, atomic exact moves, honest errors, accessible input parity, bounded live run status |
| Fixed constraints? | plugin-only feature, owning-workspace scope, current board/task format, central plugin UI and intent boundaries |
| Unknown? | no current Kanban feature gap; `filesystem.file.write.v1` major-version debt is owned by PRD-008 and must not be hidden here |

## 3. Users, jobs, and vocabulary

The primary user coordinates tasks across human and AI workers. They need to scan column load,
inspect criteria, move a card without erasing another writer's update, start an agent in a real PTY,
and return to that run. Plugin/runtime engineers need this feature to prove that the public plugin
boundaries are sufficient without bespoke host Kanban APIs.

- See the board for the workspace that owns this pane, even while another workspace is selected.
- Move a card by pointer, keyboard, or VoiceOver with one safe relocation algorithm.
- Distinguish a missing board from a failed or invalidated read/write.
- Inspect task details and current agent output without loading an entire growing transcript.
- Close/move/reload panes without orphaning watchers, timers, or stale publications.

| Term | Meaning | Not to be confused with |
|---|---|---|
| board | `<owning workspace>/.kanban/board.md` | current global workspace selection |
| task file | relative link stored on a board task line | the board line itself |
| column | non-empty `## <name>` section | malformed bare `## ` stub |
| move | verbatim relocation of the first rendered task line | rewriting parsed/normalized board content |
| run | agent terminal pane started from one task in one Kanban instance | modal/polling lifetime |

## 4. Goals, measures, scope, and bounds

- `KAN-G-001` — Every instance follows its owning workspace board independently.
- `KAN-G-002` — Large, concurrently edited boards remain readable and atomically movable.
- `KAN-G-003` — Fixed native columns and bounded cards remain scannable at any pane width.
- `KAN-G-004` — Agent launch and current activity are visible without unbounded polling/storage.
- `KAN-G-005` — The feature proves existing plugin boundaries are sufficient.

Targets: zero cross-workspace board leakage; zero partial board writes; one disk change per committed
move; no write for same-column drop; deterministic rapid move order; one watcher per pane board;
one debounced refresh per burst; zero watcher/timer callbacks after close; exact button/drag move
parity; representative real-host visual evidence for layout changes.

Current bounds: 12 rendered cards/column; label 160, card title 96, meta 24 characters; 12 criteria;
260-point columns; 24 read pages of up to host inline size with 3 invalidation restarts; 21 write
pages ×48 KiB (<1 MiB); 4 queued moves; 250 ms watch debounce; 1.2 s open-modal tracking tick;
15 non-empty tail lines ×160 characters.

In scope: board/task parsing, large reads, watch refresh, native board rendering, task modal,
terminal start/tracking/focus, pointer/button moves, atomic staged writes, workspace rebinding, errors,
and teardown. Non-goals: editing arbitrary task fields, creating/deleting cards, assigning owners,
server collaboration/merge, cross-pane drag, retaining full scrollback, background tracking with no
open modal, or host-native Kanban-specific Swift code.

## 5. User experience

The launcher/palette invokes plugin-owned `dev.tenon.kanban.open.v1`, which fills a pane with the
instanced board view. The header shows the resolved board path. A horizontal scroller contains fixed
columns with name/count, bounded cards, and an overflow count. Each card has More plus only valid
left/right buttons and is draggable to any column in that same plugin/view/instance. Buttons remain
the keyboard and VoiceOver route.

More opens one host-native sheet. It re-reads task details, shows description, priority/effort and
criteria, then either Start or the run's state, pane ID, output tail, Focus pane, and Start again.
Dismissal closes only the sheet. A live run remains associated with that task/instance and resumes
tracking when reopened; polling exists only while the sheet is open.

Missing board is stated as missing. Permission, paging, content-shape, invalidation, relocation, and
write failures are named in-pane; after a move outcome the pane refreshes from disk. Host-native UI
uses the shared plugin components and Tenon design system.

## 6. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `KAN-FR-001` | The bundled plugin **MUST** register one instanced `board` view and a plugin-owned open intent projected to palette and launcher with pane-filling metadata. | shipped | `@req-kan-fr-001` |
| `KAN-FR-002` | Each view instance **MUST** resolve its owning workspace through `workspace.pane.owner.v1`; selected workspace **MUST NOT** determine its board. | shipped | `@req-kan-fr-002` |
| `KAN-FR-003` | The board path **MUST** be `<owning workspace>/.kanban/board.md`, and the pane header **MUST** expose that resolved path. | shipped | `@req-kan-fr-003` |
| `KAN-FR-004` | The parser **MUST** treat only non-empty `##` headings as columns and parse `- [T-n](path) title/meta` task lines under the current column. | shipped | `@req-kan-fr-004` |
| `KAN-FR-005` | Task title/meta **MUST** split at the first ` — ` and discard later status segments from display; task files **MUST** parse description, priority/effort, and criteria state. | shipped | `@req-kan-fr-005` |
| `KAN-FR-006` | Malformed lines/headings/task content **MUST** fail soft so valid surrounding columns/cards/details remain visible. | shipped | `@req-kan-fr-006` |
| `KAN-FR-007` | Board/task reads **MUST** follow at most 24 bounded inline pages, restart at most 3 times after invalidation, and reject unexpected content shape or endless growth explicitly. | shipped | `@req-kan-fr-007` |
| `KAN-FR-008` | Only path-not-found **MUST** render “No board”; every other read failure **MUST** render its reason. | shipped | `@req-kan-fr-008` |
| `KAN-FR-009` | A refresh **MUST** publish only if its pane still exists and generation is newest; stale reads **MUST NOT** overwrite current state. | shipped | `@req-kan-fr-009` |
| `KAN-FR-010` | A real board-content change **MUST** emit owner-qualified `board.changed`; unrelated watch events or identical content **MUST NOT** emit it. | shipped | `@req-kan-fr-010` |
| `KAN-FR-011` | Each instance **MUST** own one `.kanban` watcher and 250 ms debounce; bursts **MUST** coalesce and rebinding **MUST** replace the old watcher. | shipped | `@req-kan-fr-011` |
| `KAN-FR-012` | Workspace-owner change **MUST** rebind path/watch/state, close old detail/run tracking, and load the new board without changing other instances. | shipped | `@req-kan-fr-012` |
| `KAN-FR-013` | The board **MUST** render native 260-point column boxes in one horizontal scroll row; columns **MUST NOT** shrink to share pane width. | shipped | `@req-kan-fr-013` |
| `KAN-FR-014` | Each column **MUST** show name/count, pin cards to the top, fill row height, and remain a full drop target including empty space. | shipped | `@req-kan-fr-014` |
| `KAN-FR-015` | Rendering **MUST** cap each column at 12 cards and name the remaining count; all labels/title/meta/criteria **MUST** use the documented bounds. | shipped | `@req-kan-fr-015` |
| `KAN-FR-016` | Each card **MUST** show task ID, clipped title and metadata, More, valid adjacent move buttons, and a same-instance drag source. | shipped | `@req-kan-fr-016` |
| `KAN-FR-017` | More **MUST** open a window-level plugin modal while leaving the card layout unchanged; inline detail expansion **MUST NOT** coexist. | shipped | `@req-kan-fr-017` |
| `KAN-FR-018` | Opening detail **MUST** refresh the board then read the currently linked task file and display bounded description/priority/effort/criteria; a disappeared task **MUST** close detail. | shipped | `@req-kan-fr-018` |
| `KAN-FR-019` | Escape, backdrop, close control, or dismiss action **MUST** close the plugin-owned modal through one select callback. | shipped | `@req-kan-fr-019` |
| `KAN-FR-020` | Start **MUST** invoke `terminal.open.v1` in the owning workspace with a task/CLAUDE workflow prompt and record only a valid returned pane ID; failure **MUST** remain visible in the modal/pane. | shipped | `@req-kan-fr-020` |
| `KAN-FR-021` | While a live run's modal is open, tracking **MUST** read that pane's bounded viewport every 1.2 seconds and show running/exited, pane ID, and at most 15 clipped non-empty tail lines. | shipped | `@req-kan-fr-021` |
| `KAN-FR-022` | Dismissing detail **MUST** stop polling but **MUST NOT** close/forget the agent pane; reopening the task **MUST** resume its current run unless already exited. | shipped | `@req-kan-fr-022` |
| `KAN-FR-023` | Focus pane **MUST** invoke `workspace.pane.focus.v1` scoped to the exact recorded agent pane. | shipped | `@req-kan-fr-023` |
| `KAN-FR-024` | Left/right buttons **MUST** request one adjacent-column relocation and appear only when that adjacent destination exists. | shipped | `@req-kan-fr-024` |
| `KAN-FR-025` | Drag/drop **MUST** use the same move queue/relocation as buttons, admit only exact plugin/view/instance payloads, and allow every column including empty columns as a target. | shipped | `@req-kan-fr-025` |
| `KAN-FR-026` | A move **MUST** re-read the current board, relocate the first occurrence of the rendered task's verbatim line, preserve every other byte/line, and use the same heading predicate as rendering. | shipped | `@req-kan-fr-026` |
| `KAN-FR-027` | A same-column drop **MUST** be a no-op with no write/watch churn; an absent task or invalid adjacent/column target **MUST** fail visibly without mutation. | shipped | `@req-kan-fr-027` |
| `KAN-FR-028` | Moving into an empty column **MUST** insert directly under its heading; otherwise the line **MUST** append after that column's last task. | shipped | `@req-kan-fr-028` |
| `KAN-FR-029` | One pane **MUST** serialize at most four queued pointer/button moves so each re-reads the result committed by the preceding move. | shipped | `@req-kan-fr-029` |
| `KAN-FR-030` | A move **MUST** capture its board path once so a mid-operation workspace rebind cannot read one board and write another. | shipped | `@req-kan-fr-030` |
| `KAN-FR-031` | Writes **MUST** split UTF-8 on code-point boundaries into at most 21 ×48 KiB pages, use one call for small boards and cursor staging/one atomic final commit for large boards, and expose any lost/invalid cursor. | shipped; version debt in PRD-008 | `@req-kan-fr-031` |
| `KAN-FR-032` | Read, relocate, page, or commit failure **MUST** leave no partial target, show a bounded honest error, and refresh from disk to the actual final state. | shipped | `@req-kan-fr-032` |
| `KAN-FR-033` | Closing an instance or retiring its generation **MUST** cancel watcher, debounce timer, tracking timer, pending publication, and stale callbacks without affecting other instances or the agent pane. | shipped | `@req-kan-fr-033` |
| `KAN-FR-034` | The feature **MUST** use only declared current plugin surfaces: UI CONTRIBUTION, board EVENT, watcher/timer RESOURCE, pure path DIRECT, and canonical filesystem/workspace/terminal INTENTS. | shipped | `@req-kan-fr-034` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `KAN-NFR-001` | native design | Board, cards, badges, buttons, header, scroller, modal, status, and errors **MUST** use shared Tenon plugin UI/design tokens with no local CSS/native object. | shipped | `@req-kan-nfr-001` |
| `KAN-NFR-002` | accessibility | Every move/start/focus/detail/dismiss action **MUST** have keyboard and VoiceOver parity; drag **MUST NOT** be the sole move route and state **MUST NOT** rely only on color. | shipped/continuous | `@req-kan-nfr-002` |
| `KAN-NFR-003` | boundedness | Board snapshots, labels, cards, criteria, pages, restarts, queued moves, watch events, timers, and viewport tail **MUST** obey the central finite bounds above. | shipped | `@req-kan-nfr-003` |
| `KAN-NFR-004` | reliability | Concurrent writers, stale reads, malformed lines, missing files, invalidated cursors, failed writes, and rebinding **MUST** preserve committed board data and expose the honest result. | shipped | `@req-kan-nfr-004` |
| `KAN-NFR-005` | concurrency | Refresh generations and per-pane move queues **MUST** make publication/mutation deterministic without cross-instance shared mutable state. | shipped | `@req-kan-nfr-005` |
| `KAN-NFR-006` | lifecycle | Watch, debounce, tracking, modal, run reference, pane instance, and plugin generation ownership **MUST** have explicit independent end conditions. | shipped | `@req-kan-nfr-006` |
| `KAN-NFR-007` | performance | Watch bursts **MUST** coalesce, hidden/closed modal **MUST NOT** poll, tracking **MUST** read viewport not full scrollback, and rendering **MUST** cap growing columns. | shipped | `@req-kan-nfr-007` |
| `KAN-NFR-008` | security | The plugin **MUST** receive no host/native object or implicit path authority; manifest declaration, capabilities, scope, and consent **MUST** gate every effect. | shipped | `@req-kan-nfr-008` |
| `KAN-NFR-009` | compatibility | aio-kanban v3 parsing **MUST** remain fail-soft; single-page behavior remains byte-compatible; the historical list/inline-detail layout remains superseded. | shipped | `@req-kan-nfr-009` |
| `KAN-NFR-010` | visual evidence | Layout-sensitive changes **MUST** include real-host offscreen/installed visual evidence in addition to tree-shape tests, covering narrow overflow, empty/tall columns, and modal. | shipped process | `@req-kan-nfr-010` |
| `KAN-NFR-011` | observability | Read/write/start/tracking/refusal errors **MUST** name the failed operation/reason in bounded text without claiming missing data when access failed. | shipped | `@req-kan-nfr-011` |

## 7. Acceptance and architecture

[`kanban.feature`](kanban.feature) maps all 45 requirements. Evidence includes shipped-plugin
manifest gates, pure parser/relocation assertions, real filesystem/intent paging, hosted runtime
view/modal/drag tests, real FSEvents lifecycle, mutation proofs, and visual receipts.

| Interaction | Classification | Constraint |
|---|---|---|
| view/header/modal/drag state | CONTRIBUTION | host validates/renders bounded values |
| select/submit/open/close and `board.changed` | EVENT | immutable owner facts, no reply |
| watch/timer | RESOURCE | instance/generation-owned and cancellable |
| path composition/local parse/relocate | DIRECT | pure plugin-local JavaScript |
| read/write/workspace/terminal | INTENT | declared finite public operations |

## 8. Delivery matrix, risks, and decisions

| Requirements | Source/evidence | State |
|---|---|---|
| 001…012 | manifest, instance lifecycle, parser/read/watch tests | shipped |
| 013…019 | native body/header/modal rendering and visual receipts | shipped; supersedes prior list/inline detail |
| 020…023 | terminal start/viewport/focus and run modal tests | shipped |
| 024…032 | button/drag relocation, queue, paging/atomic filesystem tests | shipped; write-v1 major debt owned by PRD-008 |
| 033…034 and NFR | resource teardown, shipped-surface/boundary/mutation/visual gates | shipped/continuous |

Risks are concurrent writers, stale page cursors, partial staged writes, moves crossing a workspace
rebind, cross-instance drag, unbounded Done/rendering, event storms, polling leaks, and shape tests
missing geometry. Fresh read-before-write, atomic staging, captured paths, exact drag scope, finite
bounds/debounce, instance teardown, and real-host snapshots mitigate them.

Decisions: workspace owner—not selected workspace—binds the board; malformed input fails soft;
columns are fixed width/horizontally scrolled; More uses one window-level modal and removes inline
detail; pointer drag and accessible buttons share one move; the first duplicated task occurrence is
the rendered/moved one; same-column drop writes nothing; live tracking exists only while detail is
open; the feature remains plugin-only.

**2026-08-14 — the board becomes a host-native surface (operator decision; supersedes "the
feature remains plugin-only" above, which governs until T-150 ships).** The operator stated
the product intent this rests on: the board is how Tenon organizes parallel workstreams for
its users, not a convention private to this repository. That makes the `host-native core:`
clause the interaction law requires citable and true — VISION.md:54-55 puts organizing
parallel workstreams by goal, delta, decision, blocker, evidence, freshness, and next action
in the product promise, and VISION.md:61-62 makes the supervisable-workstream count the
measure Tenon exists to raise.

Three cheaper justifications were tested against the tree first and refuted; they are recorded
so they are not re-offered. Drag/drop is not missing — `PluginViewNode.swift:63-66` ships
`dragSource`/`dropTarget` and `plugin-ui.prd.md:55` names Kanban as its consumer. "No plugin
presentation surface" is refuted by name in the law itself
(`architecture-interaction-boundaries.md:468-472`, citing this plugin's own modal). And
"heavy in JavaScript" measured false as a language claim: the weight is
`PluginRuntime.setViewBody` (`PluginRuntime.swift:1864-1893`) reparsing the whole
specification with no diff against the previous body, which a Swift plugin calling the same
contribution would pay identically — that defect is owned by T-151 and fixed for every plugin.

What the change buys is therefore stated narrowly: SwiftUI's own diffing with nothing
serialized across the boundary, and the ~375 lines of board parsing, task relocation, and
paged writes at `plugins/kanban/main.js:108-482` becoming Swift values testable without a
window. What it costs is that this plugin is today the most demanding proof the public
boundary carries a real feature; naming the replacement dogfood is a T-150 criterion.

Sequence is gated and recorded in T-150: VISION, then the law and the entry count at
`architecture-interaction-boundaries.md:443`, then the `DirectInventoryGateTests` pin, then
this PRD's requirements, then code. Requirement IDs for the native surface are written at that
fourth step rather than now, because they depend on the registry T-149 has yet to design.

## 9. Verification receipts and change history

| Date | Worktree | Result | Exclusions |
|---|---|---|---|
| T-055/T-066 delivery | historical accepted tree | offscreen native renders verified fixed columns, horizontal overflow, top-pinned cards, and modal/run layout; mutation restores byte-identical | snapshot probes were temporary; reusable snapshot capability is now PRD-005 |
| 2026-08-09 | current dirty tree, documentation audit | current 34 FR/11 NFR mapped to manifest, source, 30 Kanban tests and shared host tests | no board file or running Tenon process touched |

Initial canonical PRD created 2026-08-09 from the shipped implementation and accepted task receipts.
