# T-169: A reading survives its own startup, and cites facts it cannot misspell
> Two defects in one feature, measured rather than argued: the silence deadline runs during a
> window the CLI is structurally unable to speak in, and a reading is thrown away whole when the
> model mistypes one of ninety UUIDs it was asked to copy by hand.

- **priority**: critical
- **effort**: L

## Owner / files (agent lock)

**DONE + VERIFIED 2026-08-16 02:0x, session `ee649e9f`. ALL LOCKS RELEASED** — every file below
is free. `Sources/TenonApp/TenonLog.swift` was taken additively (one new category) and is
released too; `AgentTimelineDigest.swift` was read but never edited.

- `Sources/TenonApp/AgentTimelineSynthesis.swift`
- `Sources/TenonApp/AgentSessionTimeline.swift`
- `Sources/TenonApp/AgentTimelineDigest.swift`
- `Sources/TenonApp/AgentTimelineView.swift`
- `Tests/TenonAppStateTests/AgentSessionTimelineTests.swift`
- `Tests/TenonAppStateTests/AgentReadingSilenceTests.swift`
- `docs/prds/agent-lens.prd.md`, `docs/prds/agent-lens.feature`

## The evidence this was opened on

The operator reported Timeline failing with **“The reading stopped responding after 45s of
silence”**. The whole pipeline was re-run outside the app against real transcripts, on the
installed CLI 2.1.233, with the exact arguments `AgentCLITimelineSynthesizer.arguments` builds.

| session | facts | prompt | wall clock | verdict |
|---|---|---|---|---|
| `2c49b6c2` | 215 | 48.8 KB | 276.9 s | **refused** — `inventedAnchor` |
| `524f6471` | 226 | 56.6 KB | 247.3 s | accepted |
| `4d775ec5` | 320 | 82.6 KB | 379.3 s | accepted |

**The heartbeat the 45 s budget was measured against is still there.** A frame-by-frame probe of
a healthy 201.6 s run on 2.1.233 counted 69 `system/thinking_tokens` frames at ~2.1 s apart and a
**worst unexcused gap of 2.2 s** against a 45 s budget. The comment at `AgentTimelineSynthesis.swift:506`
is still true. So the deadline is not misfiring mid-reply.

**It misfires before the reply.** `AgentRunActivity` is constructed with `explainedUntil = nil`
(`AgentTimelineSynthesis.swift:307`), so the budget is armed from `process.run()` — but the
first thing the CLI can possibly say is `system/init`, and reaching it takes:

| concurrent readings | time to first frame | share of the 45 s budget |
|---|---|---|
| 1 | 15.7 s | 35% |
| 4 | 19.7–20.6 s | 46% |
| 8 | 22.2–**25.3 s** | **56%** |

Two things fill that window and both scale the wrong way. Node cold start is one. The other is
structural: **the macOS pipe buffer measures 65 536 bytes and the digest prompt is 48.8–82.6 KB**,
so `input.fileHandleForWriting.write(Data(prompt.utf8))` (`AgentTimelineSynthesis.swift:773`)
blocks until the CLI drains it — measured at 2.2–11.0 s, growing with both digest size and load.
The CLI cannot emit its first frame until it has been handed a prompt it is still being handed.

This is the one stretch of a healthy run where quiet is guaranteed and the host counts it as
death. The file already states the rule that settles it, for the *other* quiet window:
“where the CLI publishes no heartbeat, silence is not evidence, and the absolute ceiling is the
only honest bound” (`AgentTimelineSynthesis.swift:344-346`). Startup publishes no heartbeat
either.

Environment was measured and excluded: first frame at 7.9 s under a shell environment and 9.8 s
under the launchd-minimal environment a bundled app actually carries.

**Confidence.** That the window is unexcused and is the largest unexcused gap in a healthy run:
**HIGH**, measured above. That it is what killed the operator's run: **MEDIUM** — no crossing of
45 s was reproduced on this machine, and the operator's real load (Swift compiles beside several
agent panes) is heavier than eight idle node starts. Timeline synthesis writes **no log at all**
(`rg 'TenonLog' Sources/TenonApp/AgentTimeline*.swift` → empty), which is why the MEDIUM cannot
be closed from the machine and why a receipt is part of this task rather than a nicety.

