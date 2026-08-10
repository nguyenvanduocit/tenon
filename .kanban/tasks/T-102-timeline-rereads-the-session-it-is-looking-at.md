# T-102: Timeline re-reads the session it is looking at
> The "nothing to summarize yet" notice is scored once on appear and never again, so a session that grows past the bar stays unreadable until the pane re-attaches.

- **priority**: high
- **effort**: S

## Owner / files (agent lock)
**RELEASED 12:2x** — session `10d2c332-eb73-4a59-81e8-c1c0fec5fdff` held these from 11:5x
and every one of them is now free.

## The defect, as observed

Live pane `84AEB4CF` in the `tenon` workspace, running `claude` PID 47838, session
`aae57603`. Its transcript is 962 KB / 354 records, created 11:28:05 — far past the
six-fact bar. Timeline showed "Nothing to summarize yet" anyway.

`AgentSessionTimelineView.body` calls `model.prepareTimeline()` from `.onAppear`
(`AgentTimelineView.swift:42`). `prepareTimeline()` guards on `.idle`
(`AgentLensSession.swift:387`), so the verdict is computed **once**, at the instant the
account is mounted — which is normally before discovery has attached (poll interval
750 ms) or before the transcript tail has streamed. The digest then answers `.noSession`
or `.tooShort`, the state becomes `.insufficient`, and:

- `prepareTimeline()` can never run again — its guard now fails.
- the `.insufficient` branch of the view draws a notice with **no button at all**,
  unlike `.failed` (Try again) and `.ready` (Refresh).
- the only path back to `.idle` is `discardTimeline()`, reached solely from `attach()`
  and `stop()`.

So the notice is an absorbing state: correct for one instant, then permanently wrong.

Adjacent brittleness found while diagnosing, left to its own task: Claude Code holds **no
open FD** on its transcript (`lsof -p 47838` → no `.jsonl`), so `openTranscript()`
(`AgentLensSources.swift:197`) is dead for Claude and the hook registry is the only route
to the file. The hook route itself is healthy — `/v1/agent-events` answers 401 on a wrong
bearer and 204 on the real one.

## Approach

Delete the stored verdict rather than add a button to it. Sufficiency is a pure function
of the current snapshot, so it is computed where it is drawn:

- `AgentTimelineGeneration` loses its `.insufficient` case.
- `AgentLensSession` loses `prepareTimeline()`; `generateTimeline()` stays fail-closed by
  returning without starting a run.
- `AgentTimelineDigest.insufficiency(of:)` answers the same question `build(from:)` does,
  sharing `fact(from:)` and stopping at the sixth fact so it is cheap enough to call from
  a view body.
- The `.idle` branch draws the invitation when the session is readable and the honest
  notice when it is not — and re-evaluates on every snapshot change.

## Criteria
- [x] A session that is unreadable when Timeline appears and readable later offers the reading, with no re-attach — `testAnUnreadableSessionBecomesReadableAsItGrows`
- [x] A session that is readable when Timeline appears and stays readable is unchanged — `testThePaneLandsAValidatedReading`, unedited and green
- [x] `insufficiency(of:)` and `build(from:)` never disagree about the same snapshot — `testTheTwoSufficiencyAnswersNeverDisagree`, nine snapshots
- [x] An unreadable session still spends no model call (`AL-FR-025` holds) — `testAnUnreadableSessionSpendsNoModelCall`
- [x] `AL-FR-035` added to the PRD with its scenario in the feature file
- [x] Full suite green; the `TENON_TIMELINE_SNAPSHOT_STATE` pictures still render

## Evidence

- Full suite **1696 / 0** at 12:16 (`swift test`, 149.9 s). An earlier run in the same hour
  showed 3 failures that were gone by this one and were never in files this task opened.
- `AgentSessionTimelineTests` **28 / 0**.
- RED first, and it was the seam test that spoke: with `insufficiency(of:)` stubbed to `nil`,
  `testTheTwoSufficiencyAnswersNeverDisagree` named all five disagreeing snapshots (`noSession`,
  `empty`, `tooShort` at 2, 3 and 5 facts) before the implementation existed.
- Photographed through `TENON_TIMELINE_SNAPSHOT` at `idle` and `insufficient`: a readable
  session draws the invitation and its **Read this session** button; a one-fact session draws
  "1 of 6 facts — this session is still short enough to read in Chat" and no button. Both are
  now the `.idle` branch answering from the live snapshot.

## Known limits

- The live pane was **not** re-verified in the running app. Fixing it there means reinstalling
  and restarting Tenon, which would kill every other session's panes — including the
  `aae57603` session working T-101 in the very pane this bug was found in. Left for the user
  to time.
- The route this bug hid is still single-threaded: `openTranscript()` is dead for Claude Code
  (no open FD, measured), so a hook that never lands means a Claude pane has no transcript at
  all. Timeline now says so honestly and keeps re-asking, but nothing yet re-drives the hook.
  Worth its own task.
- No mutation testing run. The seam test is the substitute for it and is weaker: it proves the
  two answers agree, not that either is right for a snapshot shape no fixture covers.
