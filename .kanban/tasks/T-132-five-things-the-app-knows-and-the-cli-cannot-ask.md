# T-132: Five things the app already knows and the CLI cannot ask for

> The capability survey found 127 of 379 rows at XS–S effort. These five are the ones where
> the Swift service exists, is tested, and is reachable only by the host's own UI.

- **priority**: medium
- **effort**: M
- **source**: `docs/reports/2026-08-11-cli-capability-survey.html` (dated evidence, 2026-08-11)
- **owning PRD**: `docs/prds/cli-control.prd.md`; `terminal.prd.md` for (a), `spatial-panes.prd.md` for (c)/(d)/(e)

## Why this and not the other 223

The survey separates capabilities Tenon refuses on purpose from capabilities it merely cannot
reach. Everything below is the second kind: no new behavior, no new architecture, no invariant
touched — a catalog entry with a `cli` audience over a typed service that already runs. The
survey's own strategic read names this the highest value-per-effort group in the report, and
notes it has been sitting unclaimed while richer work went first.

Deliberately **not** in scope: headless/detach/handoff/remote (one architectural decision about
PTY ownership, `Sources/TenonApp/TenonApp.swift:489-510`), a STREAM lane for live pane
observation, and everything under orchestration/browser/remote that `VISION.md:8-9` refuses.

## Items

**(a) `terminal.process.read.v1` — what is actually running in a pane**
`SurfacePool.terminalProvenance(for:)` at `Sources/TenonApp/SurfacePool.swift:341` already
returns `(ttyName, foregroundPID)` per slot and `ProcessTelemetryBridge.swift:41-60` already
assembles this exact map for the in-app monitor. orca answers it with `terminal show --json`,
herdr with `pane process-info`. tenon-cli has nothing. Read-effect, `confirmation: .never`.

**(b) widen the pane node of `workspace.state.v1`**
Add title, cwd, and exited to each pane node. `SurfacePool.swift:445` derives the title from
OSC and `:194` holds cwd per pane. This is the change that turns `tenon-cli state` from a
geometry map into the cheap supervision primitive `orca worktree ps` provides — the survey
names that shape as the nearest thing in either reference to what `VISION.md:18-22` asks for.

**(c) `workspace.tab.close.v1`**
`Workspace.closeTab` exists at `Sources/TenonCore/Workspace.swift:592-629`, fronted by
`WorkspaceStore.swift:119-124`, and its only callers are `ShellTitleBar.swift:152,172,372`.
Closing every pane does not remove the tab today. Classify `.destructive` with
`confirmation: .policy`, matching `workspace.pane.close.v1` at `CoreIntentCatalog.swift:1685-1688`.

**(d) `workspace.pane.split.v1` must return the new paneID**
`WorkspaceIntentProvider.swift:330-339` computes the before/after slot-ID sets, identifies the
new slot, and then discards it through `emptySuccess`. `terminal.open.v1` already returns its
paneID; a scripted caller cannot chain a split without one.

**(e) richer `ping` payload**
`CLICommandExecutor.swift:20-27` returns exactly `{active, pid, protocolVersion}` (verified
live: `{"active":false,"pid":79579,"protocolVersion":3}`). Add app version and socket path.
`AppVersion.swift` is currently read only by `SettingsView.swift:373`, and
`tenon-cli --version` answers `unknown command`. **Constraint:** `CLI-FR-014` scopes ping to
report state *without claiming provider readiness*, and `docs/design-cli.md:186` says it proves
only control-socket liveness — so this widens the payload and must not grow into a health probe.
`DRM-FR-043` walls diagnostics off from the CLI; keep it walled.

## Explicitly gated, do not fold in

`workspace.pane.resize.v1` maps 1:1 onto `Workspace.swift:1344 resizeSlot`, but
`docs/design-pane-slots.md:157` requires "a concrete public use case and explicit bounded
schema" before a move/swap/resize intent exists. Write the use case and get it into the PRD, or
leave it out. A mapping being easy is not the use case.

