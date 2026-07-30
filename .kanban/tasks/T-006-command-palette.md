# T-006: Command Palette (⌘⇧P) — fuzzy search hợp nhất, plugin đóng góp command
> Surface tìm-và-chạy kiểu Spotlight/Raycast: một ô search fuzzy gom built-in actions + plugin commands, mở bằng ⌘⇧P. Plugin đóng góp command tĩnh + dynamic provider + actions-on-results qua public API (no private API).

- **priority**: high
- **effort**: L
- **design**: [docs/design-command-palette.md](../../docs/design-command-palette.md)

## Owner / files (agent lock)
- **Phase 4 + 5b COMPLETE, CLAIM RELEASED** (Orca worker task_66cd5c096f69, 2026-07-31
  00:56) — all files below are FREE. Actually modified: `TenonCore/{PluginHost,
  PluginRuntime, PluginRuntimeBootstrap, PluginRuntimeModels}.swift`, NEW
  `TenonCore/PaletteProviders.swift`, `TenonApp/{PaletteOverlay, CommandPaletteState,
  PaletteIntentInvoker}.swift`, NEW `TenonApp/PaletteDisplayModel.swift`,
  `Tests/TenonCoreTests/{PluginBuiltinsTests, PluginHostTests}.swift`, NEW
  `Tests/TenonCoreTests/PaletteProviderTests.swift`, NEW
  `Tests/TenonAppStateTests/PaletteDisplayModelTests.swift`, `docs/design-command-palette.md`,
  `docs/architecture-interaction-boundaries.md` (inventory + EVENT/CONTRIBUTION lists),
  repo `CLAUDE.md` (vocabulary list only). Never opened for writing despite the claim:
  `CommandIndex.swift`, `CommandAggregation.swift`, `PluginManifest.swift`,
  `LauncherMenu.swift`, `poc/plugins/**`.
- **Phase 1 COMPLETE** (session `4564041c`, 2026-07-24) — claim released, files stable:
  - `poc/Sources/TenonCore/FuzzyMatch.swift`, `Frecency.swift`, `CommandIndex.swift`
  - `poc/Tests/TenonCoreTests/FuzzyMatchTests.swift`, `FrecencyTests.swift`, `CommandIndexTests.swift`
  - `docs/design-command-palette.md`
  - Evidence: full suite 220/220 green (+21 new). Not committed (awaiting user).
- Phase 2+ (touches PluginRuntime/PluginHost/ContentView/TenonApp/manifests) UNCLAIMED — coordinate before starting; those files are hot with T-002..T-005 work.

## Phase 4 verification — every asserted rule broken once, seen RED, restored

| # | Mutation (Sources/) | Test that went RED | Red output seen |
|---|---|---|---|
| A1 | `setPaletteResults` stale-revision guard deleted | `testPublicationForASupersededRevisionIsDropped` | `("1") is not equal to ("0") - a superseded answer was accepted` |
| A2 | provides-membership check deleted in `parsePaletteIntentDesignation` | `testResultsAreBoundedAndShapeValidated` | `("49") is not equal to ("48")` + foreign action kept |
| A3 | provider-count guard deleted in `registerPaletteProvider` | `testANinthProviderRegistrationFailsTheRuntime` | `expected the expression to throw` |
| A4 | `PaletteDisplayRow.pending` made selectable | `testSelectionSkipsHeadersAndPendingRows` | `XCTAssertNil failed: "result(...)"` |
| B | host `isCurrent` filter → always-true | `testASlowProviderNeverBlocksOrReordersTheStaticRankedList` | pending asserts failed (never-answering provider rendered as answered) |
| C | `paletteSections =` → `+=` (retired sections linger) | `testResultsFollowTheCurrentQueryAndRetirementRemovesThem` | `condition did not become true` on `waitUntil isEmpty` after disable |
| D | `palette` removed from the `tenon` freeze | `testANinthProviderRegistrationFailsTheRuntime` (+ suite unable to run the feature at all) | `TypeError: undefined is not an object (evaluating 'tenon.palette.registerProvider')` |

