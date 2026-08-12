# T-139: Raise Hand — the agent asks, in its own words

> The flagship of the declared-first direction. Today an agent that needs a person can only wait to
> be noticed; Tenon guesses at that from pixels, and guesses wrong in exactly the case that matters.

- **priority**: high
- **effort**: M
- **owning PRD**: `docs/prds/agent-control.prd.md` — `AC-FR-038`, `AC-FR-039`, `AC-FR-040`, `AC-NFR-010`
- **depends on**: T-136 (`AC-FR-037`, the agent principal — **shipped 2026-08-12**)

## Why this and not more inference

`IdleDetector.swift:19-27` calls a pane idle when its sample is unchanged three times running. So a
pane **blocked on an approval prompt** — motionless by definition — is the most "idle" pane on the
screen. The one state that needs a human is the state inference gets backwards, and no amount of
better scraping fixes a signal that is inverted at the source.

The current answer path makes it worse. `AgentLensSession.answer` sends `String(choice + 1)` into
the PTY, capped at `choice < 9` (`:649,659-662`) — a nine-option ceiling and a per-vendor key
dialect. And the question itself is recovered by parsing Claude's `AskUserQuestion` tool schema
(`Sources/TenonApp/ClaudeToolFacts.swift:74-92`), so every new agent is another scraper.
`AC-NFR-010` already forbids extending that to add a capability.

Meanwhile the UI's own escape hatch says the quiet part out loud: the button is **"Answer in
Terminal"** (`Sources/TenonApp/AgentLensView.swift:1015`). Tenon sends the person back to the place
it promised to save them from.

## What ships

`agent.ask.v1`, audience `{plugin, cli, agent}`:

- the agent **declares** the question in its own words, with `choices[]`, `evidence[]`, and a
  caller-set `timeoutMs` the host bounds;
- the call **blocks** until answered or expired, and returns a **typed value** — not keystrokes;
- the record is bound to the **pane**, not the asking process, so it survives context compaction,
  provider timeout, and the death of the agent that asked (`AC-FR-039`);
- the question may address a human **or another agent principal**, routed and recorded identically,
  and the host schedules nothing as a result (`AC-FR-040`).

The human sees one card: which pane, which agent, the agent's own words, the choices, the evidence
links, and a countdown on the agent's own deadline. One click answers it.

## Refusals that make it opinionated

- **No `agent.send-keys`.** Already a non-goal at `docs/prds/agent-control.prd.md:222`.
- **No answering Tenon's own policy prompts** — `AC-FR-030` (`:346`).
- **No unbounded question.** `timeoutMs` required, host-capped; invariant 10 holds.
- **No evidence-free question.** Empty `evidence[]` is refused by the contract, per `VISION.md:25-26`.
- **Keystroke answering survives only as labelled lower-authority fallback**, for providers that do
  not declare.

## Criteria

- [x] `agent.ask.v1` in `CoreIntentCatalog.swift` with exact audience; blocks; returns a typed value
- [x] The record outlives the asking process — proven by a test that kills the asker and still answers
- [x] A question addressed to another agent principal routes identically, and nothing is scheduled
- [x] Contract behaviour asserted in `TenonCoreTests` **without a window**
- [x] The in-place answer UI replaces "Answer in Terminal" as the primary path
- [x] `swift test` green **run while the machine is loaded** (T-134)
- [x] `swift test` needs `--disable-automatic-resolution` here; `xcodegen generate` after any new file
- [x] PRD rows to `shipped` with a dated receipt

## Completion evidence

**DONE 2026-08-13 05:5x, Codex goal `019ff7b0`; locks released.** The closed
`agent.ask.v1` contract has audience `{plugin, cli, agent}`, requires one exact human or agent
recipient, 1...16 scalar typed choices, 1...16 evidence anchors and a 1...55,000 ms deadline,
and runs in the eight-wide `agentWait` lane under the dispatcher's 60-second ceiling.
`AgentAskStore` owns at most 64 pane-scoped records; caller cancellation detaches only that waiter,
while answer, expiry and pane close each settle the record exactly once. Exact-principal matching
handles agent recipients through the same store and never creates work.

The installed, signed app was photographed at 900x620 and 420x620. A real System Events AX walk
found named native `AXButton` choices and `AXLink` evidence anchors with stable identifiers and help;
performing `AXPress` on the first choice removed the card, proving the accessibility action reaches
the typed settlement path. The native SwiftUI controls stay visual and pointer-active; a transparent
AppKit accessibility bridge supplies the role/name/action that this macOS build otherwise omitted.
The old provider-extracted path is explicitly labelled `Provider inference` and `lower authority`,
and its terminal action remains only the fallback.

Evidence:

- red-first contract/store/provider/UI coverage; final focused slice **83 tests / 0 failures**;
- loaded full suite with starting load averages `13.64 20.85 22.70`: **2,082 / 0** in 201.061 s,
  using `--disable-automatic-resolution`;
- several earlier loaded runs exposed the already-recorded T-134 timing-flake class; every named
  foreign failure passed in isolation, and the final loaded run was green;
- `xcodegen generate`; current-tree `xcodebuild build-for-testing`: `TEST BUILD SUCCEEDED`;
- SwiftFormat: **0/5 files changed**; domain-tag and interaction-boundary fitness included in the
  focused green run;
- standard screenshot `/tmp/tenon-t139.k1m15z/question-standard-final.png`, SHA-256
  `f4649c530d1a0b7dded12b9068337fbcb91801d46c649df3b29c091bcad818ea`;
- narrow screenshot `/tmp/tenon-t139.k1m15z/question-narrow-final.png`, SHA-256
  `99e254a38f27126c1e3f32979cd4bd29092c29ae4df836f443796c59233e6dd7`.

Honest exclusion: no installed Claude or Codex has invoked this contract end to end yet. The typed
host channel and installed UI are proven independently, but provider adoption remains the true-
provider receipt. Declared status is a separate follow-up (`AC-FR-041`); this slice does not turn
Tenon into a scheduler or ship an agent-to-agent consumer surface.

## Owner / files (agent lock)

Claimed 2026-08-13 by Codex goal `019ff7b0`. Fourth card in Doing under the operator's
explicit keep-working/self-task directive. T-133 is still unclaimed, so its expected catalog
overlap holds no competing lock.

- `.kanban/board.md`
- `.kanban/tasks/T-139-raise-hand.md`
- `Sources/TenonCore/AgentAskStore.swift` (new)
- `Sources/TenonCore/CoreIntentCatalog.swift`
- `Sources/TenonApp/AgentIntentProvider.swift`
- `Sources/TenonApp/AppIntentRuntime.swift`
- `Sources/TenonApp/TenonApp.swift`
- `Sources/TenonApp/AgentLensSession.swift`
- `Sources/TenonApp/AgentLensView.swift`
- `Sources/TenonApp/AgentTimelineSnapshot.swift`
- `Sources/TenonApp/AgentDeclaredQuestionCard.swift` (new)
- `Tests/TenonCoreTests/AgentAskStoreTests.swift` (new)
- `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`
- `Tests/TenonAppStateTests/AgentAskIntentProviderTests.swift` (new)
- `Tests/TenonAppStateTests/AgentLensTests.swift`
- `Tenon.xcodeproj/project.pbxproj` (generated after the new files)
- `docs/architecture-interaction-boundaries.md`
- `docs/prds/agent-control.prd.md`
- `docs/prds/agent-control.feature`