## Criteria

- [x] Owning PRD read before the first edit; each new requirement carries an ID and a scenario
      — `TERM-FR-026`, `SP-FR-028`, `CLI-FR-027`, each with a tagged scenario in its `.feature`
- [x] (a) `terminal.process.read.v1` returns tty and foreground PID for a named pane, audience includes `cli`
- [ ] **(b) BLOCKED — not a same-major edit.** See the decision below.
- [x] (c) `workspace.tab.close.v1` exists, is `.destructive` with `confirmation: .policy`, and removes the tab
      — plus the refusal the criterion did not anticipate: a workspace's only tab comes back
      `dev.tenon.core.close-refused`, because `Workspace.swift:613` keeps it
- [ ] **(d) BLOCKED — not a same-major edit.** See the decision below.
- [x] (e) `ping` reports version and socket path and still claims no provider readiness
      — `{protocolVersion, pid, active, version, build, socketPath}`, key set pinned
- [x] Every new intent declared in `CoreIntentCatalog.swift` with an exact audience; no invariant weakened
- [x] `swift test` green — **2001 / 0** on one full run; a second full run showed **2001 / 2**, both
      the already-recorded load-sensitive `AgentFleetIntegrationTests`
      `testOneEventHandlerFansOutTwoSupervisedAgentsAndPublishesTheAggregate` (logged by T-114
      and T-123), which passes **1 / 0 in 1.120 s alone** and touches neither new intent.
      Contract behavior asserted in `TenonCoreTests` without a window, provider behavior in
      headless `TenonAppStateTests`
- [x] PRD delivery-matrix rows moved to `shipped` with a dated verification receipt (all three PRDs)

## Decision: (b) and (d) are major mints, not same-major edits

Both criteria name `.v1` and assume the field can be added in place. It cannot:

- (d) `workspace.pane.split.v1`'s output is a **closed object with no properties**. Adding
  `paneID` is exactly "add any top-level input/output field to a closed object", which
  `docs/design-intent-bus.md:620-624` answers **"same major? no"**.
- (b) `workspace.state.v1`'s pane node is a closed object too. `FC-NFR-009`
  (`files-and-content.prd.md:289`) states the rule without the "top-level" qualifier:
  **"Closed schemas MUST not widen inside one major"**; `IAR-NFR-008` repeats it.
- The standing precedent is `filesystem.directory.list.v2`, whose v1 was **removed outright**
  and is pinned by `CoreIntentCatalogTests.testTheDirectoryListingShapeChangeMintedANewMajor…`.

So the correct change is `workspace.state.v2` and `workspace.pane.split.v2`, and that reaches
files outside this task's claimed set — every shipped plugin naming the old id in `uses` breaks
if its manifest is not migrated in the same change:

| Item | Files a correct v2 mint must also carry |
|---|---|
| (b) `workspace.state.v2` | `plugins/{git,file-explorer,core-commands}/{manifest.json,main.js}`, `Sources/TenonCLI/main.swift` (the `state` alias), `Tests/TenonCoreTests/{KanbanPluginTests,WorkspaceScopedViewStateTests,CLIActionParserTests,CLIProtocolTests,CoreCommandsPluginTests,BundledPluginConsentTests,InteractionBoundaryFitnessTests}.swift`, `docs/{design-cli,design-pane-slots,development,architecture-interaction-boundaries,research-reference-terminals}.md`, `docs/prds/cli-control.feature` |
| (d) `workspace.pane.split.v2` | `plugins/{core-commands,file-explorer}/{manifest.json,main.js}`, `Tests/TenonCoreTests/{FileExplorerPluginTests,CoreCommandsPluginTests}.swift`, `docs/{design-command-palette,design-pane-slots,architecture-interaction-boundaries}.md`, `AGENTS.md` |

