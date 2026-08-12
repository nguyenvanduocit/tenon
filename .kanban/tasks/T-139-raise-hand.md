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

- [ ] `agent.ask.v1` in `CoreIntentCatalog.swift` with exact audience; blocks; returns a typed value
- [ ] The record outlives the asking process — proven by a test that kills the asker and still answers
- [ ] A question addressed to another agent principal routes identically, and nothing is scheduled
- [ ] Contract behaviour asserted in `TenonCoreTests` **without a window**
- [ ] The in-place answer UI replaces "Answer in Terminal" as the primary path
- [ ] `swift test` green **run while the machine is loaded** (T-134)
- [ ] `swift test` needs `--disable-automatic-resolution` here; `xcodegen generate` after any new file
- [ ] PRD rows to `shipped` with a dated receipt

## Owner / files (agent lock)

_Unclaimed._ Expected: `Sources/TenonCore/CoreIntentCatalog.swift`, a new provider under
`Sources/TenonApp/`, `AgentLensView.swift`, tests, `docs/prds/agent-control.{prd.md,feature}`.
⚠️ `CoreIntentCatalog.swift` also appears in T-133's expected set — check the board first.
