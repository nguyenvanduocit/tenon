# T-110: History begins where a record stands alone
> A bounded transcript window opens at a record that carries its own meaning, and says where it cut.

- **priority**: high
- **effort**: M
- **prd**: `TENON-PRD-012` (`docs/prds/agent-lens.prd.md`) — `AL-FR-036`, `AL-FR-037`

## Owner / files (agent lock)
Released 2026-08-10 17:2x — done and verified.

## Why

`AgentTranscriptTailer` bounds an attach at 8 MB by seeking to `size - initialWindowBytes`
and dropping the one partial record that seek lands inside. That answers a syntactic
question — is this line whole — while the transcript's unit of meaning spans records: a
Claude turn writes `tool_use` in an `assistant` record and its `tool_result` in the next
`user` record. A cut between them admits the second half alone, and
`AgentLensDecoders.swift:148-160` turns an orphan `tool_result` into
`AgentToolRun(name: "Tool", summary: "", state: .finished)` — an unnamed, already-finished
row that leads nowhere, which is exactly the claim VISION refuses to show.

Measured on a real 5.03 MB transcript: 271 `user` records, 268 of them `tool_result`. The
byte window is cutting through the dominant structure of the file, not a rare edge.

Replay cost is NOT the problem and no cache is warranted: a full attach over that file
measures 96 ms (split 28.4, JSON 61.3, SHA256 6.6 — `scripts`-style probe, 2376 records).

## Criteria
- [x] `AgentTranscriptDecoder.opensHistoryWindow(line:)` is a pure per-provider rule: a
      record consisting only of tool results cannot open a window; a conversational record can.
- [x] The tailer skips forward to the first record that opens the window, so a bounded
      attach never emits an orphan tool completion. `dropsInitialPartialRecord` is gone —
      one concept, not two.
- [x] The oversized-unterminated-record path reuses that same rule.
- [x] `initialWindowBytes` is injectable the way `pollInterval` already is, so the bound is
      testable without writing 8 MB.
- [x] `AgentLensSnapshot.earlierHistoryAvailable: Bool` becomes evidence: which transcript,
      which byte offset the visible history starts at. In-memory trimming names its own
      boundary the same way.
- [x] The Session notice states where the cut is instead of only that one happened.
- [x] PRD-012 carries `AL-FR-036`/`AL-FR-037`, the feature file carries their scenarios, and
      §4 key bounds reads as it now behaves.

## Evidence

Red first, on the real path: with the window landing five bytes inside a call record, the
tailer projected
`AgentToolRun(id: "toolu_cut", name: "Tool", kind: .generic, summary: "", detail: "1854 passed", state: .succeeded)` —
the orphan this task exists to remove. Reducer/notice assertions failed the same run (4 tests,
9 failures).

A second defect surfaced while reading the diff, not from a failing test: the tailer knew the
window offset but published `terminalInference("<path>:bounded-history")`, which carries no
`byteOffset`, so `AL-FR-037` would have been satisfied only in the reducer test and never on
the live path. The stream test now asserts the published evidence names the file and the byte,
and it is what caught the fix landing.

Green: `AgentLensStreamTests` + `AgentLensReducerTests` 12 / 0, stable over three repeat runs;
full suite 1857 / 0.
