# T-022: `+` button launcher menu (Orca-style), "Add slot" removed
> The title bar's amber "Add slot" menu goes away; the tab strip's `+` opens a searchable
> popover projected from plugin-owned intent metadata instead of a hardcoded Swift list.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session `fd5aa92f`

Claimed files:
- `Sources/TenonApp/ShellTitleBar.swift` — delete `slotControls`, `+` opens the popover
- `Sources/TenonApp/LauncherMenu.swift` — NEW (the popover itself)
- `Sources/TenonApp/ContentView.swift` — pass `host` + `intentRuntime` into the title bar
- `Sources/TenonCore/CommandIndex.swift` — `Command.isLauncher` + `launcherOnly`
- `Sources/TenonCore/CommandAggregation.swift` — project the flag
- `Sources/TenonCore/PluginManifest.swift` — `palette.launcher` (additive field only)
- `Sources/TenonCore/PluginHost.swift` — ONE additive field on `PluginIntentPresentation`
  (~2276) + one line at its construction (~2294). Nothing else in this file.
- `plugins/{core-commands,browser,file-explorer,claude-sessions}/manifest.json`
- `Tests/TenonCoreTests/LauncherCommandsTests.swift` — NEW

⚠️ @019f9576 (T-019/T-020): four of these are on your claim list and have not changed
since Jul 25. My edits are strictly additive (a new optional manifest field threaded to a
new `Command` flag) — no rename, no signature change to `rank`, no keybinding code touched.
Shout here if that collides and I will hand over the patch instead.

## Criteria
- [x] "Add slot" button is gone from the title bar
- [x] `+` opens a search-first popover listing plugin-declared launcher intents with their
      key hints, grouped by category
- [x] Nothing that "Add slot" could open is lost (Terminal, Files, Diff/Changes, Docs,
      Browser) and split verbs stay reachable from the same menu — asserted by
      `testShippedLauncherOffersEverythingTheAddSlotMenuDid`
- [x] Menu content comes from `manifest.json`; adding an entry needs no Swift change
- [x] `swift build` clean + `swift test` 562 executed / 3 failures, all three proven
      pre-existing (see Evidence)

## Evidence
- `swift build` exit 0; `swift test` → **562 executed, 3 failures**.
- The 3 failures belong to T-021's provenance work, not to this task, and were **reproduced
  without a single line of mine**: a scratch copy of the current tree with my 12 edits
  reverted and my 2 new files deleted fails the same three at the same lines —
  `BundledPluginConsentTests.swift:81` (`testPluginHostDefaultsToUntrustedInventory`),
  `AppStatePathsTests` `testEnvironmentOverrideIsUntrustedForCopiedBundledPluginID` and
  `testUnknownTrustFlagValueLeavesOverrideUntrusted` (both expect `[]`, get
  `["process.exec.v1"]` — standing consent is seeded from an inventory the test declares
  untrusted). @c7da3ffe this is yours; item 8 of your own open list ("re-check at the
  execution boundary") looks adjacent to it.
- `LauncherCommandsTests` 5/5 (red → green: first run failed to compile on the missing
  `launcher` / `isLauncher` members, exactly the members this task adds).
- Behaviour change caught in the UI contract: `+` no longer creates a tab on click, so
  `testPlusButtonOpensAnAdditionalTab` became `testPlusButtonLauncherOpensAnAdditionalTab`
  (click `+` → click the manifest-declared New Tab row → 2 tabs) and
  `Tests/TenonUITests/README.md` gained the `tenon.launcher.row.<commandID>` identifier.
  **Not executed**: XCUITest needs `xcodegen generate`, which would overwrite
  `Tenon.pbxproj` while another session has it dirty. Left for whoever owns that file.

## Notes / follow-ups not done
- `EmptyStateCard.launchable` (`EmptyStateCard.swift:22-41`) and `SlotTypeOption`
  (`SpatialCanvasView.swift:1173`) are the two remaining hardcoded copies of the list this
  task removed from the title bar. They should follow the same projection; out of scope here.
- `CLAUDE.md` still documents `swift run tenon-poc`; the executable is now `tenon`
  (renamed in another session's uncommitted `Package.swift`). Not mine to fix.

## Follow-up polish (2026-07-30, session 8d6d0f45) — density + hover
User feedback on the shipped popover: no hover feedback, and the UI reads too heavy for a
menu hanging off a 36-pt title bar.
- `PaletteRow` gained a `Density` (`regular` | `compact`) and a pointer-hover wash. The
  launcher asks for `.compact`; the ⌘⇧P overlay keeps `.regular` metrics unchanged.
- Hover and keyboard selection stay separate signals: hover paints
  `text.opacity(0.07)`, the accent stays on the row Enter would run (a hovered *and*
  selected row goes amber 0.16 → 0.24). Arrowing never chases the mouse.
- Highlight is now an inset pill (radius 6/8, rail inset 6/8pt) instead of a full-bleed band.
- Compact metrics: row 40 → 28pt, title 14 → 12, icon 18/13 → 15/11pt, padding 14 → 12.
  Launcher chrome: search 40 → 32pt (font 13 → 12), width 320 → 300. Eight rows + two
  dividers: ~387 → ~285pt tall.
- Both result lists are bounded by available space, not by a constant. `LauncherMenu`
  measures from the popover's anchor under the title bar to the bottom of the screen the
  window is on (`NSScreen.visibleFrame`); `PaletteOverlay` measures the window through a
  `GeometryReader`. A display with room for forty rows shows forty rows; scrolling begins
  only when the screen actually runs out.
- Evidence: `swift build` exit 0. `swift test` cannot run — `SpatialLayoutTests.swift:703`
  (T-025 session dd2c89a8, mid-TDD) fails to compile on `SpatialLayout.fillWidth`, which
  takes the whole `TenonCoreTests` target down. Untouched, not mine. Visual confirmation
  of the popover still needs a human relaunch.
