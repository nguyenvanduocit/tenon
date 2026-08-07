# T-020 boundary audit — actionable slice, 2026-07-30

Worker: Orca `task_78e0ddf7a663` (dispatch `ctx_e1f6fafce1bd`). Tree: `main` @ `b5e489e` +
live uncommitted work by T-027/T-035/T-036. Law: `docs/architecture-interaction-boundaries.md`
(normative). Method: every claim below carries file:line or a measured command; anything I
could not ground was dropped.

## Part 1 — the three Evidence defects: all three are ALREADY RESOLVED on disk

The task's Evidence section describes the tree **before** commit `8620bc3` (2026-07-30
12:52, "Build out the shell"). Nobody had re-verified it since; I did:

| # | Evidence claim | Verdict | Proof |
|---|---|---|---|
| (a) | `AppIntentRuntime.swift:19-24` defines an app principal with no production caller | **STALE — no violation.** Lines 19–24 today define `palettePrincipal` (`kind: .palette`), a lawful public-adapter principal, and it HAS a production caller | caller: `Sources/TenonApp/PaletteIntentInvoker.swift:77`; load-bearing anchor: `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift:158`; no generic app kind can exist: `InteractionBoundaryFitnessTests.swift:6-15` pins principal kinds/audiences to exactly `{core, plugin, palette, cli, agent}` |
| (b) | `CLICommandExecutor.swift` duplicates catalog-backed workspace/terminal semantics | **STALE — already collapsed.** The executor is a thin control-plane adapter: `ping`, `appFocus` direct; `intentList`/`intentDescribe`/`intentSend` all cross `AppIntentRuntime` → kernel dispatcher. Zero domain rules live in it | `Sources/TenonApp/CLICommandExecutor.swift:18-78`; closed verb set: `Sources/TenonCore/CLIAction.swift:38-44`; legacy verbs (`command.run`, `pane.send`, `pane.read`, `pane.wait`…) are pinned OUT and forbidden deps (`WorkspaceStore`, `SurfacePool`, `PluginHost`…) asserted absent by `Tests/TenonCoreTests/CLIIntentBusBoundaryTests.swift:5-80` |
| (c) | `docs/design-intent-bus.md:240-246` omits the ownership test and over-classifies finite internal work as INTENT | **STALE — already corrected.** The section "Boundary selection: delegated to the interaction law" (`docs/design-intent-bus.md:228-254`) states the full ordered ladder — control plane, CONTRIBUTION, EVENT, RESOURCE, same-owner **DIRECT** (the ownership test, step 4), SCOPED FACILITY, INTENT — in the law's exact order, affirmatively, and delegates exact definitions to the normative doc. No "previously" residue | compared line-by-line against `docs/architecture-interaction-boundaries.md:118-152`; order and semantics agree |

**Consequence for the board:** T-020's Evidence section is done; what remains of the XL is
the criteria, most of which the audit below shows are now also satisfied. Nothing in Part 1
required a source change, so no behaviour change (and no new test) was made by this slice.

## Part 2 — repo-wide audit against the ladder

### FINDING 1 (most severe) — Invariant 1 is not implemented: the plugin global scope is open, and no test would notice

`CLAUDE.md` invariant 1: "Plugins see only the `tenon` global. `console` is explicitly
deleted." Measured today:

- A fresh `JSContext` exposes `console` (`typeof console === "object"`, measured with
  `swift -e` against JavaScriptCore on this machine — modern JSC ships a global
  ConsoleObject).
- No file under `Sources/` contains the string `console` at all (rg over
  `Sources/TenonCore/` and the whole target: zero hits), so nothing deletes it. The old
  deletion did not survive the runtime rewrite landed in `163c8bf`/`8620bc3`.
- The surface fitness test enumerates only members **of `tenon`**
  (`Tests/TenonCoreTests/PluginBuiltinsTests.swift:86-141`,
  `testRuntimeExportsOnlyTheClassifiedPublicSurface`) — it never inspects `globalThis`, so
  this regression is invisible to the 653-test suite.
- Additionally the bootstrap installs ~20 `__tenon*` host hooks on `globalThis`
  (`Sources/TenonCore/PluginRuntimeBootstrap.swift:438-745`). They are
  `configurable: false, writable: false` (good — a plugin cannot replace them), but they
  are plugin-visible and plugin-callable: a plugin can invoke e.g. `__tenonSettleIntent`
  or `__tenonEmit` against its own runtime. Blast radius is confined to that plugin's own
  generation (the host keeps its own request state), so this is self-harm, not a
  cross-principal hole — but it contradicts the invariant's letter.

