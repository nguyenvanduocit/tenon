# T-111: A reading you can watch happen
> Timeline synthesis streams what it is doing, times out on silence instead of on the clock, and stops paying for a full agent session to write one JSON object.

- **priority**: high
- **effort**: M
- **prd**: `TENON-PRD-012` (`docs/prds/agent-lens.prd.md`) — `AL-FR-031`, `AL-FR-038`

## Owner / files (agent lock)
Released 2026-08-10 18:4x — done and verified.

## Why

Three complaints, one cause. `AgentCLITimelineSynthesizer` runs the CLI with
`--output-format json`, which answers once at the end, so the host has no signal that the run
is alive. Having no signal, it must guess with a fixed 180 s deadline; having nothing to show,
the Timeline can only draw a spinner and a fingerprint. A person watching a long reading
cannot tell a working run from a hung one, and a run that needed 200 s is killed at 180 s with
nothing to show for it.

The CLI already streams. Measured on this machine with a trivial prompt:

| | today (`--output-format json`) | `stream-json --safe-mode --no-session-persistence` |
|---|---|---|
| wall clock | 8.1 s | 4.5 s |
| CPU | 8.22 s user + 3.08 s sys | 0.79 s user + 0.52 s sys |
| NDJSON lines | 24, of which 20 are the user's SessionStart hooks | 4 |
| tools loaded | 120 | 30 |
| model time (`duration_ms`) | 3.0 s | 2.7 s |

So roughly 5 s of every reading is spent booting ten of the operator's hooks and 120 tools to
write one JSON object against a schema the host validates anyway — and each run leaves a stray
transcript in `~/.claude/projects/…`. A custom output style could also break the JSON the
validator requires, which `--safe-mode` removes as a class.

With a live stream, the deadline changes kind: silence becomes the thing worth killing, not
duration. A run still writing is alive by observation.

## Criteria
- [x] `AgentCLIStreamReader` is a pure per-line rule over NDJSON: session announcement, text
      delta, terminal result, error result, and unrecognised line each have one answer.
      `AgentCLIResultEnvelope` is gone, not kept beside it.
- [x] `AgentTimelineSynthesizer` carries progress to its caller; the pane shows what the run
      is doing (connected, characters written) instead of a fingerprint.
- [x] The deadline is silence-based with an absolute ceiling, and the two failures say which
      one happened.
- [x] The CLI runs `--safe-mode --no-session-persistence`, so a reading costs a reading.
- [x] PRD-012 records the changed `AL-FR-031` and the new `AL-FR-038`, with the measurement
      above in the decision log.

## Evidence

`AgentCLIStreamReader` was **red first**: 5 assertions against a stub that answered `.ignored`
for every line, using shapes recorded from the installed CLI rather than invented.

The progress wiring was written before its test, so the test was checked by mutation instead:
returning early from `AgentLensViewModel.note(_:run:)` turns
`testAReadingInFlightSaysWhatItIsDoing` red with "the pane never showed what the run was
doing". Restored from a byte-compared backup afterwards.

Verified against the installed CLI (`--safe-mode` does not break auth — the run returns a
real reply):

```
--print --output-format stream-json --verbose --include-partial-messages
        --max-turns 1 --safe-mode --no-session-persistence
→ {"type":"system","subtype":"init",…}
  {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"{"}}}
  {"type":"result","subtype":"success","is_error":false,"result":"{\"milestones\":[]}"}
```

Suite: `AgentSessionTimelineTests` 30 / 0; full suite reported below.

## Not done

The silence watchdog itself has no automated test — it needs a real child process that goes
quiet, and this suite has no seam for one. The rule it enforces is a two-line comparison over
`ActivityClock`; what is proven is the arguments, the stream reading, and the progress path.
