# T-089: Agent Lens tells the session as an AI-built milestone timeline
> Beside the chat view, let a person read the session as a timeline of meaningful milestones synthesized by an AI Agent—not as a chronological dump of messages and tool calls.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)

**DONE + VERIFIED 15:2x, session `524f6471`. ALL LOCKS RELEASED** — every file below is free.

New: `Sources/TenonApp/AgentSessionTimeline.swift`,
`Sources/TenonApp/AgentTimelineDigest.swift`,
`Sources/TenonApp/AgentTimelineSynthesis.swift`,
`Sources/TenonApp/AgentTimelineView.swift`,
`Tests/TenonAppStateTests/AgentSessionTimelineTests.swift`.

Edited: `Sources/TenonApp/AgentLensDomain.swift`, `Sources/TenonApp/AgentLensSession.swift`,
`Sources/TenonApp/AgentLensView.swift`, `docs/design-agent-lens.md`,
`docs/architecture-interaction-boundaries.md`.

`Sources/TenonApp/TenonApp.swift` is **not** claimed here — T-071 named it.

## Product shape
Agent Lens gains a `Chat` / `Timeline` presentation choice for the same attached session.
Chat remains the verbatim conversational account. Timeline is an interpretation layer: an AI
Agent reads the session evidence, groups related work, and explains the few moments where the
session materially changed direction or state.

A milestone is something such as “reproduced the focus loop”, “found the competing focus
writers”, “changed the ownership rule”, or “verified the fix”. It is not one row per prompt,
tool call, file edit, or hook event.

## Criteria
- [x] Agent Lens exposes Timeline beside Chat without changing the attached session, terminal, or existing Session/Terminal/Split rendering choice; switching views is local host UI state.
- [x] Timeline generation is performed by an AI Agent over bounded session evidence from the transcript and reconciled hook facts, rather than by relabeling or mechanically listing existing events.
- [x] The generated result is structured into a small number of semantic milestones. Each milestone carries a concise title, its session position or time span, what changed, why it mattered, and its outcome/current state.
- [x] Related prompts, tool runs, edits, retries, and validation steps are grouped under the milestone they support; repetitive exploration and incidental tool noise are omitted.
- [x] Milestones retain evidence anchors back to the underlying chat/session facts so a person can inspect what supports the synthesis instead of trusting an untraceable summary.
- [x] A growing live session can refresh the timeline without replacing a newer result with stale work; generation has explicit loading, progress, cancellation, failure, and retry states while Chat remains usable.
- [x] Empty, short, interrupted, and still-running sessions produce honest states—never invented milestones or a falsely completed outcome.
- [x] The AI-produced structure is validated and bounded before rendering, and malformed or oversized output fails visibly instead of becoming arbitrary UI.
- [x] Host-native Timeline UI follows `docs/designs.md`, including Agent Lens density, semantic colors, keyboard access, VoiceOver labels, and narrow-pane behavior; no feature-local design tokens are introduced.
- [x] The generation lifecycle is classified under `docs/architecture-interaction-boundaries.md` before implementation. If it outlives its initial reply or streams multiple results, it uses the existing RESOURCE/STREAM/TASK path where applicable rather than inventing a finite capability API.
- [x] Headless tests prove milestone grouping, evidence anchoring, bounds, stale-result rejection, cancellation/error states, and that a transcript rendered as a raw event list does not satisfy the Timeline contract; visual verification covers representative long and narrow sessions.

## Non-goals
- A second copy of Chat sorted by timestamp.
- One timeline item for every tool call, message, hook, or file edit.
- Treating AI inference as ground truth when the session contains no supporting evidence.

## What shipped

**Classification first.** The generation is **RESOURCE/TASK** — a bounded, cancellable
producer owned by the pane, inventoried in `docs/architecture-interaction-boundaries.md`
beside the transcript tail. It invents no capability API: no new `tenon` member, no intent,
no principal. The account choice is same-owner DIRECT UI state. The "why not a plugin"
clause names the missing mechanism rather than a difficulty: the law's own EVENT inventory
says host-private agent lifecycle facts "are not exposed to plugins and never enter the
intent dispatcher", so no plugin can read the evidence this reads.

**The design line that carries the feature:** the model decides *grouping and judgement*;
everything a reader can check stays the host's answer. Anchors are ids copied from the
digest and refused if invented. Anchor labels are written by the host from its own facts.
Time spans are computed from the anchored facts. Grouping is a partition. `settled` is
refused over work the host can see is still open. And the timeline carries **no
session-level verdict at all** — so a reading can be stale, never falsely complete.

**The anti-relabelling gate is structural**, not a review note: `milestones × 3 ≤ facts`,
so one row per fact is refused at any session length.

**Evidence.** `swift test` **1583 / 0** (baseline 1557 + 26 new). Thirteen mutations run
individually against a mutated `Sources/`; twelve caught by the assertion that names them,
the thirteenth (`cancel()` settling without advancing the token) identified as an equivalent
mutant and recorded rather than "fixed". Two of those mutations found real weakness and were
fixed before they passed:

- the span test anchored to the head of the session, so "span widened to the whole session"
  was undetectable — it now anchors to the middle;
- `testCancellingLeavesAReadingNobodyIsWaitingOnUnrendered` cancelled before the pane had
  reached the synthesizer, so `release()` released nobody and the test passed having
  exercised nothing. The fixture now waits for entry. Fixing it exposed that
  `Task.isCancelled` was masking the run ledger — two mechanisms for one rule — so the
  ledger is now the sole authority and is proved load-bearing.

**Visual verification** through a new `TENON_TIMELINE_SNAPSHOT` renderer (states, size, and
expanded-evidence knobs; documented in CLAUDE.md). All five states photographed at 900 pt and
at 340 pt: the narrow pane reflows title/metadata onto separate lines and never scrolls
horizontally. The reading is produced through the real decoder and validator, which caught
the first fixture written for it — it claimed `settled` over a still-running `swift test`.

## Found on the way, NOT fixed here — worth their own tasks

1. **The Agent Lens pane header collides its status label with the pane title.** It renders
   as `Runningclaude — tenon`, with zero gap between the last leading item and the title.
   Pre-existing: reproduced with the new account picker removed entirely, and the changes
   panel's header at the same width has a correct gap. Lives in `PaneHeaderLayout`/
   `PaneHeaderProjection` (`pane-chrome`), not in this task's files.
2. **Segmented pickers render macOS blue inside the dark Tenon chrome**, which
   `docs/designs.md` lists by name as an anti-pattern. Also pre-existing and not Agent Lens
   specific — the changes panel's layout picker is blue in the same offscreen mount. Worth
   confirming against the running app before writing the task: it may be that the card
   applies `.tint` and only the snapshot mount lacks it, in which case the bug is in
   `PaneChromePreview` rather than in the product.
