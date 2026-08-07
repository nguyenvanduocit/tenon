# T-069: Agent Lens becomes hook-first for Claude Code
> Claude Code writes nothing to its transcript while a question is pending, so the Session view goes blank in the one moment a human is needed. Claude Code's own hooks carry that moment; adopt them as the live spine and keep the transcript for prose and evidence anchors.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
Session 317fbcfc (started 2026-08-06 13:35):
- `poc/Sources/TenonApp/AgentSessionHooks.swift`
- `poc/Sources/TenonApp/AgentHookLensProjection.swift` (new)
- `poc/Sources/TenonApp/AgentLensDecoders.swift`
- `poc/Sources/TenonApp/AgentLensDomain.swift`
- `poc/Sources/TenonApp/AgentLensSession.swift`
- `poc/Sources/TenonApp/AgentLensSources.swift`
- `poc/Sources/TenonApp/TenonApp.swift`
- `poc/Tests/TenonAppStateTests/AgentLensTests.swift`
- `poc/Tests/TenonAppStateTests/AgentHookLensProjectionTests.swift` (new)

- `poc/Sources/TenonApp/AgentLensView.swift` (claimed 14:3x, after T-068 finished and
  released it; session cbf0f2c6 moved on to T-070, which touches `AgentLensMarkdown.swift`
  only)

## Measured, not assumed