Recorded in `docs/prds/spatial-panes.prd.md`'s decision log. A follow-up task should claim both
mints together, since they touch the same three plugins.

## Owner / files (agent lock)

**LOCKS RELEASED 2026-08-12 00:1x, session `a4006da9`** — (a), (c), (e) shipped; (b) and (d)
blocked as major mints, see the decision above. Files touched:

- `Sources/TenonCore/CoreIntentCatalog.swift`
- `Sources/TenonApp/TerminalIntentProvider.swift`
- `Sources/TenonApp/CLICommandExecutor.swift`
- `Sources/TenonApp/WorkspaceIntentProvider.swift`
- `Tests/TenonCoreTests/CoreIntentCatalogTests.swift` (inventory 46 → 48)
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` (inventory count only, 46 → 48)
- `Tests/TenonCoreTests/PaneProcessAndTabCloseContractTests.swift` (new)
- `Tests/TenonAppStateTests/PaneProcessAndTabCloseIntentTests.swift` (new)
- `Tests/TenonAppStateTests/CLIPingPayloadTests.swift` (new)
- `docs/prds/terminal.{prd.md,feature}`, `docs/prds/spatial-panes.{prd.md,feature}`,
  `docs/prds/cli-control.{prd.md,feature}`
- `docs/architecture-interaction-boundaries.md` — four inventory rows only. Outside the
  expected set, taken because that file declares the intent inventory and lane map as **closed**
  and adding two intents makes it wrong; the edit is additive and matches the source exactly.

**Not needed after all**: `Sources/TenonApp/AppIntentRuntime.swift`. Both new bindings ride the
existing `TerminalIntentProvider`/`WorkspaceIntentProvider` binding lists, so the composition
root did not change.

⚠️ T-126's lock is released; its `agentSessionContent` diff in `CoreIntentCatalog.swift` and
`WorkspaceIntentProvider.swift` is uncommitted peer work — left untouched.
⚠️ `Sources/TenonApp/TenonApp.swift` was held by T-125 while this ran and is NOT touched: that is
why the ping socket path is resolved inside `CLICommandExecutor` rather than passed by its one
caller. (That lock is clear as of 2026-08-12.)

## Verification 2026-08-12 — CONFIRMED, of the *partial* claim

An independent pass re-ran `swift build` (5.25 s), the three new suites **13 / 0** and the full
suite **2001 / 0** — the load-sensitive `AgentFleetIntegrationTests` flake did not reproduce —
and went after the two things most likely to be excuses:

- **The block defence is factually correct.** `additionalProperties: .bool(false)` is set once,
  in the shared `object()` builder at `CoreIntentCatalog.swift:2554`, so every core schema is
  genuinely closed, including `workspace.pane.split.v1`'s zero-property output and the
  `workspace.state.v1` pane node. `docs/design-intent-bus.md` reads verbatim "Add any top-level
  input/output field to a closed object | no"; `FC-NFR-009` and `IAR-NFR-008` repeat it; and
  `plugins/{git,core-commands,file-explorer}` really do name those `.v1` intents in `uses`.
  Stopping was the correct call, and the criteria for (b)/(d) really are wrong as written.
- **No assertion was weakened.** The seven deleted `XCTAssert` lines in `CoreIntentCatalogTests`
  are the inventory constant 46 replaced one-for-one by 48; `InteractionBoundaryFitnessTests`
  has zero deleted assertions; no `XCTSkip`, `.only`, TODO or stub in the three new test files;
  `Sources/TenonCLI/main.swift` is untouched, which independently confirms that
  `tenon-cli --version` is still an unknown command.

**The status fact this Done entry must not hide: two of five items are undelivered.** The
follow-up — `workspace.state.v2` + `workspace.pane.split.v2` as one task, since they touch the
same three plugins — has no board entry of its own yet. Its exact file lists are in the table
above and in the `spatial-panes` decision log.