**Concrete consequence:** a plugin can emit diagnostics through `console.log` → os_log,
unattributed, bypassing `tenon.log`'s per-plugin attribution — exactly the side channel
the closed surface exists to prevent — and any global JSC grows in a future macOS arrives
in plugin scope unnoticed, because no fitness test closes the scope.

**NOT fixed in this slice, deliberately:** the fix is a behaviour change and
`docs/tdd.md` requires the failing test first, but the shared test target does not
compile right now (T-027's `WorkspaceCatalogPersistenceTests.swift` references
`WorkspaceCatalogStore`, which lands shortly — coordinator-confirmed), so no RED→GREEN
cycle is possible. No live worker holds `PluginRuntimeBootstrap.swift`; the next slice can
apply, verbatim:

1. In `PluginRuntimeBootstrap.source`, immediately after
   `delete globalThis.__tenonNativePost;` (line 7): `delete globalThis.console;`
2. New test beside `testRuntimeExportsOnlyTheClassifiedPublicSurface`: evaluate
   `typeof console` (expect `"undefined"`) and pin
   `Object.getOwnPropertyNames(globalThis).filter(n => !n.startsWith("__tenon"))`
   against the exact ECMA-builtin set plus `tenon`, so the NEXT global also fails the
   suite. Decide `__tenon*` visibility explicitly while there (hiding them behind a
   closure-captured table would satisfy the invariant's letter; document either way).

### FINDING 2 — CLAUDE.md cites two fitness tests that no longer exist

- `CLAUDE.md` invariant 1 names `testPluginsSeeOnlyTheTenonGlobal`; the Commands section
  offers `swift test --filter testEditingTheClockPluginOnDiskHotReloadsIt` as the
  single-test example. Neither name exists anywhere under `Tests/` (rg: zero hits).
- Consequence: the documented single-test command runs **0 tests** for every agent that
  copies it, and the invariant points at an unfailable test — which is how Finding 1
  stayed invisible. Successor names to cite: `testRuntimeExportsOnlyTheClassifiedPublicSurface`
  (surface closure) and the `ShippedPluginsTests` reload family
  (`testFailedReloadRetainsActiveSessionAndContributions` et al.).
- Not edited here: `CLAUDE.md` is outside this slice's claimed files. One-line doc fix
  for whoever holds it next.

### FINDING 3 — stale board/task metadata steers agents at the wrong files

- `.kanban/board.md` T-019 line still opens with "**T-020 session 019f9576 ACTIVE**" —
  that session is gone (the same board's T-020 line said so); T-020's own task file still
  carried the dead session's locks on 6 files until this slice rewrote its lock section.
- Consequence: workers route around locks nobody holds (this evening's dispatches did).
  T-019's line is another task's claim, so I did not edit it — flagged for the PM sweep.

### Ladder reconciliation — PASS inventory (measured, not assumed)

Every criterion the task file never ticked, answered with its enforcing artifact:

| Criterion | Status | Enforcing artifact |
|---|---|---|
| No internal dispatcher shortcut / generic app principal | **PASS** | source-scan fitness: dispatcher entry allowlisted to `TenonApp/AppIntentRuntime.swift` + `TenonCore/PluginHost.swift`, `IntentPrincipal(` construction allowlisted to 2 files (`InteractionBoundaryFitnessTests.swift:17-56`); kinds pinned, no `app` kind (`:6-15`) |
| Shipped plugins: declared intents only | **PASS** | static: every literal `send`/`handle` in shipped JS must match its manifest (`ShippedPluginsTests.swift:75`); runtime: fail-closed policy path. My independent sweep of all 9 plugins found every `tenon.intents.send`/`call.send`/`handle` target ⊆ manifest `uses`/`provides` — including multi-line and nested `call.send` forms (browser/core-commands/claude-sessions/file-explorer/git); `workspace.select.v1` retarget uses the sanctioned `options.scope` form (`plugins/core-commands/main.js:101-104`) |
| Shipped plugins: closed runtime surface only | **PASS** | static scan (`ShippedPluginsTests.swift:50`); exact 26-path `tenon` inventory pinned (`PluginBuiltinsTests.swift:86-141`) and it matches the law's table (`architecture-interaction-boundaries.md:411-443`) member-for-member; facility allowlist closed at `{settings, storage, log}` (`PluginBuiltinsTests.swift:137-140`) |
| Providers + CLI agree with declared schemas | **PASS** | `AppIntentRuntime.validateBindingInventory` fails startup when provider bindings ≠ compiled catalog (`AppIntentRuntime.swift:298-315`); CLI transports only kernel-shaped `CLIIntentInvocation` with strict parsing, host-owned `userGestureID` rejected (`CLIAction.swift:125-138`); schema shape/bounds fitness `CoreIntentCatalogTests.swift:91` |
| Fitness rejects audience drift | **PASS** | per-intent audiences == profile, exact `pluginOnly` 12-set, inventory count 39, exact lane map (`CoreIntentCatalogTests.swift:538-668`); profiles are exactly `{plugin, cli, agent}` / `{plugin}` (`CoreIntentCatalog.swift:61-73`) — matches the law's audience table |
| Fitness rejects stale request paths | **PASS** | legacy CLI verbs + forbidden dependencies pinned out (`CLIIntentBusBoundaryTests.swift:5-80`); removed handwritten `tenon.*` product APIs pinned out of Sources+plugins (`InteractionBoundaryFitnessTests.swift:58-94`) |
| Fitness rejects undeclared surfaces | **PARTIAL** | closed for `tenon.*` and for shipped-plugin usage (above); **open for `globalThis`** — that hole is Finding 1 |
| Same-owner UI stays DIRECT | **PASS** | focused editor/Ghostty/palette controls asserted DIRECT (`InteractionBoundaryFitnessTests.swift:171-250`); the two UI files touching `IntentValue` outside adapters do so only for values that genuinely cross the plugin boundary — plugin settings editing (`SettingsView.swift:362,457,480`) and plugin-view event payloads (`BuiltInSlotViews.swift:388,443`) — which invariant 2 requires to be bounded values, not a same-owner serialization detour |
| Keybinding projection | **PASS** | manifest-owned `palette.key` → `KeyBindingIndex` → shared `PaletteIntentInvoker`, asserted end-to-end (`InteractionBoundaryFitnessTests.swift:96-169`) |
| Docs agree with the law | **PASS** (post-`8620bc3`) | `design-intent-bus.md:228-254` ladder verified against the law; runtime-inventory tables verified against the pinned test list. Residual doc drift is Finding 2 (CLAUDE.md test names), not a law conflict |

### Explicitly out of scope, with owner

- `plugins/file-explorer|git|claude-sessions/main.js` are mid-edit by T-036 (instance
  model adoption). My sweep audited the bytes on disk tonight; T-036's landing may change
  line numbers but its stated design (instance model + `workspace.state.v1` scoping,
  no new `tenon` member) is inside the law.
- `PluginHost.swift`, `TenonApp.swift`, `AppStatePaths.swift`, `Workspace*`,
  `SurfacePool.swift`, `GhosttySurface.swift`: held by T-036/T-027/T-035 — untouched.

### Side note grounded during verification

The criterion "Swift 6 warnings-as-errors build" is not configured anywhere:
`Package.swift` sets only `swiftLanguageModes: [.v6]` (line 117) and no target carries
a treat-warnings-as-errors Swift setting. Today's builds pass with warnings (the known
GhosttyKit ImGui symbol ones). Either configure it or reword the criterion — as written it
can never be ticked honestly.

### Totals measured by this slice

- `swift build`: **exit 0 at 23:49** (tree at `b5e489e` + live worker edits of that
  moment). This slice changed **zero source files** — its writes are the board, the T-020
  task file, and this report — so it cannot have moved the build or the suite.
- `swift test`: **no clean full-suite run was obtainable between 23:49 and 00:10** — five
  attempts, each killed by a different live worker's mid-edit state, none by this slice:
  1. 23:52 — `TenonApp.swift:180` `cannot find 'resolvedLaunchDirectory'` + "input file
     modified during the build" (T-027 mid-edit).
  2. 23:57 — same file, "modified during the build" again (T-027 still writing).
  3. 00:01 — `Tests/TenonAppStateTests/FileDocumentExternalChangeTests.swift:280`
     ambiguous-expression compile error (T-016 editor session, file mtime 34 s old at
     failure).
  4. 00:05 — `Sources/TenonApp/SourceEditorView.swift:31` `cannot find
     'RestorableEditorScrollView' in scope` (+ Coordinator members) — T-016 mid-refactor;
     the tree never stayed quiet ≥60 s during a 6-minute stability-gated wait.
  5. 00:08 — final `swift build` check: red on a Swift 6 `SendingRisksDataRace` in T-016's
     new editor scroll-state closure (`slotID`/`statePath`/`NSClipView`).
- Last clean coordinator-verified baseline: **653/0 at `b5e489e`**; since then `48f57cb`
  (T-036) and `a8e2b28` (T-035) landed, each committed by the coordinator with its own
  verification. The suite total at next quiet window is expected ≥653; re-run once T-016
  and T-027 settle.