A live `claude` session driven through tmux: with a question on screen, sending the single
byte `2` — no return — selected option 2 and the turn continued ("User answered Claude's
questions: … → Blue"). So an answer from the Session view is a keystroke, not text: the
paste-then-return path would type the option's label into a list that accepts digits, and
its trailing return would land on whatever prompt came next.

## Evidence that motivates this
- Transcript `~/.claude/projects/-Users-firegroup-projects-tenon/cbf0f2c6-….jsonl` for the session
  photographed at 13:33 holds one `user` record and stops; no `assistant` record exists while
  `AskUserQuestion` is on screen. Transcript-only projection cannot show a pending question.
- Captured hook payloads (headless probe, Claude Code v2.1.223):
  - `PreToolUse`: `tool_name`, `tool_use_id`, `tool_input`, `permission_mode`, `cwd`, `session_id`
  - `PostToolUse`: adds `tool_response` (Bash `stdout`/`stderr`/`interrupted`; Write/Edit
    `structuredPatch`/`filePath`) and `duration_ms`
  - `Stop`: `last_assistant_message`, `stop_hook_active`, `permission_mode`
  - `SessionEnd`: `reason`
  - `tool_use_id` equals the transcript's `tool_use` block id, so hook and transcript facts
    reconcile on one identity instead of duplicating.
- `toolKind` (`AgentLensDecoders.swift:504`) recognizes Codex tool names only; the tools Claude
  Code actually runs (`Bash` 40, `Read` 13, `Edit` 8, `Write` 5, `Skill` 1 across six recent
  transcripts) all fall to `.generic` and render raw JSON input.
- Claude's `toolUseResult` record field (exit status, `structuredPatch`, output) is never read.

## Result

Shipped hook-first for Claude Code, with the transcript kept as the record rather than
replaced. `AgentHookLensProjection` (new, pure) turns `PreToolUse` / `PostToolUse` /
`Notification` / `Stop` into lens facts; `ClaudeToolFacts` (new, pure) is the one place a
Claude Code tool is named and its result read, asked by both the hook path and the
transcript decoder, so the same call reads the same way whichever account arrives first.
The two reconcile on the provider's `tool_use_id`: a finished run is never reopened by the
later record of its start, an answered question is never raised again, and the transcript
still supersedes the hook as the evidence anchor because only it carries a byte offset.
`AgentHookInstallStatus` records whether installation worked and how to repeat it; the
Session view says so and offers the retry instead of showing an empty pane as if normal.

Left deliberately: `Stop.last_assistant_message` is not projected as prose. It would put an
unanchored claim beside the same claim carrying its source.

## Criteria
- [x] Installer registers `PreToolUse`, `PostToolUse`, `Notification` alongside the existing
      `SessionStart`/`UserPromptSubmit`/`Stop`, replacing the previous Tenon handler generation
      and preserving unrelated hooks — Codex keeps the smaller set its native protocol already
      covers (`testAgentHookInstallerWritesClaudeProviderIntoAdditiveSettingsHook`,
      `testCodexKeepsTheSmallerHookSetItsNativeProtocolAlreadyCovers`,
      `testAgentHookInstallerReplacesLegacyTenonHandlerAndPreservesUnrelatedHook`)
- [x] Hook request decoder accepts the new events and carries tool identity, input, response,
      permission mode, and notification message under explicit bounds — an oversized argument
      document is dropped whole rather than kept half-parsed
      (`testHookRequestCarriesTheToolFactsTheLensProjectsAndBoundsThem`)
- [x] A headless projection turns hook facts into lens events: tool started/finished with real
      exit state, `AskUserQuestion` into a pending interaction carrying its options, notification
      into a waiting-for-user state, `Stop` into completion (11 tests in
      `AgentHookLensProjectionTests`)
- [x] Hook and transcript facts for the same `tool_use_id` reconcile into one tool run
      (`testACompletedToolIsNeverReopenedByALaterRecordOfItsStart`,
      `testAnAnsweredQuestionIsNotRaisedAgainWhenTheTranscriptDescribesIt`)
- [x] Claude Code tool taxonomy is correct (`Bash`→command, `Read`/`Write`/`Edit`→file change,
      `Task`→subagent, `Grep`/`Glob`, `WebFetch`/`WebSearch`, `TodoWrite`→plan, `Skill`) with
      human summaries instead of raw JSON
      (`testClaudeToolsAreNamedByWhatTheyDoInsteadOfTheirRawArguments`)
- [x] Transcript `toolUseResult` supplies completion detail and failure state
      (`testClaudeTranscriptNamesItsToolsAndReadsTheStructuredResultBesideThem`,
      `testClaudeTranscriptRecordsAnAnsweredQuestionAsTheDecisionItWas`)
- [x] Claude capabilities advertise the lifecycle/questions the hook transport really provides —
      announced when a hook from that pane actually arrives, not assumed at attach
- [x] Answering a listed option sends the key that prompt reads and never submits
      (`testAnsweringAListedOptionSendsOnlyThatKeyAndNeverSubmits`; measured against a live
      session first)
- [x] The Lens surfaces hook installation failure with a way to retry from its own UI
      (`AgentHookSetupNotice`, `testAFailedHookInstallCanBeRepeatedFromWhereItIsReported`)
- [x] `swift test` green for this task — 111/111 across every Agent Lens, hook, and
      interaction-boundary suite; `swift build` clean under warnings-as-errors.
      Full suite **1163 tests / 3 failures**, none of them this work and each in a file another
      session holds mid-TDD: `PaletteIntentInvokerTests` (KeyBinding), `PluginInventoryTests`
      (`PluginInstallationStore.swift`, which failed my build with "modified during the build"),
      `RestoredPluginPanesTests` (calls `AppComposition.make`, an API that did not exist when
      this task started). Ruled out as mine rather than assumed: every register/ingest path
      added here is behind `!underTest` (`TenonApp.swift:145`), so none of it runs under XCTest.
      Failure count drifted 3 → 2 → 3 across runs while peers edited the tree.

## Not done, and why

The GUI is the one thing tests cannot see. Nobody has watched a real Claude Code question
appear in a real Session pane and answered it from there — the pieces are each pinned
headless (projection, keystroke alphabet, reconciliation) but the assembled path wants a
human at a window. Human-verify: open a terminal pane, run `claude`, ask it something that
makes it use `AskUserQuestion`, and answer from Session rather than Terminal.
