# T-057: Tab context menu reuses the launcher popover
> Right-clicking a tab chip shows a flat native menu — the ranked launcher list rendered
> as bare `Button(title)` rows, frecency-interleaved, no icons/groups/search/shortcuts
> (user screenshot, 2026-08-01). The `+` button already opens `LauncherMenu` with all of
> that. One catalog, two presentations — the flat one goes away and the tab's right-click
> opens the same `LauncherMenu`, scoped to that tab via `TabContextPlacement`.
- **priority**: high
- **effort**: S

## Owner / files (agent lock)
RELEASED 00:2x — done + verified, all files free (`ShellTitleBar.swift`,
`LauncherMenu.swift`, NEW `LauncherOutcome.swift`, NEW `LauncherOutcomeTests.swift`).

## Design
- `LauncherMenu` gains an injectable `send: ((String) async -> IntentResult?)?` — `nil`
  keeps the `+` meaning (focused pane via `PaletteIntentInvoker.send`). The tab chip's
  popover injects a send that resolves scope through the existing `TabContextPlacement`
  (reveal-if-background + scoped `PaletteIntentInvoker.send(commandID:scope:)`).
- `TabChip` drops `menuCommands`/`runMenuCommand` and the native `.contextMenu`; a
  right-click (or control-click) catcher opens a `.popover` hosting the same
  `LauncherMenu`, anchored to the chip like the `+` popover.
- Pure rule extracted so the outcome flow is headlessly pinned: `LauncherOutcome`
  maps `IntentResult?` → record-frecency? / dismiss? / error text. Pins the defect the
  flat menu shipped with: `ShellTitleBar.run` recorded frecency even when the send
  failed or the intent had vanished, and swallowed the failure.

## Criteria
- [x] `LauncherOutcome`: success → record + dismiss; failure → error code shown, no
  record, stays open; vanished intent → "no longer available", no record (headless,
  TenonAppStateTests, red-first on assertions)
- [x] Tab right-click opens `LauncherMenu` scoped to that tab; the flat `.contextMenu`
  path is deleted (no second presentation of the launcher catalog)
- [x] Frecency records only successful invocations on every launcher surface
  (`PaletteOverlay.run` already did; both launcher anchors now settle through
  `LauncherOutcome`)
- [x] `swift build` exit 0 (warnings-as-errors) + full `swift test` **921 / 0**, run
  after every edit landed. ⚠️ Live launch smoke deliberately not run from here: at
  verification time the peer session's build was mid-compile on the shared `.build`
  tree, and `swift run` would have contended for it. Human-verify (the pixels anyway):
  right-click a tab chip — including a background tab — pick a row, result lands in
  that tab.

## Evidence
- RED 00:11 — inert `LauncherOutcome.init` (always `.ran`): 2/3 tests fail on 8 named
  assertions (this run doubles as the mutation proof for the settlement rule — the
  stub IS the mutation "record/dismiss regardless of result").
- GREEN 00:17 — full suite 921 tests / 0 failures in 81 s; build exit 0.
- Defect fixed by the unification, not just styling: the flat menu's
  `ShellTitleBar.run` recorded frecency even when the send failed or the intent had
  vanished, and swallowed the failure. Both launcher anchors now share `LauncherMenu`'s
  one settlement path.
- Honest limit, per docs/tdd.md layer map: the popover wiring and `RightClickCatcher`
  (hit-test participates only for right-/control-click events) are SwiftUI/AppKit shell
  — no headless test can see them; they ride the smoke bar.
