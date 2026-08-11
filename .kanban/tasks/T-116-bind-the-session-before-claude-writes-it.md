# T-116: Bind the session before Claude writes its transcript
> Agent Lens shows nothing for the whole gap between an agent starting and its operator's first message, because the binding waits for a file the provider has not created yet.

- **priority**: high
- **effort**: M
- **prd**: TENON-PRD-012 (agent-lens) — AL-FR-012, AL-FR-015, AL-NFR-003

## Owner / files (agent lock)
Released — DONE 2026-08-11 00:0x, session `c254942e`.

## Measured cause

Claude Code buffers a session and writes its `.jsonl` only at the first prompt, back-stamping
the records it already held. Measured in this pane: the first record carries `23:39:52`, the
file was born at `23:40:19` — 27 seconds during which the transcript named by the `SessionStart`
hook did not exist.

`AgentSessionRegistry.materializedBinding` requires `attributesOfItem` to succeed, so the hook's
correct `transcript_path` stayed pending for those 27 seconds. `AgentLensDiscovery.resolve` then
fell to `.processOnly` with `transcriptURL == nil`, and `AgentHookLensProjection` emits nothing
for `SessionStart` — so the pane knew the provider and had nothing to show. The window is as
long as the operator takes to type.

## Design

Trust the declared path at bind time; verify the bytes at open time.

- The registry binds on the path the hook declares, still constrained by `candidateURL` to a
  `.jsonl` under `~/.claude/projects` or `~/.codex/sessions`.
- Ordering stops using `transcriptCreatedAt`, which a not-yet-written file cannot supply. A
  session ID that has been superseded on that surface cannot reclaim the binding — the same
  invariant, stated over the terminal's own event order instead of the filesystem's.
- `AgentTranscriptTailer` checks regular-file and owner uid from the attributes it already
  fetches each poll, which closes the bind→read swap window that existed before this change too,
  and stays silent about a transcript that has not appeared for the first time yet.

## Criteria
- [x] A `SessionStart` naming a transcript that does not exist yet binds immediately
- [x] A superseded session ID cannot reclaim the binding; a new `SessionStart` can take it
- [x] The tailer refuses a transcript that is not a regular file owned by this user
- [x] The tailer reports no diagnostic before the transcript first appears, and still reports one when it vanishes after being read
- [x] `swift build` + `swift test` green; PRD delivery matrix and receipt updated