All mutations reverted; the restored tree re-ran green before the final full suite.
Method note: this slice implemented first and proved every rule by break→RED→restore
(the T-019 pattern) instead of a stub-red phase — same evidence, one fewer build cycle
under a 3-worker `.build` contention.

## Phase 4 — boundary classification (written before implementation, per the ordered decision law)

Dynamic providers are three semantic interactions, classified one at a time
(`docs/architecture-interaction-boundaries.md`, "Classification unit"):

1. **`tenon.palette.registerProvider(id, {title})` → CONTRIBUTION (registration), rung 1.**
   An independently owned contributor publishes a static registration whose snapshot it
   owns; the host owns validation, indexing, and rendering. Identical in kind to
   `tenon.views.register`. Rung 0 does not apply: this is product surface, not
   protocol/registry control.
2. **Query delivery → EVENT, rung 2.** "The palette query is now *t*, revision *N*" is a
   fact that already happened on a publisher-owned channel — the palette produces query
   facts whether or not any provider observes them, and never awaits observers (the static
   ranked list renders regardless). `tenon.palette.onQuery` is EVENT subscription control,
   the same classification as `views.onSubmit`. Rung 1 fails: the host is not a
   contributor publishing declarative state for rendering.
3. **`tenon.palette.setResults(id, revision, results)` → CONTRIBUTION (publication),
   rung 1.** The plugin owns "my results for revision N" as a replaceable snapshot keyed
   by provider; repeated publication replaces the previous one; the host owns validation,
   bounds, stale-revision rejection, reconciliation, and rendering. Hot reload removes the
   retired generation's publications atomically — the standard CONTRIBUTION teardown.

Why the neighbouring rungs do not fit:
- **Not RESOURCE/STREAM/TASK (rung 3):** the plugin establishes no producer and holds no
  lifetime handle. The query producer is the palette itself, existing independently of any
  observer (`fs.watch` is RESOURCE because the caller *creates* the watcher; here the
  plugin creates nothing and cancels nothing).
- **Not DIRECT (4):** plugin ↔ host crosses semantic owners.
- **Not SCOPED FACILITY (5):** the allowlist is closed at settings/storage/log
  (invariant 7); a query-time command source is discoverable product surface, not a
  plugin-private fixed service.
