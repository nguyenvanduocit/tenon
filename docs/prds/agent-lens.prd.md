# PRD — Agent Lens, session evidence, and milestone timelines

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-012` |
| Lifecycle | `partial` |
| Owner | agent-lens, terminal-surface, workspace-model, and plugin-contributions domains |
| Reviewers | product, native UI, accessibility, privacy/security, agent integrations, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-013, T-048, T-067, T-068, T-069, T-075, T-089, T-102 |
| Existing design | [`design-agent-lens.md`](../design-agent-lens.md) |
| Acceptance specification | [`agent-lens.feature`](agent-lens.feature) |

## 1. Executive summary

### Problem

Raw terminal output is exact but expensive to scan when supervising one or several coding
agents. Transcripts alone are insufficient: Claude writes some decisive facts only through
live hooks, Codex session identity cannot safely be guessed from cwd/mtime, and generated
summaries can invent or double-count progress unless the host retains evidence authority.
At the same time, detecting an agent must not steal the terminal renderer or restart its PTY.

### Proposed outcome

Agent Lens is a host-internal semantic projection over the same living terminal slot. Session,
Terminal, and Split are presentation choices; Chat and Timeline are accounts of one attached
session. Bounded provider events and transcript streams reduce into evidence-ordered snapshots,
explicit diagnostics, guarded input, pending interactions, file links, and readable Markdown.
Timeline generation is an explicit cancellable AI task whose milestones cite host-validated
facts; the model judges grouping, never identity, times, anchors, or live completion.

The separate `claude-sessions` plugin remains a history/resume browser, not the live Lens.
Fleet orchestration uses `tenon.agents.run` and terminal intents; Agent Lens observes the
resulting panes rather than creating another orchestration API.

### Why now

The capability is extensively tested but still has assembled installed-app observations and
one real-provider fleet race/e2e question outstanding. Canonical requirements must distinguish
headless component proof from a user-observed live workflow and preserve explicit degradation.

## 2. Discovery record

| Evidence | Source | Confidence | Establishes |
|---|---|---|---|
| accepted design | [`design-agent-lens.md`](../design-agent-lens.md) | high for intended/current mapping | ownership, trust, bounds, presentation law |
| live Lens source | [`AgentLensDomain.swift`](../../Sources/TenonApp/AgentLensDomain.swift), [`AgentLensSession.swift`](../../Sources/TenonApp/AgentLensSession.swift), [`AgentLensView.swift`](../../Sources/TenonApp/AgentLensView.swift) | high | reducer, modes, UI, lifecycle |
| ingress/identity | [`AgentSessionHooks.swift`](../../Sources/TenonApp/AgentSessionHooks.swift), [`AgentLensSources.swift`](../../Sources/TenonApp/AgentLensSources.swift) | high | auth, provider binding, streams |
| Timeline | `Sources/TenonApp/AgentTimeline*`, `AgentSessionTimeline.swift` | high | digest, synthesis, validation, view states |
| history plugin | [`plugins/claude-sessions`](../../plugins/claude-sessions) | high | bounded listing/resume behavior |
| tests/tasks | Agent Lens/Timeline/Fleet suites; T-013/T-048/T-067/T-068/T-069/T-075/T-089/T-102 | medium/high | headless receipts, live-discovered timeline reread fix, and known live exclusions |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Regain trustworthy situation awareness and intervene without leaving the spatial terminal context. |
| Primary users? | operators supervising Claude Code or Codex sessions in terminal panes |
| Success? | evidence is ordered, bounded, attributable, actionable, and Terminal remains exact escape hatch |
| Fixed constraints? | same PTY, DIRECT host interactions, authenticated EVENT ingress, resource streams, no invented evidence |
| Unknown? | assembled GUI input/link behavior and true-provider fast-command fleet race remain to observe |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `AL-A-001` | Chat plus semantic Timeline lowers resumption time. | workflow study | unmeasured |
| `AL-A-002` | 1,024-event streams and current reducer capacities cover ordinary sessions. | long-session fixtures/telemetry | bounded, revisit by evidence |
| `AL-A-003` | Current Claude/Codex terminal grammars remain compatible with guarded answers. | installed provider matrix | partially observed |

## 3. Users, jobs, and vocabulary

The primary user watches agents working in several panes and needs to answer “what is it doing,
what changed, does it need me, and what evidence supports that?” without replacing the terminal.

- Resume one historical Claude session from a bounded project list.
- Detect a live supported agent without losing the terminal view.
- Scan one chronological narrative, inspect source evidence, and answer a pending question.
- Open a cited file, or return to exact terminal state when semantic evidence degrades.
- Request a short milestone interpretation and verify every milestone against host facts.
- Observe several agent panes while orchestration remains owned by Automations/terminal intents.

| Term | Meaning | Not to be confused with |
|---|---|---|
| Lens session | semantic attachment to a living terminal surface | `claude-sessions` history row |
| Session mode | semantic renderer | provider session identity |
| Chat | verbatim conversation account | raw PTY transcript |
| Timeline | AI-grouped milestone interpretation | event-per-row log |
| evidence authority | provider-reported or host-observed provenance | truth/confidence score |
| gap diagnostic | explicit incomplete-source fact | silent omission |

## 4. Goals, measures, and bounds

- `AL-G-001` — Preserve the PTY while making agent state quickly scannable.
- `AL-G-002` — Bind evidence to the correct root session and current surface incarnation.
- `AL-G-003` — Make questions, failures, gaps, and evidence return paths actionable.
- `AL-G-004` — Permit AI interpretation without granting it authority over checkable facts.

| ID | Target | Measurement |
|---|---|---|
| `AL-M-001` wrong-session evidence admitted | zero | identity/admission tests |
| `AL-M-002` detection-triggered renderer switches | zero | live pipeline test |
| `AL-M-003` silently dropped semantic overflow | zero | stream/reducer tests |
| `AL-M-004` invented/shared Timeline anchors rendered | zero | validator mutation tests |
| `AL-M-005` input delivered after foreground identity changes | zero | surface/input tests |

Key bounds: 1,024 events per stream; 2 MB transcript record; 64 KB tool output; 8 MB initial
window, opened at the first record that stands on its own rather than at the byte the seek
landed on; Timeline digest 320 facts/96 KiB; synthesis output 64 KiB; at most 12 milestones,
24 anchors each, titles 80 chars and prose fields 400 chars; synthesizer process 45 seconds of
silence under a 600-second ceiling, and 512 KiB per CLI stream line.

## 5. Scope

### In scope

- `claude-sessions` history/resume plugin;
- Claude/Codex discovery, authenticated hooks, transcript/native streams, identity registry;
- reducer/snapshot, Session/Terminal/Split, Chat/Timeline, inspector and pending requests;
- Markdown, responsive tables, bounded messages, evidence/file links;
- guarded text/option input, failure recovery, pool/app teardown;
- AI timeline digest, task, validation, staleness, retry/cancel and evidence expansion;
- fleet observation and cross-link to `tenon.agents.run`.

### Non-goals

- replacing Terminal, replaying/restarting the agent, or reconstructing arbitrary PTY bytes;
- context instructions/skills as primary execution events;
- guessing Codex identity from cwd/newest transcript;
- plugin access to host-private agent lifecycle evidence;
- line-number jump before file content supports line targets;
- Timeline as transcript relabeling or session-level verdict;
- claiming unsupported providers have semantic capabilities.

## 6. User experience

Agent detection reveals the existing pane-header mode control but leaves `.terminal` selected.
The person chooses Session or Split. Session shows one summary, pending judgment, and evidence-
ordered narrative; instructions remain collapsed in the inspector. Terminal always re-enters the
live surface. Switching mode/account never changes attachment or process.

Claude live tool/question state comes from hooks, while transcript prose and offsets remain the
record. Codex requires authoritative hook/native binding. Malformed, missing, rotated, oversized,
overflowed, stale, or unauthenticated sources become named degradation. File citations link only
when safely resolved inside the workspace. Composer input is FIFO and process-guarded.

Timeline begins only on explicit request. Chat stays usable while the installed agent CLI reads a
bounded digest. Empty/short sessions avoid a model call. Valid milestones group at least three
facts, use host-written labels/times, and cannot claim settled over visible open work. New facts
mark the last reading stale; newest requested run alone may replace it.

## 7. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `AL-FR-001` | `claude-sessions` **MUST** list bounded project transcripts newest-first with useful metadata and resume the selected ID in the terminal. | shipped | `@req-al-fr-001` |
| `AL-FR-002` | Agent Lens **MUST** project the same living terminal slot; renderer changes **MUST NOT** replace the surface, PTY, process, input, or scrollback. | shipped | `@req-al-fr-002` |
| `AL-FR-003` | Detecting or reattaching an agent **MUST** reveal choices without changing the person's selected renderer. | shipped | `@req-al-fr-003` |
| `AL-FR-004` | Session, Terminal, and Split **MUST** be local presentation modes in the pane's one header; Terminal **MUST** remain the exact escape hatch. | shipped | `@req-al-fr-004` |
| `AL-FR-005` | Session **MUST** present one evidence-ordered narrative across conversation, tools, subagents, questions, and diagnostics, with context instructions collapsed in the inspector. | shipped | `@req-al-fr-005` |
| `AL-FR-006` | Pending questions/approvals **MUST** be elevated; repeated skill reads and adjacent subagent controls **SHOULD** group without losing evidence. | shipped | `@req-al-fr-006` |
| `AL-FR-007` | Agent Markdown **MUST** support emitted headings, prose, nested/ordered/task lists, fences, quotes, tables, rules, and attributed inline syntax with streaming-safe degradation. | shipped | `@req-al-fr-007` |
| `AL-FR-008` | Wide tables **MUST** use columns, narrow tables **MUST** reflow to labeled fields, and collapsed messages **MUST** bound source before block rendering. | shipped | `@req-al-fr-008` |
| `AL-FR-009` | A cited path **MUST** link only when it resolves to an existing contained file; file inference **MUST** reject commands, flags, URLs, escape paths, and missing files. | shipped | `@req-al-fr-009` |
| `AL-FR-010` | File-link activation **MUST** call typed workspace placement DIRECT and **MUST NOT** self-send a public intent. | shipped/headless | `@req-al-fr-010` |
| `AL-FR-011` | Supported providers **MUST** be explicit; absent authoritative evidence **MUST** report process-only/degraded capability rather than guess a conversation. | shipped | `@req-al-fr-011` |
| `AL-FR-012` | Surface identity **MUST** include pane, host-minted incarnation token, foreground process group, root session ID, and canonical transcript where applicable. | shipped | `@req-al-fr-012` |
| `AL-FR-013` | Hook ingress **MUST** be loopback-only, bearer-authenticated, bounded, and admitted before decoding into host state. | shipped | `@req-al-fr-013` |
| `AL-FR-014` | Codex root binding **MUST** reject child facts, stale sessions/incarnations, wrong process groups, unsafe paths, and older replacements. | shipped | `@req-al-fr-014` |
| `AL-FR-015` | Claude **MUST** use hooks as the live lifecycle/question spine and transcript as prose/evidence record. | shipped | `@req-al-fr-015` |
| `AL-FR-016` | Hook and transcript tool facts **MUST** reconcile by provider tool ID; completion cannot reopen and answered questions cannot reappear. | shipped | `@req-al-fr-016` |
| `AL-FR-017` | Claude tool names/inputs/results **MUST** project into human task kinds/summaries, including command, files, search, subagent, web, plan, skill, and question. | shipped | `@req-al-fr-017` |
| `AL-FR-018` | Capabilities **MUST** follow observed transport evidence; hook installation failure **MUST** be visible with retry. | shipped | `@req-al-fr-018` |
| `AL-FR-019` | Transcript/native sources **MUST** stream normalized events with cancellation and terminate overflow as an explicit gap diagnostic. | shipped | `@req-al-fr-019` |
| `AL-FR-020` | The reducer **MUST** serialize facts into immutable snapshots with authority, source location, offset/fingerprint, capture time, freshness, status, and bounded collections. | shipped | `@req-al-fr-020` |
| `AL-FR-021` | Text input **MUST** validate foreground identity, sanitize bracketed-paste terminators, send one paste plus separately guarded Return, and serialize submissions FIFO. | shipped | `@req-al-fr-021` |
| `AL-FR-022` | Option answers **MUST** use the provider's terminal grammar, latch interaction identity, and prevent duplicate delivery. | shipped | `@req-al-fr-022` |
| `AL-FR-023` | Input identity failure **MUST** withhold remaining bytes, fail visibly, and return to Terminal for exact recovery. | shipped | `@req-al-fr-023` |
| `AL-FR-024` | Chat and Timeline **MUST** be local accounts of the same attachment, independent of renderer mode. | shipped | `@req-al-fr-024` |
| `AL-FR-025` | Timeline generation **MUST** be explicit and use a bounded evidence digest; empty/unattached/fewer-than-six-fact sessions **MUST NOT** call a model. | shipped | `@req-al-fr-025` |
| `AL-FR-026` | Timeline **MUST** contain a small set of semantic milestones, not one row per fact, with bounded title/change/importance/state fields. | shipped | `@req-al-fr-026` |
| `AL-FR-027` | Milestone anchors **MUST** be existing digest IDs; labels and time spans **MUST** be host-derived. | shipped | `@req-al-fr-027` |
| `AL-FR-028` | Milestone grouping **MUST** be a partition with at least three facts each; settled **MUST** be refused over observed open work; no session verdict may be synthesized. | shipped | `@req-al-fr-028` |
| `AL-FR-029` | Loading, cancel, failure, retry, success, and stale states **MUST** preserve usable Chat and the last valid reading. | shipped | `@req-al-fr-029` |
| `AL-FR-030` | Timeline runs **MUST** be newest-request-wins; cancellation/newer runs **MUST** prevent older results from landing. | shipped | `@req-al-fr-030` |
| `AL-FR-031` | Synthesis **MUST** run the person's installed agent CLI headlessly in scratch space with one turn, without the operator's customizations or session persistence, output bound, deadline, and process termination. | shipped | `@req-al-fr-031` |
| `AL-FR-032` | Closing a slot/app **MUST** cancel Lens/timeline work, clear bindings, and close ingress; hide/tab/focus/mode changes **MUST NOT**. | shipped | `@req-al-fr-032` |
| `AL-FR-033` | Fleet orchestration **MUST** remain `tenon.agents.run` over terminal intents; Lens **MUST** observe resulting panes without a duplicate public API. | partial | `@req-al-fr-033` |
| `AL-FR-034` | A real-provider installed workflow **MUST** verify fast command completion, multi-agent aggregation, Claude pending-question answer, file-link click, and mode preservation end to end. | planned verification | `@req-al-fr-034` |
| `AL-FR-035` | Whether a session is readable **MUST** be derived from the current snapshot every time it is drawn, never stored; a session that crosses the six-fact bar while Timeline is open **MUST** become readable without re-attaching. | shipped | `@req-al-fr-035` |
| `AL-FR-036` | A bounded history window **MUST** open at a record that carries its own meaning; a record holding only tool results **MUST NOT** open one, so a cut turn never projects a completion whose call is on the far side of the cut. | shipped | `@req-al-fr-036` |
| `AL-FR-037` | Where visible history begins **MUST** be evidence naming transcript and byte offset, from the bounded window and from in-memory trimming alike, and the Session notice **MUST** state it. | shipped | `@req-al-fr-037` |
| `AL-FR-038` | A reading in flight **MUST** report what it is doing from the CLI's own stream, and its deadline **MUST** be silence rather than duration, with the two expiries distinguishable to the reader. | shipped | `@req-al-fr-038` |
| `AL-FR-039` | A session **MUST** bind to the transcript its root hook declares from the moment it is declared, without waiting for the provider to create the file; a transcript that has not appeared yet **MUST NOT** be reported as a fault. | shipped | `@req-al-fr-039` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `AL-NFR-001` | design/accessibility | Lens/Timeline **MUST** use native Tenon density/tokens, keyboard/VoiceOver labels, semantic non-color state, and narrow-pane reflow. | partial visual | `@req-al-nfr-001` |
| `AL-NFR-002` | boundedness | All stream, record, output, digest, milestone, and collection bounds specified above **MUST** fail visibly. | shipped | `@req-al-nfr-002` |
| `AL-NFR-003` | privacy/security | Ingress and transcript paths **MUST** authenticate/contain identity; evidence **MUST NOT** be exposed to plugins or unrelated panes. | shipped | `@req-al-nfr-003` |
| `AL-NFR-004` | lifecycle | Every stream/task/input continuation **MUST** cancel and settle exactly once under slot close, app stop, overflow, timeout, or replacement. | shipped | `@req-al-nfr-004` |
| `AL-NFR-005` | determinism | Replay/reduction/validation over the same normalized evidence **MUST** produce the same host facts and refusals. | shipped | `@req-al-nfr-005` |
| `AL-NFR-006` | evidence | Provider-reported and host-observed facts **MUST** retain distinct authority/freshness and never be presented as equivalent ground truth. | shipped | `@req-al-nfr-006` |
| `AL-NFR-007` | responsiveness | Tailing, parsing, projection, and synthesis I/O **MUST NOT** block MainActor; the live terminal and Chat remain usable. | shipped | `@req-al-nfr-007` |
| `AL-NFR-008` | architecture | Built-in state/input/file actions **MUST** be DIRECT, facts EVENT, tails RESOURCE/STREAM, and Timeline RESOURCE/TASK; no new public path/principal is added. | shipped | `@req-al-nfr-008` |
| `AL-NFR-009` | fail-soft | Unknown methods and malformed/missing/rotated/oversized sources **MUST** become explicit diagnostic or safe ignore according to whether evidence completeness is affected. | shipped | `@req-al-nfr-009` |
| `AL-NFR-010` | verification | Headless mutation proof **MUST** be complemented by installed visual/interaction receipts for assembled native flows. | partial | `@req-al-nfr-010` |
| `AL-NFR-011` | privacy/security | A bound transcript **MUST** be proven a regular file owned by this user on every read pass, so a path trusted before it exists cannot later deliver another file's bytes. | shipped | `@req-al-nfr-011` |

## 8. Acceptance specification

[`agent-lens.feature`](agent-lens.feature) maps all 45 requirements. Reducer/decoder/tailer,
hosted input/surface, Timeline validator/ledger, plugin, fleet integration, visual snapshot,
and installed-app observation are distinct evidence seams; only the last remains incomplete.

## 9. Product and architecture constraints

| Interaction | Classification | Constraint |
|---|---|---|
| snapshot/mode/account/input/file open | DIRECT | same host owner and typed services |
| hook/tool/question/lifecycle fact | EVENT | authenticated fact already happened |
| transcript/native ingress | RESOURCE/STREAM | bounded producer lifetime |
| Timeline synthesis | RESOURCE/TASK | pane-owned cancellable process/model run |
| fleet launch/wait/read | INTENT from automation/plugin | canonical terminal contracts |

`SurfacePool` owns PTY; `AgentLensPool` owns the view model; registry owns binding; ingress
owns listener; coordinator owns reduction; synthesizer/ledger own readings. No plugin sees
host-private evidence. Transcript paths are same-user regular files under the active provider
root. Host UI follows `docs/designs.md` and preserves one pane header.

## 10. Delivery matrix and rollout

| Requirements | Source/evidence | State/gap |
|---|---|---|
| 001 | `claude-sessions`, shipped plugin tests | shipped |
| 002…010 | Lens view/markdown/file links and tests | shipped; link click live receipt owed |
| 011…020 | hooks, sources, registry, reducer tests | shipped; assembled provider receipt owed |
| 021…023 | input queue/surface tests | shipped; real Claude question receipt owed |
| 024…032, 035 | Timeline source, 28+ tests/mutations/snapshots | shipped |
| 033…034 | fleet example/integration and checklist | partial; true-provider fast command/e2e pending |
| 036…037 | `AgentTranscriptDecoder.opensHistoryWindow`, tailer window start, reducer `earlierHistory`, `AgentLensEarlierHistoryNotice` | shipped; `AgentLensReducerTests`/`AgentLensStreamTests` |
| 038 | `AgentCLIStreamReader`, `AgentTimelineProgress`, silence watchdog, `AgentTimelineView.running` | shipped; `AgentSessionTimelineTests` |

Rollout is fail-soft: Terminal remains available; semantic attachment may degrade without
stopping the process. New provider support requires authoritative identity, bounded ingress,
decoder, capability truth, fixtures, and installed observation—not a process-name heuristic.

## 11. Risks and mitigations

| ID | Risk | Mitigation |
|---|---|---|
| `AL-R-001` | wrong transcript attached to visible process | incarnation/process/root/path conjunction; no cwd guess |
| `AL-R-002` | hook and transcript duplicate/reopen work | provider tool-ID reconciliation and terminal state precedence |
| `AL-R-003` | AI timeline becomes confident fiction | host anchors/labels/times/partition/settled validator |
| `AL-R-004` | answer bytes leak into next prompt | identity guard, provider grammar, latch, separate Return check |
| `AL-R-005` | headless green hides native click/focus defect | FR-034/NFR-010 installed checklist remains open |
| `AL-R-006` | a bounded window strands a turn and shows an unnamed finished tool | window opens only at a record that stands alone (FR-036); the cut names its own offset (FR-037) |
| `AL-R-007` | a reading that is working is indistinguishable from one that hung | the CLI's stream drives both what is shown and when the host stops waiting (FR-038) |
| `AL-R-008` | a provider stops being recognised when it changes how it installs itself | unmitigated, and measured: Claude Code 2.1.226 runs from `~/.local/share/claude/versions/2.1.226`, so the executable is named after the version and `provider(for:)` matches only on the incidental `/claude` directory component. A new install layout takes detection to nothing, and nothing in the suite would notice — the host cannot assert on a path only the provider chooses |

## 12. Open questions and decisions

Open: does `tenon.agents.run` need an additional start gate to eliminate the measured
open→fast-command→wait race under a true provider, or does provider state already close it?
The answer requires the pending real-provider test, not source inference.

| Date | Decision | Supersedes |
|---|---|---|
| 2026-08-06 | Agent detection offers modes but never changes renderer. | automatic Session switch |
| 2026-08-06 | Claude is hook-first with transcript as anchored record. | transcript-only live spine |
| 2026-08-06 | Timeline model decides grouping/judgment only; host owns checkable facts. | AI-authored evidence metadata |
| 2026-08-09 | Component proof and installed workflow proof have separate delivery states. | blanket “implemented” claim |
| 2026-08-09 | Readability is computed where it is drawn; `AgentTimelineGeneration` carries no `insufficient` case. | a verdict stored on first appearance |
| 2026-08-10 | A reading streams, so its deadline is silence (45 s) under a ceiling (600 s) rather than a flat 180 s, and the pane shows what the run said about itself. It runs `--safe-mode --no-session-persistence`: measured here, the operator's ten SessionStart hooks and 120 tools cost 8.1 s wall / 11.3 s CPU against 4.5 s / 1.3 s without them, for a run whose only job is to answer in a schema the host validates. | a fixed 180-second deadline and a spinner |
| 2026-08-10 | History is bounded in bytes but begun in meaning: the tailer seeks by byte and the decoder decides which record may open the window. Measured cost of a full 5.03 MB attach is 96 ms, so no cache, checkpoint, or reverse scan is warranted. | dropping exactly one partial record at the seek |

## 13. Verification receipts

| Date | Worktree | Scope | Result | Exclusions |
|---|---|---|---|---|
| 2026-08-09 | current dirty tree, docs audit | current design/source/test/task mapping | canonical requirements reconciled | no live provider, click, or GUI question flow run |
| 2026-08-10 | `main`, session `c254942e` | `AL-FR-039`, `AL-NFR-011` (T-116) | Reported from a live pane: Claude Code's first transcript record carried `23:39:52` while the file itself was born at `23:40:19`, so the declared path was correct and absent for 27 s and the lens sat at `.processOnly` with nothing to draw. 5 tests / 10 assertions **red first** — the binding returned `nil` before creation, and the tailer really did read a symlinked transcript, its first event arriving as `from-the-swapped-file`. Binding now attaches the declared path and `AgentTranscriptTailer` re-proves regular-file plus owner uid on every pass, from attributes it already fetched. The sixth test, that a transcript vanishing *after* it was read is still reported, was proven by mutation: `didAppear = false` turns it red in 2.4 s. Full suite **1875 / 0** | the 27 s figure is one measured session, not a bound; a provider that never writes the file leaves the pane bound to a path forever, reported as silence |
| 2026-08-10 | `main`, session `0a29c687` | `AL-FR-031`, `AL-FR-038` (T-111) | `AgentCLIStreamReader` 5 assertions **red first** against a stub answering `.ignored`; progress path checked by mutation (early return in `note(_:run:)` turns the pane test red); stream shapes recorded from the installed CLI, and `--safe-mode` verified not to break auth; `TENON_TIMELINE_SNAPSHOT_STATE=running` photographs "Writing the reading — 512 characters"; full suite **1859 / 0** | the silence watchdog has no automated test — no seam for a child process that goes quiet |
| 2026-08-10 | `main`, session `0a29c687` | `AL-FR-036`, `AL-FR-037` (T-110) | 4 tests red first — the tailer projected `AgentToolRun(id: "toolu_cut", name: "Tool", summary: "", state: .succeeded)` from a window cut between a call and its result — then `swift test` **1857 / 0**; window-start tests stable over 3 repeat runs | notice text asserted as a pure rule, not photographed; no live provider run |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD | consolidate evidence, UI, input, Timeline, history plugin, and fleet gaps |
