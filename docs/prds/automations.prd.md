# PRD — Durable automations, operations Canvas, AI authoring, and agent fleets

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-013` |
| Lifecycle | `partial` |
| Owner | automation, plugin-host, plugin-runtime, intent-bus, and terminal-surface domains |
| Reviewers | product, native UI, accessibility, security, runtime, operations, test |
| Created / reviewed | 2026-08-09 |
| Related work | T-046, T-047, T-048, T-060, T-061 |
| Existing design | [`design-automations.md`](../design-automations.md) |
| Acceptance specification | [`automations.feature`](automations.feature) |

## 1. Executive summary

### Problem and outcome

A prompt pasted into one scheduled TUI cannot express reliable branching, data flow, retries,
parallelism, or inspectable authority. Tenon instead makes an automation ordinary plugin
JavaScript plus host-owned wall-clock scheduling. Scripts retain the same manifest, principal,
permissions, intents, isolation, hot reload, and consent as every plugin; the host contributes
only durable-in-generation schedule computation and owner-scoped firing facts.

The Automation Canvas makes declarations, next due, pause state, Run Now, and bounded delivery
history visible. A single `.js` file can carry its manifest at the top. “Create with AI” opens a
fresh terminal tab at the real user-plugin root with a safely quoted guide. `tenon.agents.run`
composes visible terminal panes, finite waits, and paged scrollback for supervised fleets.

Current scheduling and UI are shipped, but this PRD remains partial until the installed Canvas/
authoring workflow and the true-provider fast-command wait race are observed. Cross-restart
catch-up and unattended implicit terminal scope are explicit non-goals, not hidden claims.

## 2. Discovery, users, and jobs

| Evidence | Source | Confidence |
|---|---|---|
| schedule/runtime design | [`design-automations.md`](../design-automations.md) | high after source-backed task updates |
| scheduler/history | [`AutomationScheduler.swift`](../../Sources/TenonCore/AutomationScheduler.swift), [`AutomationRunHistory.swift`](../../Sources/TenonCore/AutomationRunHistory.swift) | high |
| Canvas/authoring | [`AutomationSlotView.swift`](../../Sources/TenonApp/AutomationSlotView.swift), [`AutomationAuthoring.swift`](../../Sources/TenonApp/AutomationAuthoring.swift) | high |
| plugin/runtime | manifest loader, `PluginRuntimeBootstrap`, `plugins/core-commands` | high |
| tests/examples | Automation/AgentsRun/Fleet suites, `examples/fleet-review` | high for headless composition |

Primary users are operators who want scheduled or manual workflows beside the terminals they
supervise, and authors/agents who need the smallest safe script format. They need to see what is
eligible, trigger and verify it, understand delivery rather than guessed business success, pause
without deleting declarations, and fan work into visible agent panes.

| Term | Meaning | Not to be confused with |
|---|---|---|
| automation | plugin JavaScript reacting to a firing EVENT | a host-owned prompt string |
| firing | delivery attempt fact | business success/run completion |
| scheduledFor | occurrence represented by the fact | actual delivery time |
| Run Now | manual firing through the same emit site | schedule phase change |
| pause | host policy suppressing scheduled delivery | plugin disable/uninstall |

Assumptions still needing installed observation: Canvas copy is understandable; AI authoring
produces a valid script without manual repair; arming wait immediately after terminal open closes
ordinary provider timing but may need a contract-level start gate for very fast commands.

## 3. Goals, measures, scope, and bounds

- `AU-G-001` — Real JavaScript expresses workflows while one policy path owns authority.
- `AU-G-002` — Wall-clock schedules are deterministic across tick/reload/pause behavior.
- `AU-G-003` — Operators can inspect, run, pause, and verify delivery in workspace context.
- `AU-G-004` — AI authoring and agent fleets remain safely quoted, bounded composition.

Targets: zero duplicate firing at one instant; zero authority from schedule declaration; zero
manual runs shifting phase; history capacity exactly 128 newest-first; at most 8 schedules per
plugin; cadence 1 minute…7 days; 256 outbound intents per generation; agent wait slices at most
55 seconds under an overall default 10-minute budget; scrollback invalidation may restart once.

In scope: manifest schedules, scheduler/event/reconcile, global/per-schedule pause, Canvas,
history/Run Now, single-file plugins, user inventory, AI authoring, `tenon.agents.run`, fleet
example. Non-goals: host business-success inference, cross-restart catch-up, silent headless
terminal selection, log deep link before a log product exists, built-in prompt DSL, installing
the fleet demo by default.

## 4. User experience

The launcher opens Automation Canvas as workspace content. Summary shows active count, next
eligible firing, attention, and delivered/attempted recent ratio. A stable navigator supports
search and All/Attention/Paused filters; the inspector shows exact plugin/schedule identity,
cadence, due, grace, availability, and recent delivery. Global enablement pauses scheduled
delivery only. Per-row Pause advances occurrences without replay. Run Now remains available and
does not alter nextDue.

Create with AI closes Settings and focuses a new terminal tab rooted at the writable user-plugin
inventory. Claude receives one POSIX-quoted prompt teaching the exact leading manifest header,
schedule/event schema, real path, intent discovery, consent, and Run Now verification. Saved
scripts hot reload. Fleet scripts use `Promise.all(tenon.agents.run(...))`; each agent remains a
visible pane and returns bounded transcript evidence.

## 5. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `AU-FR-001` | An automation **MUST** be ordinary plugin JavaScript with the same manifest, principal, grants, intents, isolation, and reload lifecycle. | shipped | `@req-au-fr-001` |
| `AU-FR-002` | Manifest schedules **MUST** be CONTRIBUTION state and firing **MUST** be owner-scoped `automation.fired` EVENT; actions **MUST** use existing intents. | shipped | `@req-au-fr-002` |
| `AU-FR-003` | A schedule **MUST** have a unique 1…64-byte ID and exactly one valid `every` or local-time `daily`; each plugin **MUST** declare at most 8. | shipped | `@req-au-fr-003` |
| `AU-FR-004` | `every` **MUST** accept 1m…7d and `daily` zero-padded `HH:mm`; grace **MUST** accept 1m…7d with documented defaults. | shipped | `@req-au-fr-004` |
| `AU-FR-005` | A tick **MUST** fire at most the latest in-grace missed occurrence, skip staler misses, rearm from now, and never duplicate one instant. | shipped | `@req-au-fr-005` |
| `AU-FR-006` | Firing payload **MUST** include scheduleId, ISO scheduledFor, lateness over two minutes, and scheduled/manual trigger. | shipped | `@req-au-fr-006` |
| `AU-FR-007` | Reconcile **MUST** preserve phase for unchanged specs, recompute changed specs, schedule only loaded/enabled plugins, and drop delivery to retired sessions. | shipped | `@req-au-fr-007` |
| `AU-FR-008` | Naming a schedule **MUST NOT** grant authority; every subsequent action **MUST** pass declared-use, capability, policy, consent, and deadline. | shipped | `@req-au-fr-008` |
| `AU-FR-009` | Global enablement **MUST** persist, default on for older preferences, suppress scheduled delivery without unloading plugins, and leave Run Now available. | shipped | `@req-au-fr-009` |
| `AU-FR-010` | Per-schedule pause **MUST** persist across reload/disable/relaunch, advance due occurrences without delivery/replay, and remain manually runnable. | shipped | `@req-au-fr-010` |
| `AU-FR-011` | Canvas **MUST** show summary, stable searchable/filterable declarations, attention/availability, exact inspector, and recent activity. | shipped | `@req-au-fr-011` |
| `AU-FR-012` | Disabled plugin schedules **MUST** leave Canvas; unloaded/failed enabled declarations **MUST** remain visible as anomalies. | shipped | `@req-au-fr-012` |
| `AU-FR-013` | Run Now **MUST** mint one manual firing through the scheduled emit site and **MUST NOT** change schedule phase. | shipped | `@req-au-fr-013` |
| `AU-FR-014` | Run history **MUST** record at delivery, remain newest-first/capacity 128 across reconcile, and carry exact fact plus delivered/dropped outcome. | shipped | `@req-au-fr-014` |
| `AU-FR-015` | UI **MUST** call scheduler/host typed services DIRECT; launcher metadata may invoke the plugin-owned automation-open intent without adding a core intent. | shipped | `@req-au-fr-015` |
| `AU-FR-016` | A top-level `.js` with a valid opening manifest header **MUST** load/reload/retire exactly like a directory plugin through the same decoder. | shipped | `@req-au-fr-016` |
| `AU-FR-017` | Malformed claimed headers **MUST** fail with file diagnostics; plain `.js` without a header **MUST** be ignored; mixed identity rules **MUST** remain exact. | shipped | `@req-au-fr-017` |
| `AU-FR-018` | Authored automations **MUST** live in the writable user inventory; bundle inventory **MUST** remain sealed and win identity clashes without granting trust to user code. | shipped | `@req-au-fr-018` |
| `AU-FR-019` | Create with AI **MUST** open/focus a fresh terminal tab at the real writable inventory and close the obscuring Settings window. | shipped/headless | `@req-au-fr-019` |
| `AU-FR-020` | The guide **MUST** teach the exact header, schedule/event grammar, real root, CLI discovery, consent, smallest-script interview, and Run Now verification. | shipped | `@req-au-fr-020` |
| `AU-FR-021` | Claude plus the complete guide **MUST** cross the shell as one POSIX-quoted argument resistant to quotes, substitutions, backticks, spaces, and newlines. | shipped | `@req-au-fr-021` |
| `AU-FR-022` | `tenon.agents.run` **MUST** be caller-local JavaScript composition over terminal open, wait, and scrollback intents with no broker authority. | shipped | `@req-au-fr-022` |
| `AU-FR-023` | Agent command/arguments **MUST** be quoted per token and run in a visible pane; success **MUST** return pane ID and transcript. | shipped | `@req-au-fr-023` |
| `AU-FR-024` | Agent wait **MUST** arm immediately, repeat bounded slices under total budget, return typed timeout, and respect handler-call deadline/cancellation when supplied. | partial | `@req-au-fr-024` |
| `AU-FR-025` | Scrollback **MUST** page to completion; one invalidation **MUST** restart cleanly and a second **MUST** fail typed without mixed transcript. | shipped | `@req-au-fr-025` |
| `AU-FR-026` | `Promise.all`, pipelines, loops, conditions, and retries **MUST** remain ordinary JS under generation outbound-intent bounds. | shipped | `@req-au-fr-026` |
| `AU-FR-027` | The fleet-review example **MUST** remain opt-in, executable in tests, launch three supervised panes, aggregate transcripts, and publish one verdict. | shipped/headless | `@req-au-fr-027` |
| `AU-FR-028` | Installed verification **MUST** cover Canvas pixels, Run Now/history, AI-authored working script, and a true-provider command that may finish before wait arms. | planned verification | `@req-au-fr-028` |
| `AU-FR-029` | A run in Canvas recent activity **MUST** lead to its owning plugin's own registered shared view, placed through typed workspace services DIRECT on that selection alone; a run whose plugin registers no shared view **MUST** present as evidence rather than as a control. | shipped | `@req-au-fr-029` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `AU-NFR-001` | determinism | Time **MUST** enter scheduler as a parameter; same state/now/reconcile inputs produce the same firings. | shipped | `@req-au-nfr-001` |
| `AU-NFR-002` | boundedness | Schedule, history, outbound-intent, wait, scrollback, payload, and process lifetimes **MUST** enforce stated bounds. | shipped | `@req-au-nfr-002` |
| `AU-NFR-003` | security | User-authored code **MUST** start untrusted; inventory placement, schedule, manual trigger, or AI authorship **MUST NOT** grant authority. | shipped | `@req-au-nfr-003` |
| `AU-NFR-004` | lifecycle | Disable/reload/uninstall/policy epoch changes **MUST** prevent stale batches from entering retired contexts. | shipped | `@req-au-nfr-004` |
| `AU-NFR-005` | design/accessibility | Canvas/Settings **MUST** use native Tenon tokens, keyboard/VoiceOver paths, non-color state, and bounded density. | partial visual | `@req-au-nfr-005` |
| `AU-NFR-006` | evidence | UI **MUST** say attempted/delivered and Recent, never infer business success or completeness beyond retained history. | shipped | `@req-au-nfr-006` |
| `AU-NFR-007` | architecture | Zero schedule-specific public `tenon` members/core intents; mechanisms **MUST** keep CONTRIBUTION/EVENT/DIRECT/INTENT classifications. | shipped | `@req-au-nfr-007` |
| `AU-NFR-008` | verification | Headless tests/mutations **MUST** be complemented by installed interaction and true-provider receipts. | partial | `@req-au-nfr-008` |
| `AU-NFR-009` | attention | A firing **MUST NOT** place, focus, or raise a surface on its own; a script with something a human must clear **MUST** carry it on a channel that costs nothing to ignore, and panes a script opens through its own declared terminal intents remain its visible supervised panes rather than host-directed navigation. | partial: the shipped inventory obeys it; the host does not yet refuse a firing that disobeys | `@req-au-nfr-009` |

## 6. Acceptance, architecture, and ownership

[`automations.feature`](automations.feature) maps all 38 requirements. Schedule declaration is
CONTRIBUTION; firing EVENT; UI/scheduler state DIRECT; script actions INTENT; timers/watchers and
agent supervision use existing RESOURCE lifetimes. Scheduler owns nextDue, pause epochs, and
history; PluginHost owns delivery; plugin runtime owns script generation; workspace/terminal
services own authoring/fleet panes. No app principal or automation capability API is introduced.

## 7. Delivery matrix, risks, and decisions

| Requirements | Evidence | State/gap |
|---|---|---|
| 001…018 | manifest/scheduler/host/history/loader suites | shipped |
| 019…021 | authoring pure tests and composition | shipped; installed flow owed |
| 022…027 | AgentsRun/fleet integration/example | shipped headlessly; fast-provider race owed |
| 028 and NFR-005/008 | human checklist | pending |
| 029 and NFR-009 | run-detail projection and row control suites; installed inventory read | shipped; host refusal of a self-opening firing not attempted |

Risks: calling delivery success; authority laundering through a broker; replay after pause; shell
injection; wait missing an ultra-fast completion. Mitigations are exact UI vocabulary, caller-
local composition, phase advancement, per-token quoting, and the pending true-provider test/start-
gate decision.

Decisions: local machine time with no dead timezone metadata; manual run never shifts phase;
single-file header must open the file; user inventory is durable/untrusted; `agents.run` is a
runtime function rather than broker intent; cross-restart catch-up is unimplemented and excluded.

2026-08-11, T-125 — a run leads to the panel; the panel does not come to the operator. Three
installed plugins were opening a pane from inside their own `automation.fired` handler, so a
five-minute schedule could take the screen from work in progress. The recorded non-goal *"log
deep link before a log product exists"* stands: `AU-FR-029` navigates to a view the plugin has
already contributed and invents no log surface. Host enforcement of `AU-NFR-009` was considered
and deliberately not taken — refusing `workspace.content.open.v1` inside a firing would also
remove a script's ability to raise something genuinely urgent, and that trade needs a real case
before the boundary decides it. The rule is therefore stated here and kept by the inventory, not
by the dispatcher; a firing that disobeys it is a bug in the plugin, findable by reading its
handler. The signal those panes carried moved to `tenon.statusBar.set`, which is in the
permission-free tier and costs nothing to ignore.

## 8. Verification and change history

| Date | Worktree | Result | Exclusions |
|---|---|---|---|
| 2026-08-09 | current dirty tree, docs audit | current design/source/tasks/tests reconciled | installed Canvas/authoring and true-provider fast command not run |
| 2026-08-11 | current dirty tree, T-125 | `AU-FR-029` and `AU-NFR-009` landed; automation suite green, run-detail projection and row control asserted headlessly; the three installed plugins parse and hold no pane-opening send or `workspace.control` permission | the row was not clicked in a running app; no installed screenshot; the host still permits a firing to open a pane |

Initial canonical PRD created 2026-08-09 to preserve the complete automation product and its
remaining verification boundary.
