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
| Answering a question the agent is showing | DIRECT | `AgentLensInputQueue.sendKeystroke` sends the key that prompt reads, never text plus a return |
| Clicking a file the agent cited in its prose | DIRECT | `AgentFileLinks` resolves the written path; the click calls the typed `WorkspaceStore.openContent(.file(path:))` |
| Transcript watch | RESOURCE/STREAM | one `AgentTranscriptTailer` stream per attached transcript |
| Native provider frame ingestion | RESOURCE/STREAM | `CodexProtocolIngress` over caller-owned transport frames |

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

## Input safety

For PTY-backed sessions, the composer records the foreground PID at attachment. Each
frame is accepted only while the same non-exited process remains foreground. Text is
sanitized for the bracketed-paste terminator, delivered as one bracketed-paste frame,
and followed by carriage return in a separate frame. One actor drains a FIFO so two
submissions cannot interleave. If identity changes between frames, return is withheld,
the send fails visibly, and the UI switches back to Terminal.

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
