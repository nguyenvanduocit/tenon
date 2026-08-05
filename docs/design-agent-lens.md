# Agent Lens

## Decision

Agent Lens is a host-internal semantic projection over a terminal slot whose PTY is
already alive. Conversation, Activity, and Terminal are presentation modes of the same
slot. Switching modes may detach the Ghostty renderer, but it does not replace the
`TerminalSurface`, restart the foreground process, replay input, or discard scrollback.

This change adds no public `tenon.*` path, core intent, audience, control-plane operation,
or plugin runtime capability.

## Interaction classification

| Interaction | Required classification | Implementation |
|---|---|---|
| Built-in SwiftUI reads a snapshot or changes presentation mode | DIRECT | `AgentLensViewModel` and `AgentLensPool` typed Swift calls |
| Built-in composer sends to the foreground TUI | DIRECT | `AgentLensInputQueue` calls guarded `SurfacePool.sendAgentInputFrame` |
| A provider message, tool transition, request, or lifecycle fact already happened | EVENT | `AgentLensEvent`, reduced into an immutable `AgentLensSnapshot` |
| Transcript watch | RESOURCE/STREAM | one `AgentTranscriptTailer` stream per attached transcript |
| Native provider frame ingestion | RESOURCE/STREAM | `CodexProtocolIngress` over caller-owned transport frames |

There is no Tenon-level duplex channel for conversation embedded in PTY bytes. PTY input
continues through the existing terminal surface. Semantic output is an independent,
read-only resource projection, and the built-in UI calls its same-owner service directly.

## Ownership and lifetime

- `SurfacePool` owns the terminal surface and PTY, keyed by workspace slot ID.
- `AgentLensPool` owns one main-actor view model per materialized terminal slot.
- `AgentLensViewModel` owns discovery, current attachment, input queue, and coordinator.
- `AgentLensSessionCoordinator` serializes normalized events through a pure reducer.
- Transcript and native-protocol producers own bounded `AsyncThrowingStream` resources.
- `AppComposition` reconciles both pools against `catalog.allSlotIDs`. Closing a slot
  cancels its Lens work; hiding, switching tabs, switching mode, or losing focus does not.
- App shutdown cancels Agent Lens sessions before process exit.

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

The foreground PID is the execution identity. Discovery first accepts a canonical JSONL
file currently opened by that PID and under the provider's validated transcript root.
If unavailable, it may recover from a bounded recent scan matched to the terminal working
directory; that resolution is marked inferred and renders a warning. A title or stale
transcript alone never creates a session.

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
framing, PID refusal, same-surface mode switching, and a live-process pipeline from Codex
PID plus open transcript FD through discovery, tailing, reduction, auto-switch, and guarded
input. `InteractionBoundaryFitnessTests` asserts that Agent Lens stays on typed DIRECT
calls and bounded RESOURCE/STREAM adapters, without opening a public intent dispatch path.
