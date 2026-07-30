# T-020: Interaction boundary law
> Make every Tenon interaction use one deterministic, machine-enforced classification.
- **priority**: critical
- **effort**: XL

## Criteria
- [x] One normative decision law classifies direct calls, intents, events, resources, contributions, scoped facilities, pure utilities, and control-plane operations. — `docs/architecture-interaction-boundaries.md` (accepted, normative); `design-intent-bus.md:228-254` defers to it correctly.
- [x] Every existing Swift, plugin-runtime, shipped-plugin, CLI, and documentation surface is inventoried and reconciled. — audit at `.kanban/reports/t020-boundary-audit.md`; one residual hole (plugin `globalThis` scope, Finding 1) reported with a verbatim patch design.
- [x] Internal app code has no generic app intent principal or dispatcher shortcut. — `InteractionBoundaryFitnessTests.swift:6-56` (kinds pinned, dispatcher + principal-construction allowlists).
- [x] Shipped plugins use manifest-declared intents and the closed runtime surface only. — static fitness `ShippedPluginsTests.swift:50,:75` + independent sweep of all 9 plugins (audit report, PASS table).
- [x] Architecture fitness tests reject undeclared surfaces, stale request paths, and audience drift. — all four legs enforced and the last one mutation-proven by the final slice (00:32): stale paths (`CLIIntentBusBoundaryTests.swift:5`), audience drift (`CoreIntentCatalogTests.swift:538`), undeclared `tenon.*` (`PluginBuiltinsTests.swift:86`), and `globalThis` scope closure (`PluginBuiltinsTests.swift:143`, landed by T-037 at `2b6a385`) — verified load-bearing, not assumed: GREEN 00:32:02 → `delete globalThis.console;` removed from `PluginRuntimeBootstrap.swift:8` → RED 00:32:58 for the right reason (both asserts, `"console"` visible in the actual global list) → restored byte-identical (sha256 match, clean `git status`) → GREEN. Also observed working live at 00:39: T-006's in-flight `tenon.palette` member turned both surface pins red exactly as designed, pending their same-change pin update.
- [x] Intent providers and CLI contracts agree with their schemas. — `AppIntentRuntime.validateBindingInventory` (`AppIntentRuntime.swift:298-315`) + strict CLI parser (`CLIAction.swift:125-138`) + `CoreIntentCatalogTests.swift:91`.
- [x] Swift 6 warnings-as-errors **build** passes, enforced. — the flag now exists:
  `.unsafeFlags(["-warnings-as-errors"])` on all seven first-party targets
  (`Package.swift`; `.treatAllWarnings(as:)` probe-verified unavailable at tools 6.1),
  vendored/dependency/GhosttyKit targets excluded, and the 00:44 full build under it is
  **exit 0 with only the 2 prebuilt ImGui linker warnings still warnings**. Two real
  Swift warnings found by full-recompile sweeps (incremental builds had hidden them) were
  fixed first: `WorkspaceCatalogStore.swift:557`, `LauncherCommandsTests.swift:103`.
  The **full-suite-pass half: 750 tests / 741 pass at 00:52 under the flag** — all 9 red
  test cases live in ONE untracked in-flight file (`PaneAttentionTests.swift`, T-029 app
  half `task_f3b0bcbc0314`, textbook TDD-RED: every assert `nil ≠ Optional`); T-006's two
  pin reds from 00:39 resolved when they updated the pins in their own change. The whole
  live tree — committed + both workers' in-flight sources — already compiles clean under
  warnings-as-errors. One green run once T-029's app half wires its machinery closes it.
- [x] An independent verifier approves the integrated result. — **APPROVED at `e3c5435`**
  by the final slice (Orca `task_a4f813d702ff`), with findings ranked and the in-flight
  T-006 delta explicitly excluded: `.kanban/reports/t020-final-verification.md`.

## Owner / files (agent lock)
- **RELEASED 2026-07-31 00:5x by Orca worker `task_a4f813d702ff`** — final slice complete,
  all 8 criteria ticked, verdict APPROVED at `e3c5435`
  (`.kanban/reports/t020-final-verification.md`). No file is claimed by this task now.
  Uncommitted writes awaiting the coordinator: `poc/Package.swift` (the flag),
  `poc/Sources/TenonCore/WorkspaceCatalogStore.swift` + 
  `poc/Tests/TenonCoreTests/LauncherCommandsTests.swift` (one-word warning fixes),
  this task file, the report, board lines.
- Historical record of the slice's claims below.
- CLAIMED 2026-07-31 00:29 by Orca worker `task_a4f813d702ff` (dispatch `ctx_39a78acca18a`,
  terminal `term_05bb75aa-e4b0-45b8-a8ba-e84c4fc058c8`) — FINAL SLICE: last 3 criteria
  (fitness-gap verify, warnings-as-errors decision, independent verifier pass).
- Files claimed for WRITE: `poc/Package.swift` (warnings-as-errors flag, applied LAST and
  only if the tree is warning-free at that moment), this task file, NEW
  `.kanban/reports/t020-final-verification.md`, own board lines.
- ADDED 00:38: `poc/Sources/TenonCore/WorkspaceCatalogStore.swift` line 557 ONLY — the
  full-recompile warning sweep found the tree's single Swift warning there (redundant
  `await` on a sync same-actor call, committed in `05d0d46`; T-027 released 00:05,
  T-031's follow-up committed 00:32, so the file is free). One-word fix so the
  warnings-as-errors criterion can be enforced without breaking anyone.
- ADDED 00:42: `poc/Tests/TenonCoreTests/LauncherCommandsTests.swift` line 103 ONLY —
  the second full sweep (test targets included) found the one remaining Swift warning
  there (redundant `try` on non-throwing `PluginLoader.discover`, committed in
  `df15971`; T-022 done + released, not in T-006's claim). One-word fix for the same
  reason.
- One temporary save/mutate/restore window on
  `poc/Sources/TenonCore/PluginRuntimeBootstrap.swift` (free — T-037 released 00:23) to
  prove the scope-closure test load-bearing; restored byte-identical, verified via git diff.
- Everything else read-only. NOT touching T-006's files (CommandIndex, CommandAggregation,
  PluginHost, PluginRuntime, PaletteOverlay, LauncherMenu, plugins/**) nor T-031's
  (SurfacePool, SpatialCanvasView, BuiltInSlotViews, GhosttySurface, TerminalSurface,
  TenonApp.swift, WorkspaceCatalogStore).

## Evidence — re-verified 2026-07-30 23:5x by Orca worker task_78e0ddf7a663
All three original defects were resolved by commit `8620bc3` and nobody had re-checked
since; per-item proof in `.kanban/reports/t020-boundary-audit.md` Part 1:
- `docs/design-intent-bus.md:228-254` now states the full ordered ladder including the
  same-owner DIRECT ownership test and defers exact definitions to the normative law.
- `poc/Sources/TenonApp/AppIntentRuntime.swift:19-24` is `palettePrincipal` (`.palette`),
  a lawful public-adapter principal with a production caller
  (`PaletteIntentInvoker.swift:77`); no generic app kind can exist
  (`InteractionBoundaryFitnessTests.swift:6-15`).
- `poc/Sources/TenonApp/CLICommandExecutor.swift:18-78` is a thin control-plane adapter
  (ping/app.focus direct; list/describe/send via the kernel); the legacy duplicate verbs
  are fitness-pinned out (`CLIIntentBusBoundaryTests.swift:5-80`).
