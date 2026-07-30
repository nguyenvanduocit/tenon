# T-006: Command Palette (⌘⇧P) — fuzzy search hợp nhất, plugin đóng góp command
> Surface tìm-và-chạy kiểu Spotlight/Raycast: một ô search fuzzy gom built-in actions + plugin commands, mở bằng ⌘⇧P. Plugin đóng góp command tĩnh + dynamic provider + actions-on-results qua public API (no private API).

- **priority**: high
- **effort**: L
- **design**: [docs/design-command-palette.md](../../docs/design-command-palette.md)

## Owner / files (agent lock)
- **Phase 1 COMPLETE** (session `4564041c`, 2026-07-24) — claim released, files stable:
  - `poc/Sources/TenonCore/FuzzyMatch.swift`, `Frecency.swift`, `CommandIndex.swift`
  - `poc/Tests/TenonCoreTests/FuzzyMatchTests.swift`, `FrecencyTests.swift`, `CommandIndexTests.swift`
  - `docs/design-command-palette.md`
  - Evidence: full suite 220/220 green (+21 new). Not committed (awaiting user).
- Phase 2+ (touches PluginRuntime/PluginHost/ContentView/TenonApp/manifests) UNCLAIMED — coordinate before starting; those files are hot with T-002..T-005 work.

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
- [ ] Phase 4 — dynamic providers (`registerProvider` search-as-you-type, async, loading)
- [x] Phase 5a — RICH bundled commands SHIPPED + verified (291 green). Added content-opening `workspace.control` verbs `newTab(spec)` + `setContent(spec)` (core `parseContentSpec`: terminal/files/changes/docs + generic {type:"plugin",plugin,viewID}, NO hardcoded plugin name) + WorkspaceCommand `.openTab`/`.setContent` + TenonApp switch. `core-commands` (plugin-agnostic): New Tab, New Terminal, Split R/D, Close Pane, Open Files/Changes/Docs. **Browser plugin registers its OWN "Open Browser"** (`newTab({type:"plugin", plugin:tenon.pluginName, viewID:"browser"})`) — core-commands never mentions it (VISION §6 replaceable-everything). Tests: WorkspaceContentCapabilityTests, BrowserOpenCommandTests (new), CoreCommandsPluginTests. Files: PluginRuntime/PluginHost/TenonApp (additive), core-commands + browser plugins.
- [ ] Phase 5b — actions-on-results (⌘K submenu) + extend `workspace.control` (nextTab/prevTab/focusNextSlot/switchWorkspace) so remaining menu actions move into core-commands (deferred: collides with T-005's live PluginRuntime edits)
