# PRD — Terminal surfaces, automation intents, reading, and process lifetime

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-009` |
| Lifecycle | `partial` |
| Owner | terminal-surface, terminal-teardown, intent-bus, and workspace-model domains |
| Reviewers | product, native UI, accessibility, security, performance, process lifecycle, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-015, T-035, T-040, T-044, T-084 |
| Existing designs | [`design-terminal-teardown.md`](../design-terminal-teardown.md), [`architecture-interaction-boundaries.md`](../architecture-interaction-boundaries.md) |
| Acceptance specification | [`terminal.feature`](terminal.feature) |

## 1. Executive summary

### Problem

A Tenon terminal is simultaneously a native renderer, a live PTY/process tree, a focus and
keyboard target, a source of title/cwd/command facts, and a public automation surface. Its
lifetime must follow pane identity rather than SwiftUI view creation. A plugin must be able
to write, run, open, read, or wait without receiving a terminal object. Closing a pane must
stop the work it started, including process groups that libghostty's own SIGHUP misses.

Current source implements explicit pane-close teardown but does not invoke it from the app
quit path. T-084 already names this as a non-goal and measured that a detached background
job can survive backend deallocation. Therefore terminal lifecycle remains partial: normal
pane close is owned and escalated; whole-app quit still relies on libghostty/ARC and cannot
claim equivalent process-tree settlement.

### Proposed outcome

One process-wide Ghostty runtime owns isolated default configuration; each visible terminal
pane lazily receives one surface keyed by stable pane UUID. The SurfacePool preserves that
surface across focus/tab/workspace changes, queues pre-materialization automation input,
and terminates it only when the pane leaves the catalog. Six canonical public intents cover
write, reuse-and-run, always-new open, viewport read, scrollback paging, and bounded wait.

Input, IME, key equivalents, clipboard requests, resizing, rendering, and callbacks remain
native AppKit/libghostty behavior with explicit safety seams. Scrollback cursors are values,
not handles. Pane close sweeps every process group on the pane's tty with SIGHUP then a
bounded SIGKILL escalation. App quit must explicitly drain all terminal surfaces before
this PRD can become shipped.

### Why now

Terminal behavior is a dependency for Files, agents, automations, CLI control, attention,
and restoration. Capturing the complete source contract prevents future command/open work
from regressing pending-text delivery, process ownership, or read coherence.

## 2. Discovery record

### Evidence available

| Evidence | Confidence | Establishes |
|---|---|---|
| [`TerminalSurface.swift`](../../Sources/TenonApp/TerminalSurface.swift), [`SurfacePool.swift`](../../Sources/TenonApp/SurfacePool.swift) | high | backend seam, lazy keyed lifetime, queued input, observations, explicit close teardown |
| [`GhosttySurface.swift`](../../Sources/TenonApp/GhosttySurface.swift) | high | runtime/config, rendering/input/clipboard, OSC facts, foreground PID, backend termination |
| [`TerminalIntentProvider.swift`](../../Sources/TenonApp/TerminalIntentProvider.swift), [`CoreIntentCatalog.swift`](../../Sources/TenonCore/CoreIntentCatalog.swift) | high | six current contracts, targeting, schemas, bounds, capabilities, lanes |
| [`ScrollbackPaging.swift`](../../Sources/TenonCore/ScrollbackPaging.swift), [`IdleDetector.swift`](../../Sources/TenonCore/IdleDetector.swift) | high | pure paging/coherence and TUI-idle rules |
| [`TerminalJobTermination.swift`](../../Sources/TenonCore/TerminalJobTermination.swift), [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift) | high | close inspection, tty ownership, signal ordering/escalation, fail-safe confirmation |
| [`TenonApp.swift`](../../Sources/TenonApp/TenonApp.swift) | high | current quit sequence omits `terminalSurfaces.retainOnly([])` |
| focused terminal test suites | high | provider, key, read capability, paging, idle, lifecycle, real-process, Ghostty smoke seams |
| T-015/T-035/T-040/T-044/T-084 | medium | original design/receipts; source supersedes old WorkspaceCommand terminology |

### Context questions

| Question | Answer |
|---|---|
| Core problem? | Keep terminal rendering, automation, and process ownership coherent under one pane identity. |
| Primary users? | Operators and programmatic plugin/CLI/agent callers. |
| Success? | Input reaches the intended PTY, reads are bounded/honest, hidden panes survive, and closed/quit panes leave no owned jobs. |
| Fixed constraints? | native AppKit/libghostty, typed DIRECT host calls, classified intents, bounded payloads/timeouts, no native handles across public boundaries. |
| Unresolved? | explicit whole-app quit teardown and the live audible-beep/original nohup rechecks. |

### Assumptions to validate

| ID | Assumption | Validation | State |
|---|---|---|---|
| `TERM-A-001` | 200 ms wait polling and three samples are sufficient supervision latency. | installed use and wait tests | shipped decision; ~200/600 ms cost documented |
| `TERM-A-002` | Default Ghostty config is preferable to loading machine-specific config. | product feedback | shipped decision |
| `TERM-A-003` | tty-scoped teardown covers pane-owned jobs users expect to end. | real PTY fixture and installed nohup recheck | fixture proven; installed recheck owed |

## 3. Users and jobs

### Primary user

An operator running shells, agents, servers, and TUIs across several panes. They need input
and focus to feel native, automation to target predictably, and closing a pane to mean its
work ends.

### Secondary actors

- Plugin, CLI, and agent principals using terminal intents.
- Agent Lens reading terminal identity and sending guarded DIRECT input.
- macOS accessibility, input-method, clipboard, and responder systems.
- Support engineers diagnosing process survivors or cursor invalidation.

### Jobs to be done

- Type, paste, use IME/dead keys, and invoke terminal shortcuts without false system beeps.
- Run a command in a useful existing terminal or request a fresh isolated terminal.
- Read the viewport or complete stopped scrollback without silent skips.
- Wait for exit, TUI idle, or a command-finished marker with a bounded timeout.
- Switch away without killing work, but close a pane/tab knowing owned jobs terminate.

### Vocabulary

| Term | Meaning | Not to be confused with |
|---|---|---|
| Runtime | one process-wide `ghostty_app_t` | a pane surface |
| Surface | one pane-keyed renderer/PTY | its transient SwiftUI wrapper |
| Preferred terminal | scoped active terminal, first terminal, then workspace fallback for run | always-new open |
| Cursor | encoded row offset plus observed total row count | resource handle |
| Foreground PID | backend process-group identity used for inspection/input guard | public ownership token |
| Pane close | slot leaves catalog | hiding/switching a pane or app quit |

## 4. Goals and measures

### Goals

- `TERM-G-001` — Every terminal pane has stable lazy surface and process ownership.
- `TERM-G-002` — Native input/render/clipboard behavior is correct and permission-aware.
- `TERM-G-003` — Public automation is finite, scoped, bounded, and capability-gated.
- `TERM-G-004` — Terminal reads never silently truncate, shift, or claim nonexistent state.
- `TERM-G-005` — Pane close and app quit explicitly settle every pane-owned process group.

### Success and guardrails

| ID | Target | Measurement |
|---|---|---|
| `TERM-M-001` | queued command loses zero bytes on first materialization | lifecycle/provider tests |
| `TERM-M-002` | handled terminal key produces zero forwarded selector beeps | responder tests + human audio check |
| `TERM-M-003` | scrollback page is ≤2,000 lines and inline payload limit | schema/provider tests |
| `TERM-M-004` | wait timeout ≤55 s; poll 200 ms; TUI idle three stable samples | provider/idle tests |
| `TERM-M-005` | pane close leaves zero tty-attached process groups | real process test + installed recheck |
| `TERM-M-006` | app quit leaves zero pane-owned process groups | pending quit integration test/live check |

## 5. Scope

### In scope

- Ghostty runtime/surface creation, default config, environment, rendering, size, focus,
  keyboard/IME/key equivalents, clipboard confirmation, title/cwd/exit/command facts.
- SurfacePool materialization, retention, queued text, observation, and termination.
- `terminal.write.v1`, `run.v1`, `open.v1`, `viewport.read.v1`,
  `scrollback.read.v1`, and `wait.v1`.
- Preferred targeting and fresh-tab semantics.
- Tab-close process inspection/confirmation and pane-close tty process-group teardown.
- Explicit app-quit gap.

### Non-goals

- Exposing `TerminalSurface`, PTY handles, native views, raw process IDs, or libghostty to
  plugins/CLI/agents.
- Continuous output push; that would be a separately inventoried STREAM.
- Loading the user's Ghostty configuration.
- Killing a `setsid` daemon that detached from the pane tty; tty ownership cannot discover it.
- Restoring a dead PTY, process, or scrollback after relaunch.

### Later possibilities

- One pushed pane-observation feed shared by wait and attention, only if measured polling
  cost/latency justifies the lifecycle change.
- Search/selection reading/cmd-click polish supported by an explicit native design.

## 6. User experience

### Native terminal flow

First display materializes a surface in restored cwd or workspace path. Runtime defaults are
machine-independent; environment includes pane/surface/socket/agent-hook identity. The
surface resizes with its host, accepts normal Ghostty key bindings, and routes IME text. A
handled selector is consumed by the terminal view so Backspace/arrows/Return/Escape do not
also reach NSBeep. Truly unhandled input elsewhere keeps normal system feedback.

Clipboard operations use the standard pasteboard. Unsafe paste and OSC 52 read/write ask
through a warning sheet when confirmation is required and deny if no window exists.
Title (OSC 0/2), pwd (OSC 7), command-finished (OSC 133), process exit, and focus become
host facts; callbacks already queued after teardown resolve through non-reused weak tokens.

### Public automation flow

- Write targets the resolved terminal and queues text if it has not materialized.
- Run focuses/reuses a preferred terminal in scope, searching the scoped workspace; if no
  terminal exists it creates a terminal tab, then sends command plus newline.
- Open always creates a fresh terminal tab, optionally seeds an existing absolute working
  directory and command, returns pane UUID, and never returns ownership/handle. It does not
  accept title because the shell owns title through OSC.
- Viewport read returns one bounded live screen observation.
- Scrollback read walks oldest-to-newest in stateless pages; any total-row change invalidates
  the cursor rather than risking skipped/repeated rows.
- Wait polls for exit, three-sample TUI idle, or command-finished after the call baseline.

### Close and teardown flow

Tab close snapshots every live terminal. No live process closes immediately. Complete
identity is inspected off-main: one process group per tty is idle; multiple groups mean
running. Missing identity or failed inspection is unavailable. Running/unavailable shows a
destructive confirmation. Confirmed catalog removal invokes `terminate()` before releasing
each surface and clears pending input/state.

The terminator discovers all process groups on the foreground process's controlling tty,
orders the root group last, sends SIGHUP, waits 120 ms, re-reads the process table, then
sends SIGKILL. If tty ownership is unavailable it signals the root group/process narrowly;
if Tenon shares the tty, it refuses the broad sweep. Hidden or inactive panes never
terminate. Current app quit does not call this removal path and remains pending.

## 7. Requirements

### Functional requirements

- `TERM-FR-001` — One process-wide Ghostty runtime MUST own default-only configuration; each materialized terminal pane MUST own one surface keyed by pane UUID.
- `TERM-FR-002` — A surface MUST start in seeded/restored cwd or workspace path and receive bounded host identity environment without exposing secrets in UI.
- `TERM-FR-003` — Surface creation MUST wire title, pwd, focus, exit, command-finished, new-tab/split/navigation, and process identity through typed host seams.
- `TERM-FR-004` — Keyboard handling MUST deliver terminal input/IME and consume the AppKit command selectors already delivered to the PTY, without swallowing feedback in unrelated views.
- `TERM-FR-005` — Terminal clipboard MUST support ordinary copy/paste and require explicit confirmation for unsafe paste or OSC 52 access when requested; absent window MUST deny.
- `TERM-FR-006` — The terminal MUST render/resize/focus at current backing scale and report viewport cells, dimensions, scrollback, exit, command count, and foreground PID where available.
- `TERM-FR-007` — `terminal.write.v1` MUST target the resolved terminal, send bounded text verbatim, and queue it without materializing a not-yet-visible valid terminal.
- `TERM-FR-008` — `terminal.run.v1` MUST reuse/focus the preferred terminal in scope or create one terminal tab when none exists, then append exactly one newline.
- `TERM-FR-009` — `terminal.open.v1` MUST always create a fresh terminal tab and return its pane UUID, even when another terminal is usable.
- `TERM-FR-010` — Open MUST accept optional nonblank/NUL-free command and existing absolute `workingDirectory`, seed before materialization, and refuse invalid values rather than ignore them.
- `TERM-FR-011` — Terminal target resolution MUST respect explicit pane, tab, and workspace scope and return typed unavailable reasons for missing/nonterminal targets.
- `TERM-FR-012` — Viewport read MUST return paneID, bounded visible text, exit state, and nullable columns/rows without changing its v1 shape.
- `TERM-FR-013` — Scrollback read MUST page oldest-to-newest with default 500, maximum 2,000 rows and inline-byte limit, returning total rows and nullable next cursor.
- `TERM-FR-014` — A scrollback cursor MUST invalidate with empty text when retained row count differs from the count it encoded.
- `TERM-FR-015` — Wait MUST support `exit`, `tui-idle`, and `command-finished`, returning one `{paneID, condition, met}` result.
- `TERM-FR-016` — Wait MUST default to 30 s, cap at 55 s, poll at 200 ms with tolerance, and require three stable viewport samples for TUI idle.
- `TERM-FR-017` — Command-finished wait MUST compare OSC 133 count after the call baseline and return `met:false` if process exits first.
- `TERM-FR-018` — Tab close MUST inspect live terminal groups off-main and confirm when running state is present or cannot be verified.
- `TERM-FR-019` — A surface MUST remain alive across focus/tab/workspace changes and terminate exactly once only after its slot leaves the catalog.
- `TERM-FR-020` — Pane termination MUST clear callbacks, sweep all process groups on the pane tty, order root last, send SIGHUP, wait 120 ms, re-scan, then SIGKILL survivors.
- `TERM-FR-021` — When tty ownership is unavailable, termination MUST narrowly signal root group/process; when Tenon shares the tty, broad sweeping MUST fail safe.
- `TERM-FR-022` — Pane removal MUST also clear surface token, title, directory, attention, viewed, and pending-text state for that UUID.
- `TERM-FR-023` — Process-table parsing/inspection MUST reject invalid/root groups, no-tty rows, incomplete identity, and recycled/stale target assumptions.
- `TERM-FR-024` — App quit MUST explicitly terminate every materialized terminal through the same surface seam before process exit; this is currently not delivered.
- `TERM-FR-025` — Relaunch MUST create a fresh shell only; it MUST NOT claim restoration of PTY, job tree, or scrollback.

### Non-functional requirements

- `TERM-NFR-001` — Terminal chrome/placeholders/confirmation UI MUST follow [`designs.md`](../designs.md); terminal cell rendering remains backend-owned.
- `TERM-NFR-002` — Runtime/surface access MUST remain MainActor-confined; process-table reads, signal escalation waits, and other blocking work MUST stay off-main.
- `TERM-NFR-003` — Callback identity MUST use monotonic non-reused tokens resolving weak views so teardown cannot dereference released Swift objects.
- `TERM-NFR-004` — All public command/text/output/cursor/page/timeout fields MUST have explicit schema and runtime bounds.
- `TERM-NFR-005` — All six terminal intents MUST use programmatic `{plugin, cli, agent}` exposure, declared-use gates, `terminal.write` or `terminal.read`, and canonical lanes.
- `TERM-NFR-006` — Scrollback cursor and returned pane UUID MUST remain bounded values, never caller-owned resource handles.
- `TERM-NFR-007` — Termination MUST be explicit, idempotent at catalog ownership, bounded to two process-table scans/one wait, and re-scan before escalation to reduce PID-reuse risk.
- `TERM-NFR-008` — Plugins MUST use `tenon.intents.send`; no handwritten terminal capability API or native terminal object may reappear.
- `TERM-NFR-009` — Pure targeting, paging, idle, and process-group decisions MUST be tested without a window; native edges MUST have hosted/integration evidence.
- `TERM-NFR-010` — PRD lifecycle MUST remain partial until app-quit termination and its regression/live evidence are delivered.

## 8. Acceptance specification

[`terminal.feature`](terminal.feature) provides exact bidirectional requirement tags.
Completion additionally requires an app-quit test proving every materialized surface receives
terminate, a real survivor fixture through the quit path, and an installed recheck that does
not interrupt the user's running app.

## 9. Product and architecture constraints

### Interaction classification

| Interaction | Class |
|---|---|
| native shell → SurfacePool/TerminalSurface | DIRECT |
| OSC title/pwd/finished/exit/focus | EVENT/fact |
| six public terminal requests | INTENT |
| future continuous output | STREAM, not currently shipped |
| surface/PTY/process tree | host-owned RESOURCE keyed by pane lifetime |

The scrollback cursor is not a resource: it owns no host state, needs no release, and fails
by invalidation. `terminal.open.v1` returns pane identity but caller does not own pane
lifetime. Public work remains finite and programmatic.

### Ownership, lifecycle, security

- WorkspaceStore owns pane/tab placement; SurfacePool owns surface/resource join; Ghostty
  owns emulation; TerminalJobTerminator owns teardown mechanics.
- User Ghostty configuration is not loaded, keeping terminal behavior deterministic.
- Clipboard confirmation defaults to deny without a presenting window.
- Public read/write capabilities and scopes are checked by the intent kernel; no raw PID,
  clipboard, PTY, or environment handle crosses the boundary.
- Broad signal sweep is limited to the proven tty and refuses a host-shared tty.

### Compatibility

- T-015's old WorkspaceCommand/`tenon.terminal.run` account is superseded by
  `terminal.run.v1` through the intent bus.
- Viewport v1 remains unchanged when scrollback read is added.
- Open uses `workingDirectory`, consistent with process exec, and intentionally has no title.
- Polling remains a documented decision until one shared pushed observation feed replaces
  both wait and attention.

## 10. Delivery plan

| Group | State | Exit evidence |
|---|---|---|
| native surface/input TERM-FR-001…006 | shipped; human beep check owed | key/clipboard/Ghostty smoke |
| public intents TERM-FR-007…017 | shipped | catalog/provider/paging/idle tests |
| pane close TERM-FR-018…023 | shipped; installed nohup recheck owed | lifecycle/real-process tests |
| app quit TERM-FR-024, NFR-010 | open | explicit pool drain + quit integration/live test |
| fresh relaunch TERM-FR-025 | shipped | catalog/surface lifecycle tests |

Implement app-quit repair in the existing stop sequence after final catalog persistence and
before runtime/process exit. Drain via a dedicated explicit SurfacePool operation or the
same retained-set semantics, await/observe bounded termination as needed, and do not mutate
the catalog merely to kill resources.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| background job survives quit | explicit quit drain and survivor fixture |
| broad sweep kills developer shell | host-shared tty guard |
| stale PID receives SIGKILL | re-read process table before escalation |
| queued command reaches wrong pane | UUID-keyed pending buffer and removal cleanup |
| live scrollback silently shifts | strict total-row invalidation |
| polling multiplies mechanisms | retain one documented cadence; future shared feed only |
| handled keys beep | consume derived selector only in Ghostty view |

## 12. Open questions and decisions

- `TERM-OQ-001` — Must app quit await escalation completion, or may it hold termination until
  all bounded terminator tasks settle? Verification must prove no survivor either way.
- `TERM-OQ-002` — Should future output streaming replace both wait and attention polling?

| Date | Decision | Supersedes |
|---|---|---|
| 2026-08-09 | current six intent contracts are canonical | pre-intent WorkspaceCommand narrative |
| 2026-08-09 | cursor is a value, not a handle | assumption that paging implies RESOURCE |
| 2026-08-09 | tty sweep plus escalation owns pane close | libghostty deallocation-only behavior |
| 2026-08-09 | app quit remains open | any broad claim that T-084 completed all teardown |

## 13. Verification receipts

| Area | Current receipt | Gap |
|---|---|---|
| targeting/delivery | provider and SurfaceLifecycle tests | none headlessly |
| input | TerminalKeyHandling tests | audible installed check |
| read/wait | catalog/provider/ScrollbackPaging/IdleDetector tests | Ghostty scrollback C edge uses smoke/stub evidence |
| close teardown | pure parser, stub terminate, real PTY process tests | installed original nohup recheck |
| app quit | source audit proves no pool drain | implementation, integration test, live survivor check |

## 14. Change history

| Date | Author | Change |
|---|---|---|
| 2026-08-09 | Codex | Created current-source terminal PRD and kept app-quit teardown explicitly open. |
