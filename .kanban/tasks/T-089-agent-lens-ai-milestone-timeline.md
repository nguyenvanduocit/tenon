# T-089: Agent Lens tells the session as an AI-built milestone timeline
> Beside the chat view, let a person read the session as a timeline of meaningful milestones synthesized by an AI Agent—not as a chronological dump of messages and tool calls.

- **priority**: high
- **effort**: L

## Product shape
Agent Lens gains a `Chat` / `Timeline` presentation choice for the same attached session.
Chat remains the verbatim conversational account. Timeline is an interpretation layer: an AI
Agent reads the session evidence, groups related work, and explains the few moments where the
session materially changed direction or state.

A milestone is something such as “reproduced the focus loop”, “found the competing focus
writers”, “changed the ownership rule”, or “verified the fix”. It is not one row per prompt,
tool call, file edit, or hook event.

## Criteria
- [ ] Agent Lens exposes Timeline beside Chat without changing the attached session, terminal, or existing Session/Terminal/Split rendering choice; switching views is local host UI state.
- [ ] Timeline generation is performed by an AI Agent over bounded session evidence from the transcript and reconciled hook facts, rather than by relabeling or mechanically listing existing events.
- [ ] The generated result is structured into a small number of semantic milestones. Each milestone carries a concise title, its session position or time span, what changed, why it mattered, and its outcome/current state.
- [ ] Related prompts, tool runs, edits, retries, and validation steps are grouped under the milestone they support; repetitive exploration and incidental tool noise are omitted.
- [ ] Milestones retain evidence anchors back to the underlying chat/session facts so a person can inspect what supports the synthesis instead of trusting an untraceable summary.
- [ ] A growing live session can refresh the timeline without replacing a newer result with stale work; generation has explicit loading, progress, cancellation, failure, and retry states while Chat remains usable.
- [ ] Empty, short, interrupted, and still-running sessions produce honest states—never invented milestones or a falsely completed outcome.
- [ ] The AI-produced structure is validated and bounded before rendering, and malformed or oversized output fails visibly instead of becoming arbitrary UI.
- [ ] Host-native Timeline UI follows `designs.md`, including Agent Lens density, semantic colors, keyboard access, VoiceOver labels, and narrow-pane behavior; no feature-local design tokens are introduced.
- [ ] The generation lifecycle is classified under `docs/architecture-interaction-boundaries.md` before implementation. If it outlives its initial reply or streams multiple results, it uses the existing RESOURCE/STREAM/TASK path where applicable rather than inventing a finite capability API.
- [ ] Headless tests prove milestone grouping, evidence anchoring, bounds, stale-result rejection, cancellation/error states, and that a transcript rendered as a raw event list does not satisfy the Timeline contract; visual verification covers representative long and narrow sessions.

## Non-goals
- A second copy of Chat sorted by timestamp.
- One timeline item for every tool call, message, hook, or file edit.
- Treating AI inference as ground truth when the session contains no supporting evidence.
