# T-126: A pane for a session you already had

> Clicking a row in Agent Sessions opens a pane that reads that recorded session with Agent Lens itself — same chat, same evidence inspector, same Timeline — and whose Terminal tab holds no PTY until `+ Resume` turns that pane into the live session.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)

**RELEASED 2026-08-11 23:0x — finished by session `af432f92`.** The files below are free.
Claimed originally by session `0c86fb73`, which died leaving only `AgentTranscriptPath.swift`
and its test untracked, plus a live `// MUTANT` at `:51`.

- NEW `Sources/TenonCore/AgentSessionRef.swift`
- NEW `Sources/TenonApp/AgentTranscriptPath.swift`
- NEW `Sources/TenonApp/AgentLensAttachment.swift`
- NEW `Sources/TenonApp/AgentSessionResume.swift`
- NEW `Sources/TenonApp/AgentSessionResumeView.swift`
- `Sources/TenonCore/Workspace.swift`
- `Sources/TenonCore/WorkspaceCatalogStore.swift`
- `Sources/TenonCore/RecentStore.swift`
- `Sources/TenonCore/CoreIntentCatalog.swift`
- `Sources/TenonApp/WorkspaceIntentProvider.swift`
- `Sources/TenonApp/AgentLensSession.swift` — **attach/lifecycle region only**, never `:372-509`
- `Sources/TenonApp/AgentLensDomain.swift`
- `Sources/TenonApp/AgentLensView.swift`
- `Sources/TenonApp/AgentSessionHooks.swift`
- `Sources/TenonApp/AgentLaunchSuggestions.swift`
- `Sources/TenonApp/BuiltInSlotViews.swift`
- `Sources/TenonApp/PaneHeaderProjection.swift`
- `Sources/TenonApp/EmptyStateCard.swift`
- NEW `Tests/TenonAppStateTests/AgentTranscriptPathTests.swift`
- NEW `Tests/TenonAppStateTests/AgentRecordedSessionTests.swift`
- NEW `Tests/TenonAppStateTests/AgentSessionResumeTests.swift`
- `Tests/TenonCoreTests/WorkspaceOpenContentTests.swift`
- `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`
- `Tests/TenonCoreTests/RecentStoreTests.swift`
- `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`
- `Tests/TenonCoreTests/PluginViewInstanceTests.swift`
- `Tests/TenonCoreTests/DirectInventoryGateTests.swift`
- `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift`
- `Tests/TenonAppStateTests/PaneHeaderProjectionTests.swift`
- `plugins/claude-sessions/main.js` — no manifest change
- `docs/architecture-interaction-boundaries.md`, `docs/prds/README.md`, `docs/design-pane-slots.md`
- `docs/prds/agent-lens.prd.md`, `docs/prds/agent-lens.feature` — **gated, see below**

⚠️ **WIP was 4/2 when this was claimed** (T-120 `b67a9a60`, T-123 `6e4239f3`, T-124 `f3e2d2dc`,
T-125 `819627d6`). Taken on the user's direct request, with the file sets checked for overlap.
Two overlaps exist and both are handled rather than ignored:

- **T-123 holds `AgentLensSession.swift`, timeline section only** (`:372-509` — `generateTimeline`,
  `readingOptions`, `readingOptionsInUse`, `land`, `discardTimeline`). This task touches only the
  attach/lifecycle region and the pool door, by `Edit` and never by `Write`.
- **T-123 holds both `docs/prds/agent-lens.*` files.** The PRD step is therefore last, and the
  requirement IDs are chosen by re-reading the file at write time rather than reserved now —
  `AL-FR-039` / `AL-NFR-011` are today's high-water marks and T-123 may consume the next ones.
- T-123 also holds `AgentTimelineView.swift`; the Timeline account is reused **verbatim** here,
  so that file is not touched at all.

No overlap with T-120 (`TabStripReorderTests.swift`), T-124 (palette/launcher), or T-125
(`AutomationSlotView.swift`).

## Decisions taken with the user

- **After `+ Resume`, the pane becomes a fully live Agent Lens pane** — the reading continues over
  the resumed PTY, chat is typable, and the agent's questions are answerable. Resume converts the
  pane in place rather than opening a second one.
- **No new reading logic.** The user's "a few first and a few last messages" is served by the Agent
  Lens chat spine as it already exists. There is no `Overview` account, no head/tail excerpt type,
  and no elision strip: taking Agent Lens means taking its reading.

