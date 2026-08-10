# Agent Lens

**Status:** implemented for supported provider evidence; explicit degradation retained · **Reviewed:** 2026-08-06

## Decision

Agent Lens is a host-internal semantic projection over a terminal slot whose PTY is
already alive. Session and Terminal are presentation modes of the same slot. Session is
one chronological execution narrative; it does not split conversation from activity.
Switching modes may detach the Ghostty renderer, but it does not replace the
`TerminalSurface`, restart the foreground process, replay input, or discard scrollback.

This change adds no public `tenon.*` path, core intent, audience, control-plane operation,
or plugin runtime capability.

## Product purpose and presentation law

Agent Lens reduces the time required to regain situation awareness for one agent session.
Its default projection answers what the agent is trying to accomplish, what it is doing
now, whether it needs judgment, what materially happened in order, and which claims are
reported versus directly observed. It is not a complete transcript renderer and it does
not replace the terminal as the source of truth.

Presentation follows these rules:

- user and assistant conversation, tool lifecycles, subagent work, interaction requests,
  and diagnostics share one evidence-ordered Session timeline;
- system, developer, project, and skill instructions are context, not execution events,
  and remain collapsed in the inspector unless explicitly requested;
- repeated reads of one skill and adjacent subagent control operations are grouped into
  one inspectable execution unit without discarding their individual evidence;
- pending questions and approvals are elevated into the session summary;
- evidence details remain one action away, while the primary timeline shows only authority
  and freshness needed for safe scanning;
- Markdown tables render as columns only while their natural width fits the pane; a narrow
  pane reflows each row into labeled fields instead of requiring horizontal scrolling;
- Terminal is always available as exact re-entry and the escape hatch for degraded state.

## Interaction classification

| Interaction | Required classification | Implementation |
|---|---|---|
| Built-in SwiftUI reads a snapshot or changes presentation mode | DIRECT | `AgentLensViewModel` and `AgentLensPool` typed Swift calls |
| Built-in composer sends to the foreground TUI | DIRECT | `AgentLensInputQueue` calls guarded `SurfacePool.sendAgentInputFrame` |
| A provider message, tool transition, request, or lifecycle fact already happened | EVENT | `AgentLensEvent`, reduced into an immutable `AgentLensSnapshot` |
| A provider reports root session identity and transcript location | EVENT | `AgentHookServer` authenticates and decodes a bounded hook payload into `AgentSessionRegistry` |
| Claude Code reports a tool starting or finishing, a question waiting, or a turn ending | EVENT | the same authenticated hook payload, projected by `AgentHookLensProjection` into `AgentLensEvent` |
| Answering a question the agent is showing | DIRECT | `AgentLensInputQueue.submitOption` sends one provider-specific selection frame: Claude receives the option hotkey plus Return; Codex receives only the committing hotkey |
| Clicking a file the agent cited in its prose | DIRECT | `AgentFileLinks` resolves the written path; the click calls the typed `WorkspaceStore.openContent(.file(path:))` |
| Transcript watch | RESOURCE/STREAM | one `AgentTranscriptTailer` stream per attached transcript |
| Native provider frame ingestion | RESOURCE/STREAM | `CodexProtocolIngress` over caller-owned transport frames |
| Choosing the Chat or Timeline account | DIRECT | `AgentLensViewModel.account`, published into the pane's ONE header as `PaneHeaderCommand.agentLensAccount` |
| Synthesizing the session into milestones | RESOURCE/TASK | `AgentTimelineSynthesizer` run owned by the pane, arbitrated by `AgentTimelineRunLedger` |

There is no Tenon-level duplex channel for conversation embedded in PTY bytes. PTY input
continues through the existing terminal surface. Semantic output is an independent,
read-only resource projection, and the built-in UI calls its same-owner service directly.

A cited file is evidence-linked compression at its smallest scale. An agent writes
`Sources/App.swift:42` and means "this is where the claim comes from"; the reader should
reach that file without retyping the path. `AgentFileReferenceRule` is the pure rule for
which span is a citation — a path or an extension, never a command, a flag, a URL, or a
bare word — and resolution is what makes the claim checkable: a span links only when it
resolves to a file that exists, relative paths resolve inside the workspace and cannot walk
out of it, and a written link whose path is missing renders as plain text rather than as a
dead return path.

