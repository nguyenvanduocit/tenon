# T-137: The quiet before the model answers is not a hang

> A reading dies at 45 s of silence in the one phase where the CLI emits no heartbeat at all —
> between "I sent the request" and the model's first token. Measured, that is the only unbounded
> quiet a healthy run has.

- **priority**: high
- **effort**: S

## Owner / files (agent lock)

Released 2026-08-12 14:30 — session `2b289426` is done with all of these. Files touched:

- `Sources/TenonApp/AgentTimelineSynthesis.swift`
- `Tests/TenonAppStateTests/AgentReadingSilenceTests.swift` (new)
- `Tests/TenonAppStateTests/AgentSessionTimelineTests.swift` (one line: `message_start` left the
  framing list, which is exactly the assertion that caught this change)
- `docs/prds/agent-lens.prd.md`
- `docs/prds/agent-lens.feature`

## What was measured

Against the installed Claude CLI 2.1.228 on 2026-08-12, with the exact arguments
`AgentCLITimelineSynthesizer.arguments(provider:.claude,)` builds and a 97 KB / 320-fact prompt:

| phase | heartbeat the CLI emits | observed quiet |
|---|---|---|
| spawn → `system/init` | none | 1.7 s |
| `init` → `system/status status=requesting` | none | ~0 s |
| **`requesting` → `stream_event/message_start`** | **none** | 1.8 s idle API; **unbounded under load** |
| streaming | `system/thinking_tokens` every ~1.4 s | max **2.62 s** over 192 lines / 126.9 s |

So the 45 s bound is seventeen times looser than it needs to be in the phase that has a heartbeat,
and is an invented number in the phase that has none. T-131's `api_retry` excuse only covers quiet
the CLI announced as a backoff; a request that is merely slow to start announces nothing.

Second measurement worth recording: the same reading now costs **11752 thinking tokens** and
`ttft_ms=129727`, against the **20–21 s** whole run recorded in this PRD on 2026-08-11. The run got
six times longer, which widens every window in which it can be killed.

## Criteria

- [x] `system/status` with `status: requesting` is read as its own event, not as framing
- [x] `stream_event/message_start` is read as the reply starting, and revokes the excuse
- [x] Quiet between those two is accounted for, so the ceiling is its only bound — same rule Codex
      already gets, for the same reason
- [x] Once the reply is arriving, unexplained silence is a deadline again
- [x] The pane says the run is waiting on the model rather than showing the same line it shows while
      reading
- [x] `AL-FR-049` written; `AL-FR-038` bound restated; receipt appended

## What was found on the way

The watchdog rule lived inside a `DispatchSource` event handler, which is why T-111's receipt
recorded "the silence watchdog has no automated test — no seam for a child process that goes
quiet". It is now `AgentRunActivity.expiry(silenceBudget:ceilingSeconds:)`, a pure question asked
of what the run has said, and a budget of `0` makes every branch decidable without a clock. That
closes the seam T-111 left open, for the old rule as well as the new one.

## Owed

- No photograph of the `waiting` state: `AgentTimelineSnapshot`'s `running` fixture reports
  `.writing(characters: 512)` and there is no fixture for the phase before the reply starts. The
  file was not claimed by this task.
- Not reproduced against a genuinely slow endpoint — the same limit T-131's receipt records. What
  is measured here is the healthy run's frame spacing, which is what makes the phase boundary
  decidable; the failure it prevents is inferred from that spacing, not from a captured stall.
- `stderr` still does not count as liveness. Considered and left alone: the drained stream was
  empty in every measured run, so there is no evidence a healthy run speaks there while stdout is
  quiet.