## The second defect, found on the way

Run `2c49b6c2` returned eleven usable milestones and one anchor the session never contained:
`message-c9f48eda-83a9-4b4d-b8f9-none` — a real UUID prefix with an invented tail. `validate`
returns on the first contradiction (`AgentSessionTimeline.swift:254-256`), so **277 seconds of
work were discarded over one of roughly ninety hand-copied 44-character ids**.

The copying is the defect, not the model. A reading cites facts by transcribing opaque UUIDs
into JSON; nothing about that task is inherent to the product. Milestones already render as time
spans — `startedAt`/`endedAt` are host-computed as the min and max of the anchored facts — so the
unit the model is really choosing is a *stretch of the session*, and it is being asked to express
it as a scattered set of identifiers instead.

## What changes

1. **Silence is not evidence until the CLI has spoken once.** A run is excused from the silence
   budget until its first frame, exactly as the post-request wait already is; the absolute
   ceiling stays the only bound on a run that never speaks. `.launching` keeps saying so on
   screen.
2. **The reading cites cut points, not identifiers.** Facts are numbered in the prompt and a
   milestone is an inclusive index range with the few indices inside it that are its evidence.
   The host maps indices back to fact ids, so `inventedAnchor` and `sharedAnchor` stop being
   things a reading can fail on and become things it cannot express. Anchor labels, spans and
   ordering stay host-derived exactly as `AL-FR-027` requires.
3. **A reading says what happened to it.** Start, provider, digest size, terminal state and
   duration reach `TenonLog`, so the next failure is read rather than reconstructed.

## What the change measured, after it landed

Same three transcripts, same CLI, same arguments — v1 (anchor lists) against v2 (spans):

| session | facts | v1 | v2 |
|---|---|---|---|
| `2c49b6c2` | 215 | 276.9 s, **refused** (`inventedAnchor`) | **45.6 s, accepted** |
| `524f6471` | 226 | 247.3 s, accepted | **77.0 s, accepted** |
| `4d775ec5` | 320 | 379.3 s, accepted | **55.4 s, accepted** |

Replies fell from 8.3–11.3 KB to 5.5–6.6 KB and prompts by 13–14%, which is where the wall
clock went. Two of the three prompts now sit **below** the 65 536-byte pipe buffer, so the
blocking handover that filled the startup window disappears for them rather than shrinking.

**The suite did not catch the one thing this change broke.** With 2291 / 0 green, all three live
readings were refused for `oversizedSpan`: real phases run **28–43 facts** and the old ceiling of
24 was sized for how many *citations* a person can read, not how long a phase of work is. No
fixture had a span that wide. The bound is now half the digest — a product judgement that a
reading is more than one milestone, and not a measurement.

## Criteria
- [x] A run that says nothing for longer than the silence budget before its first frame is
      **not** stopped; one that goes quiet that long after its first frame still is. Both
      asserted against `AgentRunActivity` without starting a process.
- [x] The absolute ceiling still stops a run that never speaks at all.
- [x] The prompt numbers its facts, and the instruction and the decoder are held to one schema
      by a test, as `AgentTimelinePrompt.schemaLine` already is.
- [x] A milestone whose range falls outside the digest is bounded into it rather than inventing
      a fact; a reading whose ranges overlap after ordering cannot render two milestones over one
      fact.
- [x] Every milestone still carries at least three facts, host-written anchor labels, and a span
      recomputed from the facts rather than accepted from the model.
- [x] `settled` is still refused over work the host can see is open.
- [x] Timeline synthesis writes a start and a terminal line to `TenonLog`.
- [x] `swift build` + `swift test` green — full suite **2292 / 0** in 141 s;
      `docs/prds/agent-lens.prd.md` and `.feature` updated (`AL-FR-027`, `AL-FR-028`,
      `AL-FR-049` reworded, `AL-FR-054` added, dated receipt appended).
      `TENON_TIMELINE_SNAPSHOT_STATE=ready` photographed: four milestones, each anchor row
      resolving and each span host-written.
