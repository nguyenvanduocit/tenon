# T-123: The reading takes the options you pick

> Timeline generate is one button with every choice compiled in. A person reading a session
> can choose nothing about how it is read: not which agent and model does the reading, not
> how much of the session it covers, not what the reading is looking for.

- **priority**: high
- **effort**: L
- **prd**: TENON-PRD-005 agent-lens (`AL-FR-040`…`AL-FR-043`)

## Owner / files (agent lock)

DONE 2026-08-11, session `a9355b78`. Locks released — the files below are free.

- NEW `Sources/TenonApp/AgentReadingOptions.swift`
- `Sources/TenonApp/AgentTimelineSynthesis.swift`
- `Sources/TenonApp/AgentTimelineDigest.swift`
- `Sources/TenonApp/AgentTimelineView.swift`
- `Sources/TenonApp/AgentTimelineSnapshot.swift`
- `Sources/TenonApp/AgentLensSession.swift` — the timeline section only
- `Tests/TenonAppStateTests/AgentSessionTimelineTests.swift` — `AgentReadingOptionsTests` lives
  here rather than in a file of its own: it is built on the `private enum Fixture` that file
  owns, and a separate file would have to copy the fixture rather than share it. One suite, one
  set of fixtures.
- `docs/prds/agent-lens.prd.md`, `docs/prds/agent-lens.feature`

## What is true today

Every choice a reading could offer is a compile-time constant:

| choice | where it is fixed |
|---|---|
| which CLI | `AgentTimelineSynthesis.swift:372` — first suggestion whose agent is `.claude` |
| which model | nowhere — no `--model` is passed, so the CLI's default decides |
| how much session | `AgentTimelineDigest.swift:86` — `maximumFacts = 320`, always |
| what to look for | `AgentTimelinePrompt.text(for:)` — one instruction, no parameter |

`generateTimeline()` (`AgentLensSession.swift:394`) takes no arguments, so there is no seam a
choice could arrive through even if the UI offered one.

## The shape

One value, `AgentReadingOptions`, carried with the request and threaded to the three places
that already exist — the digest, the prompt, the CLI invocation. No new state machine: the
options are an input to the run the ledger already governs.

**The lens changes the framing and nothing else.** The JSON schema, the anchor rules, the
host-written labels and spans, the compression gate and the `settled` refusal are identical
across every lens. This is the whole safety argument: a person choosing a different reading
is choosing what the model is asked to notice, never what the host will accept as checkable.

**A model is spelled with the provider's own documented alias.** Measured from the installed
CLIs on 2026-08-11: `claude --help` names `fable`, `opus`, `sonnet` as aliases; `codex exec`
takes `-m/--model`, `--json`, `--skip-git-repo-check`, `-s read-only`, `--ephemeral`.
Inventing a model id would fail at run time in a way no test here could catch, so only
aliases the CLI documents are offered.

**A narrower span is a different question.** The digest fingerprint is computed over the
facts, so cutting the span changes the fingerprint — the staleness rule and the
newest-request-wins ledger keep working unchanged.

## Criteria

- [x] A reading is requested with options; the options it was taken with are visible on the finished reading.
- [x] Reader choice offers only installed providers; model choice uses that provider's documented aliases and defaults to the CLI's own default.
- [x] Span bounds the digest before synthesis, never lowers the six-fact bar, and a narrower span yields a different fingerprint.
- [x] Every lens produces the same schema and passes the same validator; no lens can widen what the host accepts.
- [x] Options survive cancel/retry/refresh; a run in flight keeps the options it started with.
- [x] Headless tests red first; the invitation card is photographed at both pane widths.

## Non-goals

- Auto-refresh / cadence. T-089 made generation explicit on purpose — a reading costs a model
  call — and the user did not ask for it here.
- Per-workspace persistence of the chosen options.

## Verification 2026-08-12 — CONFIRMED

An independent pass was told to refute this and could not. It re-ran
`AgentReadingOptionsTests|AgentSessionTimelineTests` **43 / 0** and the full suite **2001 / 0**
(the `AgentTranscriptPathTests` red in the receipt is gone — T-126's owner fixed it); found the
test-file diff to be +308/−2 with both deletions mechanical signature updates, no assertion
removed, weakened or renamed out of a filter, and no `XCTSkip`/TODO anywhere in the six source
files; re-checked `codex exec --help` and `claude --help` on this machine against the flags the
code emits; read each of the four choices at source to confirm it bites rather than merely
exists; and viewed the photographs rather than trusting them.

One defect it found that this task did not record: `Sources/TenonApp/AgentTimelineSynthesis.swift:574`
keeps a `--model <alias>` branch in the `.codex` arm that no product path can reach, because
`AgentReadingModel.choices(for: .codex)` is `[.providerDefault]` and `AgentReadingOptions.init`
clamps to it. Harmless, but it is a branch kept "just in case", which `CLAUDE.md`'s replacement
rule disallows. Not re-opened for it; delete it in the next change that touches the file.

Limits it could not close, both already stated above: red-first cannot be reproduced after the
fact without reverting the work, and no reading has been run against a live Codex CLI.