## Ownership and lifetime

- `SurfacePool` owns the terminal surface and PTY, keyed by workspace slot ID.
- `AgentLensPool` owns one main-actor view model per materialized terminal slot.
- `AgentLensViewModel` owns discovery, current attachment, input queue, and coordinator.
- `SurfacePool` mints one unguessable incarnation token per materialized PTY.
- `AgentSessionRegistry` binds a root provider session to `(paneID, surfaceToken)` and
  rejects child-agent, stale-session, stale-incarnation, and wrong-process-group facts.
- `AgentHookServer` owns a loopback-only, bearer-authenticated, bounded EVENT ingress.
- `AgentLensSessionCoordinator` serializes normalized events through a pure reducer.
- Transcript and native-protocol producers own bounded `AsyncThrowingStream` resources.
- `AppComposition` reconciles both pools against `catalog.allSlotIDs`. Closing a slot
  cancels its Lens work; hiding, switching tabs, switching mode, or losing focus does not.
- App shutdown cancels Agent Lens sessions, clears bindings, and closes hook ingress
  before process exit.

## Backpressure and cancellation

Transcript and native protocol streams buffer at most 1,024 normalized events with an
oldest-first policy. A producer that would lose a semantic event terminates with
`AgentLensSourceError.overflow`; the coordinator publishes a gap diagnostic rather than
continuing with a silently incomplete conversation. Transcript records are capped at
2 MB, tool output at 64 KB, the initial transcript window at 8 MB, and projected
collections have reducer-owned capacities.

That window is measured in bytes and opened in meaning. A Claude turn spans records — the
call is named in an `assistant` record and answered in the next `user` record — so a seek
that lands between them would hand the reducer a `tool_result` whose call is on the far side
of the cut, which the decoder can only render as an unnamed finished `Tool`. The tailer
therefore skips forward to the first record `AgentTranscriptDecoder.opensHistoryWindow`
admits: a record holding only tool results opens nothing. One rule covers a record split by
the seek and a record stranded by it, because both are the tail of something whose beginning
is gone. Wherever the visible history begins, `AgentLensSnapshot.earlierHistory` carries the
transcript and byte offset it begins at, so the notice above the conversation states the
boundary instead of merely admitting one exists; in-memory trimming answers with the oldest
message still on screen.

A full attach over a real 5.03 MB transcript measures 96 ms (2,376 records: 28.4 ms
splitting, 61.3 ms JSON, 6.6 ms fingerprints), so re-reading from the window start on every
attachment is cheaper than any cache that would have to be invalidated.

Every resource installs `continuation.onTermination` to cancel its producer. Poll sleeps
propagate cancellation, file handles close with `defer`, the input queue resumes pending
continuations with cancellation, and the session coordinator cancels delayed publishes.

## Session identity and trust

Codex identity is the conjunction of the slot ID, a host-minted terminal-surface token,
the foreground process group, the root `session_id`, and a canonical transcript path.
Tenon installs an additive user-level Codex hook whose command is inert outside a Tenon
terminal. Codex remains the trust owner: a new or changed hook must be reviewed through
`/hooks`; Tenon never forges Codex trust state. The terminal inherits the same explicit
`CODEX_HOME` whose hook file Tenon merged and whose `sessions` directory it validates.

The hook posts only to a random loopback port inherited by that surface, with a per-app
bearer and the surface token. The listener caps headers and payloads, authenticates before
decoding into host state, and the registry accepts only regular, current-user-owned JSONL
files beneath the active `CODEX_HOME/sessions` root. A payload containing `agent_id` is a
child fact and cannot establish or replace the root. Only `SessionStart` may replace a
different bound session, and only when the candidate transcript's filesystem creation
time is newer; delayed facts from the previous session cannot reclaim it.

