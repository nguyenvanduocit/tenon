# PRD — Agent Lens, session evidence, and milestone timelines

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-012` |
| Lifecycle | `partial` |
| Owner | agent-lens, terminal-surface, workspace-model, and plugin-contributions domains |
| Reviewers | product, native UI, accessibility, privacy/security, agent integrations, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-13 |
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
silence *while the reply is arriving*, under a 600-second ceiling that is the sole bound on the
quiet before it, and 512 KiB per CLI stream line.

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
| `AL-FR-038` | A reading in flight **MUST** report what it is doing from the CLI's own stream, and its deadline **MUST** be *unexplained* silence rather than duration, with the two expiries distinguishable to the reader. | shipped | `@req-al-fr-038` |
| `AL-FR-044` | A reading **MUST** read the CLI's own retryable-API-error announcement, report it to the person while it waits, and treat the quiet that follows as accounted for **for as long as the CLI said it would wait**; a retry that states no delay falls back to the absolute ceiling, which **MUST** remain the only bound on a run that never speaks again. | shipped | `@req-al-fr-044` |
| `AL-FR-049` | The silence deadline **MUST** apply only while the CLI publishes a heartbeat. The stretch between the request leaving for the API and the first frame of the reply carries no frame at all, so it **MUST** be treated as accounted for and left to the ceiling — the same answer a provider that streams nothing already gets — and the pane **MUST** say the run is waiting for the model rather than reporting the line it shows while reading. The first frame of the reply **MUST** revoke that account, putting the measured bound back in charge. | shipped | `@req-al-fr-049` |
| `AL-FR-039` | A session **MUST** bind to the transcript its root hook declares from the moment it is declared, without waiting for the provider to create the file; a transcript that has not appeared yet **MUST NOT** be reported as a fault. | shipped | `@req-al-fr-039` |
| `AL-FR-040` | A reading **MUST** be taken with the reader, model, span, and lens in effect at the moment it was requested, and the finished reading **MUST** state them; options chosen while a run is in flight belong to the next reading and **MUST NOT** be attributed to that one. | shipped | `@req-al-fr-040` |
| `AL-FR-041` | Reader choice **MUST** offer only the agent CLIs installed on this machine, and each **MUST** be invoked the way its own CLI spells a one-shot headless reading, including whether silence is evidence of death; model choice **MUST** use only that provider's documented aliases, default to the CLI's own model, and a provider that takes no alias **MUST NOT** be able to hold one by any route. | shipped | `@req-al-fr-041` |
| `AL-FR-042` | Span **MUST** bound the digest before synthesis, keeping the newest facts, marking the cut, and yielding a different fingerprint; no span may take a session below the six-fact bar that refuses a synthesis, and the cheap readability answer **MUST** continue to agree with the digest's. | shipped | `@req-al-fr-042` |
| `AL-FR-043` | Every lens **MUST** carry the identical schema, anchor, partition, compression, and `settled` rules byte for byte and differ only in what the reading is asked to notice; no lens may widen what the host accepts, and two lenses asking for the same thing **MUST NOT** both be offered. | shipped | `@req-al-fr-043` |
| `AL-FR-045` | A session that has already happened **MUST** be openable as a pane that reads it with Agent Lens itself — the same chat spine, evidence inspector, and Timeline — from a reference a plugin names through `workspace.content.open.v1`; the host **MUST** re-decide for itself that the named transcript resolves, after symlinks on both sides, to a `.jsonl` under an allowed provider root, and a path that does not **MUST** be refused as invalid input with no pane opened. | shipped | `@req-al-fr-045` |
| `AL-FR-046` | A pane reading a recorded session **MUST NOT** hold a terminal surface, start discovery, or report `canSend` under any transcript content; it **MUST** draw no composer, and a request left pending when the session ended **MUST** still be shown while offering no control to answer it. | shipped | `@req-al-fr-046` |
| `AL-FR-047` | A recorded pane **MUST** offer `+ Resume`, composed through the one typed agent composer so the options this person runs their agent with come along, converting that same pane in place into a live terminal on the same session; when the agent that recorded it is unavailable the offer **MUST** state its reason before it is pressed rather than failing under it. | shipped | `@req-al-fr-047` |
| `AL-FR-048` | A recorded pane **MUST** survive capture and restore carrying provider, session, transcript, and title, and **MUST** degrade to `.empty` — keeping its place in the layout — when the transcript is gone, its provider is unrecognised, or its stored reference is malformed. | shipped | `@req-al-fr-048` |
| `AL-FR-050` | Every row of the reading **MUST** draw inside the bounds it reports to the list that stacks it, at any pane width, so no message is written over its neighbour. A row's evidence rail is chrome, not text: it **MUST** be aligned from the row's box and **MUST NOT** resolve a text-baseline guide, which a rail holding no text answers from its own bottom edge — a number that, for a rail sized to fill the row, the row has not finished computing. | shipped | `@req-al-fr-050` |
| `AL-FR-051` | Chat **MUST** remain quiet without deleting completed work: adjacent tool, plan, and change facts from one turn fold into one compact row; settled work is collapsed by default, active work shows its latest step, and expansion **MUST** retain every original fact ID and evidence return path. Timeline synthesis **MUST** continue to read raw facts rather than the fold. | shipped | `@req-al-fr-051` |
| `AL-FR-052` | Provider turn IDs **MUST** remain authoritative correlation; sources without one **MUST** use an explicitly namespaced derived ID. Codex plan, diff, token-usage, item, and request frames **MUST** remain typed and turn-scoped, and a platform-neutral read model **MUST** expose Conversation, Work, Plans, Changes, Agents, Interactions, and Context. | shipped | `@req-al-fr-052` |
| `AL-FR-053` | A person **MUST** be able to mark a recorded session as a favourite, and a marked session **MUST** stay in the pane after the newest-`limit` window has passed it — kept out of the Claude slice, and fetched from the Codex index by ID with one bounded extra query. Marks **MUST** persist in plugin-private storage, **MUST** be shown only for the project that owns the pane, **MUST** be bounded with the oldest mark giving way rather than the newest being refused, and a refused write **MUST** leave the committed marks visible and report itself. Each row's mark control **MUST** carry its state in words. | shipped | `@req-al-fr-053` |

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

[`agent-lens.feature`](agent-lens.feature) maps all 58 requirements. Reducer/decoder/tailer,
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
| 049 | `AgentCLIStreamReading.requesting`/`.replying`, `AgentRunActivity.awaitsReply()`/`replyStarted()`/`expiry(silenceBudget:ceilingSeconds:)`, `AgentTimelineProgress.waiting` | shipped; `AgentReadingSilenceTests` |
| 040…043 | `AgentReadingOptions.swift`, `AgentTimelineDigest.build(from:span:)`, `AgentTimelinePrompt.rules(forFacts:)`, `AgentCLITimelineSynthesizer.arguments(provider:model:)`/`installedProviders`, `AgentLensViewModel.readingOptions`/`readingOptionsInUse`/`loadAvailableReaders`, `AgentTimelineView.readingControls` | shipped; `AgentReadingOptionsTests`, invitation photographed at 900 pt and 380 pt |
| 051…052 | `AgentLensReadModel.swift`, typed lifecycle state in `AgentLensDomain.swift`, Codex notification decoding, quiet work rows and context usage in `AgentLensView.swift` | shipped; `AgentLensReadModelTests`, decoder/reducer suites, Chat snapshots at wide and narrow pane widths |
| 053 | `plugins/claude-sessions/main.js` — `readFavourites`/`toggleFavourite`/`favouriteIDs`, `recentAndMarked` past the Claude slice, `missingCodexFavourites`/`codexIDFilter` for the by-ID query, grouped `listCard` | shipped; `AgentSessionFavouritesTests` drives the shipped JavaScript in a real runtime |

| 045…048 | `AgentSessionRef.swift`, `SlotContent.agentSession`, `WorkspaceCatalogStore` capture/restore, `WorkspaceIntentProvider.content(from:transcriptRoots:)`, `AgentTranscriptPath`, `AgentLensAttachment.swift`, `AgentSessionResume.swift`, `AgentSessionResumeView.swift`, `plugins/claude-sessions/main.js` Details | shipped; `AgentRecordedSessionTests` (9), `AgentSessionResumeTests` (11), `AgentTranscriptPathTests` (10) |

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
| 2026-08-11 | A reading takes four choices — reader, model, span, lens — and the lens owns the framing sentence and nothing else. The schema, anchor rules, partition, compression gate and `settled` refusal are one shared `AgentTimelinePrompt.rules(forFacts:)` block every lens concatenates verbatim, so choosing a different reading changes what the model is asked to notice and never what the host will accept as checkable. | one compiled-in reading: Claude, the CLI's default model, 320 facts, milestones |
| 2026-08-11 | A model is spelled with the provider's own documented alias or not at all. `claude --help` names `fable`, `opus`, `sonnet`; `codex exec -m` takes ids that come from the person's `config.toml` rather than from a documented list, so Codex readings run whatever that CLI is configured for and `AgentReadingOptions.init` refuses to hold an alias for it. Inventing a model id fails at run time in a way nothing in this suite could catch. | a host-chosen model-name vocabulary |
| 2026-08-11 | Recent work is 80 facts, a quarter of the digest ceiling. No measurement settles it — it is a product judgement about what "what just happened" means, written as one named constant so the judgement is visible. | a span that narrowed nothing |
| 2026-08-12 | Silence is a deadline only where a heartbeat exists to break it. Measured against the installed CLI 2.1.228 with the arguments this host builds and a 97 KB / 320-fact prompt: while the reply arrives the CLI emits 192 frames over 126.9 s with a largest gap of **2.62 s** — it heartbeats `system/thinking_tokens` about every 1.4 s even through a purely thinking stretch — while the run between `system/status status=requesting` and `stream_event/message_start` contains no frame at all. One number was doing two incompatible jobs: seventeen times looser than the streaming phase needs, and an invented bound on the only stretch that can genuinely run long. The request in flight is now accounted for and the ceiling is its sole bound, which is the answer `silenceSeconds(for: .codex)` already gave to the same question — it was a property of the phase, not of the provider. | one silence budget spanning the whole run, and 45 s of API weather read as a hang |
| 2026-08-10 | History is bounded in bytes but begun in meaning: the tailer seeks by byte and the decoder decides which record may open the window. Measured cost of a full 5.03 MB attach is 96 ms, so no cache, checkpoint, or reverse scan is warranted. | dropping exactly one partial record at the seek |
| 2026-08-13 | Chat is quiet by read-side folding, not by deleting completed work. Raw plan, change, tool, and request facts keep stable identities; provider turn IDs win, while transcript-only correlation is explicitly derived. The same platform-neutral read model is the contract a later mobile renderer consumes. | showing only the newest running tool and leaving completed execution reachable only through Terminal |
| 2026-08-14 | A favourite is a scan input, not a sort key. The operator asked to mark important sessions; marking that only reordered the visible page would drop the mark the moment `limit` moved past it, which is the week the mark starts earning its keep. So `recentAndMarked` carries a marked Claude transcript past the slice the listing already walked, and Codex — which bounds its own answer with `LIMIT` — is asked a second bounded question, `AND id IN (…)`, for exactly the ids the window missed. The record itself is plugin-private storage: no permission, no intent, no host state, and `AL-FR-053` therefore ships without touching Swift. | sorting favourites to the top of the recent window |

## 13. Verification receipts

| Date | Worktree | Scope | Result | Exclusions |
|---|---|---|---|---|
| 2026-08-09 | current dirty tree, docs audit | current design/source/test/task mapping | canonical requirements reconciled | no live provider, click, or GUI question flow run |
| 2026-08-10 | `main`, session `c254942e` | `AL-FR-039`, `AL-NFR-011` (T-116) | Reported from a live pane: Claude Code's first transcript record carried `23:39:52` while the file itself was born at `23:40:19`, so the declared path was correct and absent for 27 s and the lens sat at `.processOnly` with nothing to draw. 5 tests / 10 assertions **red first** — the binding returned `nil` before creation, and the tailer really did read a symlinked transcript, its first event arriving as `from-the-swapped-file`. Binding now attaches the declared path and `AgentTranscriptTailer` re-proves regular-file plus owner uid on every pass, from attributes it already fetched. The sixth test, that a transcript vanishing *after* it was read is still reported, was proven by mutation: `didAppear = false` turns it red in 2.4 s. Full suite **1875 / 0** | the 27 s figure is one measured session, not a bound; a provider that never writes the file leaves the pane bound to a path forever, reported as silence |
| 2026-08-10 | `main`, session `0a29c687` | `AL-FR-031`, `AL-FR-038` (T-111) | `AgentCLIStreamReader` 5 assertions **red first** against a stub answering `.ignored`; progress path checked by mutation (early return in `note(_:run:)` turns the pane test red); stream shapes recorded from the installed CLI, and `--safe-mode` verified not to break auth; `TENON_TIMELINE_SNAPSHOT_STATE=running` photographs "Writing the reading — 512 characters"; full suite **1859 / 0** | the silence watchdog has no automated test — no seam for a child process that goes quiet |
| 2026-08-10 | `main`, session `0a29c687` | `AL-FR-036`, `AL-FR-037` (T-110) | 4 tests red first — the tailer projected `AgentToolRun(id: "toolu_cut", name: "Tool", summary: "", state: .succeeded)` from a window cut between a call and its result — then `swift test` **1857 / 0**; window-start tests stable over 3 repeat runs | notice text asserted as a pure rule, not photographed; no live provider run |
| 2026-08-11 | `main`, session `a9355b78` | `AL-FR-040`…`AL-FR-043` (T-123) | Picked up from a session that died mid-implementation, leaving the seams threaded and every choice inside them inert: both spans returned the same 320-fact ceiling, all three lenses returned one identical framing string, `arguments(provider:model:)` ignored its `provider` and always emitted Claude flags, and `generateTimeline()` built a fresh `AgentReadingOptions()` instead of reading the pane's. **Red first, and measured before the first edit: `swift test --filter AgentReadingOptionsTests` → 9 tests, 17 failures**; after → **13 tests, 0 failures**. The Codex invocation was re-verified against the installed CLI in this session rather than trusted from the dead session's notes — `codex exec --help` names `--json`, `--skip-git-repo-check`, `-s/--sandbox`, `-m/--model`, and states that a `-` prompt reads from stdin; `claude --help` still names `fable`, `opus`, `sonnet`. The three tests written for this session's own work were mutation-proved: dropping `readingOptions.select(provider:)` from `loadAvailableReaders` turns `testTheReaderChoiceIsOnlyTheCLIsThisMachineHas` red in 1.0 s. Photographed through the real decoder and validator at both pane bounds — invitation with all four pickers at 900×620 and reflowed two-by-two at 380×620, the finished reading carrying "Read by Claude Code · whole session · milestones", and the failed state at 380×620 showing the controls returning with "Try again". Final full suite **1968 tests, 1 failure, outside this task's file set and pre-existing**: `AgentTranscriptPathTests` (T-126's unfinished work, already recorded in T-127's receipt). An earlier run of the same tree also showed `AgentFleetIntegrationTests` red; it passes 1/0 alone and passed in the final run, so it is load-sensitive on a machine running several agents rather than a defect this change introduced. | 80 facts for `recentWork` is a product judgement no test fixes — the suite only requires it be under the 160-fact fixture and above the six-fact bar. No reading was run against a live Codex CLI: the argument list is verified against `--help`, not against a completed run. The pickers themselves are asserted only as pane rules and photographs; no test drives a menu. |
| 2026-08-11 | `main`, session `9fe92d11` | `AL-FR-038`, `AL-FR-044` (T-131) | **Red first**: an `api_retry` line read as `.ignored` and `AgentRunActivity.explain()` stubbed empty — 3 of 7 assertions red, then green. The line shape is not invented: the installed CLI 2.1.227 names it itself — "Wire twin is SDKAPIRetryMessage ('api_retry')" — and `"api_retry"`, `"error_status"`, `"attempt"` are all in that binary. Measured 2026-08-11: a healthy 320-fact / 91 KB reading first-bytes at 1.4–3.0 s, finishes in 20–21 s, largest inter-chunk gap **3.0 s**; against a loaded endpoint the gaps reach **50.41 s and 46.26 s**, both past the 45 s bound, and a fast-failing endpoint still reaches 39.28 s. So the deadline was killing healthy runs on API weather and reporting silence as the cause. `AgentCLIRetryTests` **9 / 0**, `AgentSessionTimelineTests` **30 / 0**. Corrected within the session: the first cut excused an announced retry indefinitely, arguing the host would otherwise invent a number; a background search of the CLI binary then produced its construction site — `subtype:"api_retry",attempt:…retryAttempt,max_retries:…maxRetries,retry_delay_ms:…retryInMs,error_status:…error.status??null,error:…` — so the delay was on the wire all along and the excuse now expires with it. NOT verified against a genuinely overloaded endpoint — not reproducible on demand. Found on the way and fixed: `read(line:provider:)` routed `.codex` to the Claude reader, leaving `codex(_:)` unreachable; latent only because no path can select Codex until T-123 lands. |
| 2026-08-12 | `main`, session `2b289426` | `AL-FR-049`, `AL-FR-038` (T-137) | Reported from a live pane: "The reading stopped responding after 45s of silence", on a machine where readings were failing routinely. Diagnosed by measurement rather than by reading the code — the installed CLI 2.1.228 was driven with the exact arguments `arguments(provider:.claude,model:)` builds and a 97 KB / 320-fact prompt, timestamping every stdout line. A healthy run emits **192 frames over 126.9 s with a largest gap of 2.62 s**, because `system/thinking_tokens` heartbeats about every 1.4 s even while the model only thinks; the stretch from `system/status status=requesting` to `stream_event/message_start` contains **no frame at all**. So the bound was seventeen times looser than the phase with a heartbeat needs, and invented for the phase without one — which is where a busy API puts a run. T-131's `api_retry` excuse could not reach it: a request that is merely slow announces nothing. `system/status` and `message_start` are now read, the request in flight is accounted for with the ceiling as its sole bound (the answer `silenceSeconds(for: .codex)` already gave to the same question), and the first frame of the reply revokes the account. **Red first and mutation-proved, one mutant at a time**: reading `status: requesting` back as `.ignored` → 14 tests, 1 failure; dropping `!silenceIsExplained` from the expiry rule → 14 tests, 1 failure. Found on the way and fixed: the watchdog rule lived inside a `DispatchSource` handler, which is why T-111's receipt recorded it as having no test seam — it is now `AgentRunActivity.expiry(silenceBudget:ceilingSeconds:)`, and a budget of `0` decides every branch without a clock, closing that seam for the old rule as well as the new. `AgentSessionTimelineTests` caught the change itself: it pinned `message_start` as framing, and that assertion moved rather than being weakened. `AgentReadingSilenceTests` **14 / 0**, `AgentSessionTimelineTests` **30 / 0**, `AgentCLIRetryTests` **9 / 0**, `AgentReadingOptionsTests` **13 / 0**. Full suite **2051 tests, 6 failures, every one in `AgentPrincipalMintTests`** — T-136's untracked red-first work in another lane, left untouched. | Not reproduced against a genuinely slow endpoint; what is measured is the healthy run's frame spacing, and the failure it prevents is inferred from that spacing rather than from a captured stall — the same limit T-131 recorded. No photograph of the `waiting` state: `AgentTimelineSnapshot`'s `running` fixture reports `.writing(characters: 512)` and has no fixture for the phase before the reply starts. `stderr` still does not count as liveness; considered and left alone, because the drained stream was empty in every measured run. Measured alongside and **unexplained**: the same 320-fact reading this PRD recorded at **20–21 s** on 2026-08-11 now takes **127–137 s** with `ttft_ms=129727` and 11752 thinking tokens, and `MAX_THINKING_TOKENS=1024` does not reduce it (8903 thinking tokens on the next run). The ceiling is 4.4× the slowest healthy run observed, so it was left at 600 s. |
| 2026-08-13 | `main`, session `a223b39a` | `AL-FR-050` (T-143) | Reported from the running app as a photograph: every Chat message written over the one below it. Diagnosed by measurement on the shipping composition, not by reading the diff — `AgentSpineChrome`'s `HStack(alignment: .firstTextBaseline)` holds an evidence rail that carries no text and is `maxHeight: .infinity`, and a view with no text answers that guide from its bottom edge, which for a greedy view is the row height the stack has not finished computing. SwiftUI settles the circularity by sizing against the proposal and placing against the final height, so the row hands its lazy parent one box and draws in another. `AgentSessionLayoutAlignmentTests` now mounts the shipping `AgentSpineChrome` — made internal for that reason, as `AgentSessionView` was under T-141 — between two single-child recording `Layout`s, so the row's box and its content's box are read off one pass in one coordinate space. **Red first at both pane bounds**: 63.0 pt of overflow at 320 pt wide, 33.0 pt at 860 pt, and the rail's own test showed the content starting 52.0 pt below the row. Green on `.top`, which is what the line held from the day it was written until `4b1ca5b` — a commit whose message never mentions it and whose stated thesis, to stop measuring text per row, a baseline guide contradicts. `AgentSessionLayoutAlignmentTests` **11 / 0**, the eight pre-existing cost tests in that file unmoved. Full suite **2102 / 0** in 126 s. An independent offscreen probe photographs both alignments side by side in the production container — `ScrollView` over `LazyVStack` — and the shipped one displaces every row's prose into its neighbour's band while `.top` bands cleanly. | The rail was checked against the one shape that reproduces it: only `AgentLensView.swift:814` pairs a baseline-aligned `HStack` with a greedy text-free child; the other ten baseline stacks in `Sources/` align text against text and were left alone. No photograph of the assembled Chat pane — there is no snapshot hook for the Chat account, only Timeline — so `AL-NFR-010`'s installed visual receipt is owed here as elsewhere. An earlier full run of the same tree reported 2 failures whose identity was discarded with the output; the two runs after it are 2102 / 0, and the defect under test is deterministic, so they were not this change — but they are unidentified, not explained. |
| 2026-08-11 | `main`, session `af432f92` | `AL-FR-045`…`AL-FR-048` (T-126) | Picked up from a dead session that had left exactly two untracked files and a live mutation-testing artifact in the source: `AgentTranscriptPath.swift:51` read `root.standardizedFileURL.path  // MUTANT`, resolving symlinks on the candidate but not on the root. That single line had been reddening the shared suite for a day and four peer receipts had written it off as another lane's problem — `swift test --filter AgentTranscriptPathTests` → **10 tests, 1 failure**, `testAnAllowedRootReachedThroughASymlinkStillContainsItsTranscripts`. Restored to `root.resolvingSymlinksInPath().standardizedFileURL.path` → **10 / 0**. The rule was then wired into all three near-copies it was written to replace (`AgentSessionRegistry.candidateURL`, `AgentLensDiscovery.declared`/`validate`) and they were deleted; **the drift those copies were suspected of does not exist** — `AgentSessionRegistry.init` already resolves its roots at construction (`AgentSessionHooks.swift:96`), so the conversion is pure de-duplication and behaviour-identical, which `AgentLens*` **111 / 0** confirms. Red first on the new work: `testARecordedPaneReadsItsTranscriptWithNoTerminalAndNoDiscovery` failed with `nil` messages against a real transcript on disk until the fixture terminated its last line — the tailer is line-oriented — after which the same read lands in **0.071 s** rather than exhausting a 3 s poll, which is the evidence that a recorded pane genuinely reads rather than merely constructing. `AgentRecordedSessionTests` **9 / 0**, `AgentSessionResumeTests` **11 / 0**, `ShippedPluginsTests` **4 / 0** with no manifest edit. Full suite **1988 tests, 0 failures** — but only after `DirectInventoryGateTests` refused the first version of the law edit: it caught the new DIRECT entry as unpinned, the declared inventory size still reading 18, and a justification clause written as **why no new mechanism:** where the gate requires **why not a plugin:** naming the missing thing. The clause now names it — no RESOURCE/STREAM tails a provider transcript for a plugin and no EVENT family carries decoded session facts across the boundary, both absent on purpose under `AL-NFR-003`. An earlier full run in this session read 1987/0 because it predated the law edit. | No photograph was taken of the recorded pane or of the `+ Resume` invitation, so `AL-NFR-010`'s visual receipt is owed for this surface as it is for the others. The end-to-end read test polls a real FSEvents-backed tailer, so it is timing-sensitive by construction even though it now settles in 71 ms. `+ Resume` is asserted as a composition and a pure offer; no test drives the press through to a running shell, because the conversion ends in `SurfacePool`, which needs a window. |
| 2026-08-14 | `main`, session `2c49b6c2` | `AL-FR-053` (T-148) | Favourites for recorded sessions, built entirely behind the public plugin boundary — no Swift, no manifest change, because `tenon.storage` is already a closed scoped facility. `AgentSessionFavouritesTests` drives the shipped `plugins/claude-sessions/main.js` in a real `PluginRuntime` over a bridge answering the five intents its manifest declares: **7 / 0**. The red was not observable when the tests were written — another session had the shared build down on `WorkspaceSidebarView.swift` (`EnumeratedSequence` conformance, macOS 26) and `WorkspaceCatalogStore.swift` — so the tests were proved by **seven mutations applied one at a time, the file restored between each**, every one reddening the test written for it: the plain slice → `…SurvivesTheRecentCutoff`; no by-id lookup → `…FetchedByID`; no storage write → three tests; `indexOfFavourite` dropping the project comparison → `…AnotherProjectNeverAppears`; a silent refusal → `…LeavesTheCommittedListVisible`; the bound removed → `…RecordIsBounded`; a bare glyph → `…NamesItsStateInWords`. The last two were re-run against the final layout. **Photographed, and the photograph changed the design**: the mark first sat in the verb row, and at **420×620** a fourth button broke every label in that row onto two lines ("Detai/ls", "Resum/e") — a control shot with the button removed proved the row was intact before it. The mark moved to the title line, where a narrow pane absorbs it by wrapping the title one line further; re-photographed at **900×620** and **420×620** with the verb row restored to its shipped shape. Full suite **2233 / 0** in 145 s. | The Favourites *group* itself is photographed only through the test tree, not through the app: `PluginViewSnapshot` gives a plugin a throwaway state root by design, so there is no seam to seed a mark before the shot. No live re-open of the app was run to prove a mark survives a relaunch — the persistence claim rests on `tenon.storage.set` reaching the host, which the test asserts, and on `PluginStorage`'s own suite. A plugin cannot read its pane's width, so the mark's label cannot adapt to a narrow pane; what the measurement settled is where the control goes, not that it reflows. |
| 2026-08-13 | current dirty tree | `AL-FR-051`…`AL-FR-052`, tracker `ALR-001`…`ALR-004` | Canonical facts now retain provider or explicitly derived turn identity, stable item/request/task IDs, typed plan/change/context state, and project through one platform-neutral read model. Chat folds consecutive same-turn work into a quiet expandable row without deleting source IDs or evidence; Timeline still digests raw facts. Focused decoder/reducer/read-model suites **28 / 0**, session timeline suite **30 / 0**; full suite **2106 / 0** in 134 s. The production Chat composition was photographed at **900×620** and **380×620**; the living HTML tracker was checked at desktop and **390 px** mobile width with no page-level overflow. | No live provider session was replayed. Rich content blocks, the mobile target, and the independent `libghostty-vt` spike remain `Planned` in the tracker because each needs its own provider fixture or platform/product decision. |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD | consolidate evidence, UI, input, Timeline, history plugin, and fleet gaps |
| 2026-08-13 | Added FR-051/052 | implement the reference-study lifecycle/read-model/work-log slice and make its mobile seam explicit |