- **Not INTENT (6):** rungs 1–2 matched first; and semantically an intent settles exactly
  once, while a query may legally be answered zero or many times and the palette must
  never hold a per-keystroke call open (this doc's own "Dynamic results" rule).

**Invocation is unchanged:** each executable result names a canonical intent owned by the
publishing plugin plus its input; Enter dispatches through the production dispatcher as
the palette principal — the same INTENT path as static rows (invariant 6, one policy path,
invariant 5). Runtime-side publication checks (`intent ∈ manifest.intents.provides`,
bounds) are contribution *shape validation*; authority lives solely in the dispatcher.

**Bounds and lifetime (invariant 10):**
- ≤ 8 providers/plugin, ≤ 50 results/publication (truncated), ≤ 8 actions/result,
  bounded string lengths; payloads ride the existing bridge clone depth/size caps.
- The query revision is host-owned and monotonic; a publication for revision ≠ current is
  dropped at the runtime (revision < last delivered) and filtered by the host
  (revision ≠ current) — keystroke N+1 cancels keystroke N.
- Results ride `PluginRuntimeSnapshot`; `PluginHost.accept` (`PluginHost.swift:1822`)
  drops snapshots whose session identity is not current, so a retired generation's late
  publication cannot reach the palette; `__tenonShutdown` clears palette handlers.
- Delivery is fire-and-forget onto the plugin's own pinned thread; the host never awaits
  a handler. A pathological provider harms only its own runtime.

**Loading state (product decision):** the static ranked list is never delayed, reordered,
or blocked by providers — provider sections append BELOW the static rows (positions never
churn while typing). A provider whose delivered revision is ahead of its published
revision shows one non-selectable "Searching…" row in its own section; only results
matching the current revision are shown (the palette never answers a question the user is
no longer asking); a provider with nothing to say shows nothing.

**Phase 5b re-verification (00:24):** the `workspace.control` half was already shipped by
T-009 — handlers `core-commands/main.js:61-75` (tab.next/tab.previous/pane.focus-next) and
`:102` (workspace.select.v1), manifest uses `core-commands/manifest.json:11-15`, canonical
intents `CoreIntentCatalog.swift:44-47`; T-005 (the stale deferral reason) is all-phases
done per the board. Remaining: the ⌘K actions-on-results submenu only. A dynamic result
may carry `actions: [{title, intent}]` — separate plugin-owned intents, never closures.
⌘K inside the open palette is focused-view-local control (DIRECT — the boundary law's
"palette Escape" precedent); the chosen action dispatches through the same invoker.

## Criteria
- [x] `docs/design-command-palette.md` — goal, UX spec (⌘⇧P, anatomy, states, keyboard, prefix modes, actions-on-results), API design, phased plan, invariants
- [x] Phase 1 core (this session), TDD, testable in `TenonCoreTests` without a window:
  - [x] `FuzzyMatch` — subsequence + fzf-style scoring + matched indices (highlight)
  - [x] `Frecency` — frequency×recency scoring, injectable clock, exponential decay, Codable
  - [x] `Command` value model (id/title/subtitle/category/icon/keywords/shortcut/when)
  - [x] `CommandIndex.rank` — fuzzy + keyword fallback + frecency tiebreak + `when` filter; empty query → frecency-sorted recents
  - [x] `swift test` green (220/220)
- [x] Phase 2 (session 4564041c, 2026-07-24) — object-form `tenon.commands.register` (legacy 3-arg still valid) + enriched `PluginCommand` + `PluginHost.commandIndex` via `CommandAggregation.swift` extension (zero PluginHost.swift edits); 5 tests; full suite 229/229. Frecency recording deferred to phase 3 (record on user pick). Files: `PluginRuntime.swift` (commands region only), `CommandAggregation.swift`, `CommandRegistrationTests.swift`. Not committed.
- [~] Phase 3 (session 4564041c, 2026-07-24) — IMPLEMENTED + build/launch verified; GUI interaction UNVERIFIED (headless). Files: NEW `CommandPaletteState.swift` (@Observable state + frecency persist to `.command-frecency.json`), NEW `PaletteOverlay.swift` (overlay + fuzzy-highlight rows + ↑/↓/Enter/Esc); minimal edits to `ContentView.swift` (+palette prop, +`.overlay`) and `TenonApp.swift` (+@State palette, +ContentView arg, +⌘⇧P menu Button). Frecency recording landed here (record on user pick).
  - Evidence: full app `swift build` = Build complete; launch-alive smoke = ALIVE 6s no crash; TenonCore builds clean. Full `swift test` currently BLOCKED by T-005's in-flight non-exhaustive switch in `BuiltInSlotViews.swift:1042` (unrelated to palette) — my phase 1+2 tests were green (229/229) before that break.
  - ⚠️ NEEDS GUI verification (can't screenshot headless): (1) ⌘⇧P actually opens the palette despite the terminal grabbing keys first; (2) keyboard focus lands in the search field; (3) rows/highlight render. Only plugin commands show until phase 5 (core-commands). Not committed.
- [x] Phase 3 GUI proof PASSING — `PaletteFlowUITests.swift` (XCUITest): all 3 pass on the real app (** TEST SUCCEEDED **): ⌘⇧P opens past terminal key-grab ✓, focus+typing filters to core-commands.split-right row ✓, Esc closes ✓. (Esc fix: `.cancelAction` shortcut — a focused TextField swallows the raw Escape keyDown, so `.onKeyPress(.escape)` never fires.) Runs on `Tenon` scheme via xcodebuild, no Accessibility grant. Had to wait out concurrent peer tree breakage to run.
- [x] Phase 4 — dynamic providers SHIPPED (Orca worker task_66cd5c096f69, 00:55). Protocol
  = CONTRIBUTION + EVENT (classification section above): `tenon.palette.registerProvider`
  (CONTRIBUTION registration) + `tenon.palette.onQuery` (owner-scoped EVENT subscription)
  + `tenon.palette.setResults(id, revision, results)` (CONTRIBUTION publication,
  revision-scoped). Host: `PluginHost.setPaletteQuery` (sync, one keystroke = one
  monotonic revision, fan-out fire-and-forget), `paletteSections` published state,
  `invalidatePaletteQuery` on close. Runtime: `deliverPaletteQuery` is `nonisolated` and
  takes the SAME `invocationGate` as provider bindings — a keystroke racing a plugin
  disable is refused at the gate instead of tripping `PinnedThreadExecutor`'s
  post-shutdown precondition (found by a test crash mid-slice, the gate is the fix);
  bridge failure → `transitionToFailed`, host lives (invariant 4). Bounds: ≤8
  providers/plugin (9th fails the runtime), ≤50 results, ≤8 actions, 256-char strings;
  every result/action intent must be in the publisher's `manifest.intents.provides`
  (shape check; authority stays with the dispatcher). Loading state: static list never
  waits (asserted: `setPaletteQuery` then IMMEDIATE re-rank identical, no yield);
  provider sections append below with a non-selectable "Searching…" row; only
  current-revision publications render. Tests: `PaletteProviderTests` (6, incl. real
  `PluginHost` + real JS fixtures), `PaletteDisplayModelTests` (4), surface +
  `globalThis` pins updated (`tenon.palette.*`, `__tenonPaletteQuery`). All 7 mutation
  cycles RED for the stated reason and restored (table below).
- [x] Phase 5a — RICH bundled commands SHIPPED + verified (291 green). Added content-opening `workspace.control` verbs `newTab(spec)` + `setContent(spec)` (core `parseContentSpec`: terminal/files/changes/docs + generic {type:"plugin",plugin,viewID}, NO hardcoded plugin name) + WorkspaceCommand `.openTab`/`.setContent` + TenonApp switch. `core-commands` (plugin-agnostic): New Tab, New Terminal, Split R/D, Close Pane, Open Files/Changes/Docs. **Browser plugin registers its OWN "Open Browser"** (`newTab({type:"plugin", plugin:tenon.pluginName, viewID:"browser"})`) — core-commands never mentions it (VISION §6 replaceable-everything). Tests: WorkspaceContentCapabilityTests, BrowserOpenCommandTests (new), CoreCommandsPluginTests. Files: PluginRuntime/PluginHost/TenonApp (additive), core-commands + browser plugins.
- [x] Phase 5b — DONE in two verified halves (Orca worker task_66cd5c096f69, 00:55).
  (1) The `workspace.control` nav extension was ALREADY SHIPPED by T-009 — verified with
  file:line, not reimplemented: handlers `core-commands/main.js:61-75`
  (tab.next/tab.previous/pane.focus-next) and `:102` (workspace.select.v1), manifest uses
  `core-commands/manifest.json:11-15`, canonical intents `CoreIntentCatalog.swift:44-47`.
  The old deferral reason ("collides with T-005") was stale — T-005 is all-phases done.
  (2) Actions-on-results ⌘K submenu: a dynamic result may carry
  `actions: [{title, intent}]` — separate plugin-owned intents, never closures; parsed,
  bounded (≤8) and provides-validated at publication (`PaletteProviderTests`), surfaced
  through `PaletteDisplay.actions(forSelection:)` (`PaletteDisplayModelTests`), rendered
  as a ⌘K submenu in `PaletteOverlay` (hidden `.keyboardShortcut("k", [.command])`
  button — focused-view-local DIRECT control, the boundary law's palette-Escape
  precedent; Esc closes the submenu before the palette). Both the row's Enter and an
  action dispatch through the one shared `PaletteIntentInvoker` →
  `AppIntentRuntime.send(intentID, input:, as: palettePrincipal, target: pluginProvider)`.
  Static command rows carry no actions in v1 — ⌘K is a no-op there. GUI pixels of the
  submenu are human-verify-only (repo convention); the rules are asserted headlessly.