Without an authoritative Codex hook binding, discovery reports process-only capability.
It never chooses the newest cwd-matching Codex JSONL: real Codex commonly has a Node
foreground process while a native child holds several transcripts, so cwd and mtime do
not identify a conversation. Claude retains its provider-specific recovery behavior.

### Claude Code: the hook is the live spine, the transcript is the record

Claude Code writes its JSONL at turn boundaries. While `AskUserQuestion` is on screen its
transcript holds nothing about that turn at all, so a transcript-only projection is blank
in the one moment supervision exists for. Its lifecycle hooks fire at the moment itself:
`PreToolUse` carries the tool's full arguments before it runs, `PostToolUse` its result and
how it ended, `Notification` a decision waiting on a human, `Stop` the end of a turn.

The two accounts reconcile on the provider's own `tool_use_id`, which the hook and the
transcript both use, so one call stays one run. Where they disagree, each wins on what it
knows: how a run ended is settled by whoever saw it end and is never reopened by a later
record of its start, while the transcript supersedes the hook as *evidence*, because only
it carries a byte offset and fingerprint a person can return to. An answered question is
history and cannot be raised again by the record of it.

Prose is deliberately transcript-only. `Stop` carries the assistant's last message, and
projecting it would put an unanchored claim on the timeline beside the same claim with its
source — the opposite of evidence-linked compression.

Capability follows what is actually running: questions, approvals, and live tool lifecycle
are announced only once a hook from that pane arrives. When installation failed, the pane
says so and offers to repeat it rather than presenting an empty session as normal.

Transcript and protocol content is provider-reported evidence. Direct process identity,
terminal input delivery, command exit state, and file-change state are observed evidence.
Each event carries source, authority, canonical location, byte/frame offset, SHA-256
fingerprint where available, capture time, and freshness. Unknown protocol methods are
ignored; malformed, missing, rotated, oversized, and overflowed sources become explicit
diagnostics. Terminal remains the escape hatch for every degraded state.

## Two accounts of one session: Chat and Timeline

Chat is the verbatim conversational record. **Timeline is an interpretation layer**: an agent
reads the session's evidence and writes the few moments where it materially changed direction
or state — "reproduced the focus loop", "found the competing focus writers", "verified the
fix". It is not one row per prompt, tool call, file edit or hook event, and a reading that is
one row per fact is refused rather than rendered.

The choice is local host UI state. It changes no attachment, restarts no process, sends
nothing to the PTY, and is independent of Session/Terminal/Split — a person can read the
Timeline of a pane that is currently showing both renderers. The picker publishes into the
pane's one chrome header beside the renderer picker and appears only while the Session
renderer is on screen.

### What the model is allowed to decide, and what it is not

The synthesis chooses **grouping and judgement**: which facts belong together, what to call
that, what changed, why it mattered, and whether the work settled. Everything a reader could
check stays the host's answer:

- **anchors** are `AgentTimelineItem` ids copied from the digest. A cited id that is not in
  this session is refused, so a return path never goes nowhere;
- **anchor labels** are written by the host from its own fact, never by the model — a
  citation whose words came from the synthesis could describe evidence that does not say that;
- **time spans** are computed from the anchored facts, so a milestone cannot claim a period
  the evidence does not cover;
- **grouping is a partition.** One fact belongs to one milestone; two milestones claiming the
  same run is double counting, and it is how a reading grows back to the length of the
  transcript;
- **`settled` is checkable and checked.** A milestone standing on a tool the host can see is
  still running, or a question still waiting, cannot claim the work finished;
- **the timeline carries no session-level verdict at all.** Whether the agent is still
  working is `AgentLensSnapshot.status` — observed, live, already on screen — so a reading can
  be stale but never falsely complete.

### Bounds, and failing visibly

Evidence in: at most 320 facts and 96 KiB, newest-first, instructions and loaded skills
excluded as the session's setting rather than events in it. Reading out: at most 12
milestones, at least three facts per milestone, an 80-character title and two
400-character sentences, refused above 64 KiB before parsing. A malformed or out-of-bounds
reading becomes a named failure a person can act on — never partial UI, and never a silent
empty state.