## Criteria

- [x] A recorded transcript path from a plugin is refused unless it resolves, after symlinks, to a `.jsonl` under an allowed provider transcript root — refusal is typed and opens no pane
- [x] `SlotContent.agentSession(AgentSessionRef)` exists, yields its pane to another recorded session, and carries provider + session id in `busValue`
- [x] A recorded pane survives capture/restore, and degrades to `.empty` when its transcript is gone
- [x] `AgentLensViewModel` attaches to a transcript with no `SurfacePool`, starts no discovery, and can never report `canSend`
- [x] A recorded pane draws no composer and no answer buttons on a pending request
- [x] The Timeline account works on a recorded session, reusing `AgentTimelineView` unchanged
- [x] The pane holds no terminal surface until `+ Resume`; the button states its reason when the agent is unavailable
- [x] `+ Resume` composes through the one typed agent composer and converts that same pane to a live terminal on the same session
- [x] Agent Sessions rows carry a Details button that opens the pane through `workspace.content.open.v1` with no manifest change
- [x] `swift build && swift test` green; `ShippedPluginsTests` green without a manifest edit
- [x] `docs/architecture-interaction-boundaries.md` DIRECT entry enlarged; PRD requirements + Gherkin landed once T-123's lock clears

## Outcome (session `af432f92`, 2026-08-11)

All eleven criteria are met. Requirements `AL-FR-045`…`AL-FR-048` landed in
`docs/prds/agent-lens.prd.md` with Gherkin in `agent-lens.feature` and a dated receipt;
T-123's lock on those files had already cleared.

Two findings worth carrying forward:

- **The suspected drift did not exist.** `AgentSessionHooks.candidateURL` compared against
  `$0.path` unresolved, but `AgentSessionRegistry.init` (`AgentSessionHooks.swift:96`) already
  resolves every root at construction, so the three copies agreed all along. Converting them
  to `AgentTranscriptPath` is de-duplication, not a security fix, and `AgentLens*` 111/0
  confirms no behaviour moved.
- **The `// MUTANT` line had become accepted noise.** It cost one line to fix and had been
  carried as "another lane's failure" in four separate receipts.

Deviations from the file list, both deliberate:

- `AgentRecordedSessionTests.swift` was written under `Tests/TenonCoreTests/` rather than
  `Tests/TenonAppStateTests/`, because every rule it asserts is a workspace-value rule and
  `docs/tdd.md`'s fitness question puts it in the core suite.
- `WorkspaceIntentProvider.content(from:)` moved out of the file's `private extension` into an
  internal one and became `nonisolated`. It is the door an untrusted caller knocks on, and it
  is now swept directly against real symlinks rather than only through a calling intent.

Not done: no photograph of the recorded pane or the `+ Resume` invitation, so `AL-NFR-010`'s
visual receipt is owed for this surface as it is for the others.

## Verification 2026-08-12 — CONFIRMED

An independent pass re-ran the five filters **37 / 0** and the full suite **2001 / 0** (the count
moved because peer lanes added tests, not because anything here changed), ran
`node --check plugins/claude-sessions/main.js`, confirmed the `DirectInventoryGateTests` diff is
+7 additive lines with no expected value touched, that the `// MUTANT` is gone from
`AgentTranscriptPath.swift:51`, that all five new sources carry `@domain:` on line 1, that the
manifest was not edited (`workspace.content.open.v1` was already declared), and traced all
eleven criteria into source instead of accepting the receipt.

Two evidence defects it found, both about the quality of the proof rather than missing behaviour:

- `Sources/TenonApp/AgentLensAttachment.swift:54,62` — `holdsTerminalSurface` and `offersResume`
  have **zero production consumers**. The no-PTY rule is really enforced structurally at
  `BuiltInSlotViews.swift:116-141`, so the four assertions over those two properties test an
  enum against its own definition and would stay green if the pane started mounting a PTY.
  Either wire them or delete them and let the slot-view seam carry criterion 7.
- `Tests/TenonAppStateTests/AgentSessionResumeTests.swift:141-142` — criterion 6's Timeline claim
  is a get-after-set (`model.account = .timeline` then assert it equals `.timeline`). The
  criterion is true by construction (`AgentLensSession.swift:449-476` reads only `snapshot`), but
  the tick is not backed by a test that could fail.