A session with fewer than six facts is reported as too short to be worth reading. An empty
or unattached one says so. None of them spends a model call to rediscover it.

### Newest wins, and the person asks

A reading is explicit: it costs the person a model call, so it happens when they press the
button, and Chat stays live and usable while it runs. A session grows while it is being read,
so two refreshes settle in whatever order the model finishes them — `AgentTimelineRunLedger`
makes newest-wins a property of the run rather than of arrival order, and cancelling advances
past the run in flight so its result can never land afterwards. New facts mark an existing
reading **stale**, which is said on screen; the last true reading is kept until a newer one
replaces it.

The reading itself is produced by the person's own installed agent CLI, run headlessly in a
scratch directory with one turn and no interactive input. `AgentTimelineSynthesizer` is the
seam, so the whole validation half is asserted in `AgentSessionTimelineTests` without a model
call.

The run is read as a stream (`--output-format stream-json`), which decides three things at
once. The pane shows what the run has actually done — connected, then characters written —
because duration and a spinner both keep moving for a process that has died, and the only
question a person is asking is whether this is working. The deadline becomes **silence**
(45 s) under a ceiling (600 s), since a run still writing is alive by observation rather than
by assumption, and the two expiries are told apart on screen. And the run drops the operator's
own environment (`--safe-mode --no-session-persistence`): its one job is to answer in the
schema the host validates, so a custom output style is a hazard to it rather than a help, and
a reading is not a session anybody resumes. Measured 2026-08-10 on a trivial prompt, that
takes a run from 8.1 s wall / 11.3 s CPU with ten of the operator's SessionStart hooks and 120
tools loaded, to 4.5 s / 1.3 s without them.

`AgentCLIStreamReader` is the whole knowledge of the CLI's shape, one line at a time and pure,
so the format is pinned against recorded fixtures instead of a live login.

## Input safety

For PTY-backed sessions, the composer records the foreground PID at attachment. Each
frame is accepted only while the same non-exited process remains foreground. Text is
sanitized for the bracketed-paste terminator, delivered as one bracketed-paste frame,
and followed by carriage return in a separate frame. One actor drains a FIFO so two
submissions cannot interleave. If identity changes between frames, return is withheld,
the send fails visibly, and the UI switches back to Terminal.

Listed options use the provider's actual terminal grammar. Claude's digit moves the picker
highlight and Return accepts it, so both bytes travel in one guarded frame. Codex commits
the digit itself, so no Return is appended where it could leak into the next prompt. The
submitted interaction ID stays latched until the provider advances or resolves the request;
repeat clicks are disabled and cannot send a second answer into the following prompt.

Native structured input is represented as a separate capability. The transcript PTY
adapter never claims approvals, questions, or structured input it cannot safely perform.

## Verification

`AgentLensTests` covers Claude and Codex fixtures, official Codex app-server v2 method
shapes, deterministic replay, optimistic reconciliation, evidence authority, collection
limits, malformed input, stream ordering and overflow, transcript tailing, bracketed-paste
framing, PID refusal, same-surface mode switching, surface-token rotation, authoritative
root binding, stale-session and subagent refusal, path/symlink containment, request bounds,
and idempotent hook installation that preserves unrelated user hooks.
`InteractionBoundaryFitnessTests` asserts that hook ingress remains EVENT, transcript
tailing remains RESOURCE/STREAM, and Agent Lens stays on typed DIRECT calls without
opening a public intent dispatch path.

`AgentSessionTimelineTests` covers the Timeline account: what the digest carries and drops,
grouping, host-written anchor labels and spans, the invented and shared anchor refusals, the
`settled`-over-open-work refusal, field and output bounds, the CLI envelope, newest-wins and
cancellation, the account picker's place in the pane header, and — the load-bearing one — that
a transcript re-emitted one row per fact is refused as a reading of it. Each of those rules was
falsified against a mutated `Sources/`: twelve mutations, each caught by the assertion that
names it. The thirteenth, `cancel()` marking the run settled without advancing the token, is an
equivalent mutant — both forms refuse the in-flight result — and is recorded rather than
"fixed".
