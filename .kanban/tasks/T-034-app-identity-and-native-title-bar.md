# T-034: App identity and a title bar that behaves like a system one
> Tenon shipped with the generic SwiftUI app icon and an SF Symbol standing in for a
> wordmark, a 46-pt title bar that floated the tab strip below the traffic lights' centre
> line, and an empty title bar that could be dragged but not double-clicked.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
**PM session `fb6a3270`** — retroactive bookkeeping, not a fresh claim.

This task file was written **after** the code, on 2026-07-30 22:24, because the adversarial
review in `.kanban/reports/review-landed.md` found this work sitting in the working tree
with **no task file, no board line and no owner** — the only slice in the tree nobody could
attribute. The code was written earlier the same day (`TenonTheme` / `ShellTitleBar` /
`WindowChrome` mtimes ~16:07) by a session that never registered it. Recording it now so it
can be committed with an author and acceptance criteria instead of arriving as mystery
diff.

Files carrying this slice:
- `Sources/TenonApp/WindowChrome.swift` — `mouseDownCanMoveWindow` → explicit
  `mouseDown` + `performDrag`, plus the double-click action
- `Sources/TenonApp/TenonTheme.swift` — `titleBarHeight` 46 → 36. ⚠️ `tabMinWidth` in
  the same hunk belongs to **T-025**, not to this task
- `Sources/TenonApp/ShellTitleBar.swift` — `Image("TenonMark")`, chip height 32 → 26,
  icon box 27 → 24. ⚠️ this file is currently held by the **T-022 defect fix**
  (session `46aca5a4`) — do not edit it here
- NEW `Design/AppIcon/` — `TenonAppIcon.svg`, `TenonAppIcon-Small.svg`,
  `TenonAppIcon-1024.png`, `Tenon.icns` (sources, untracked)
- NEW `Sources/TenonApp/Assets.xcassets/` — `AppIcon.appiconset` (10 PNGs + Contents.json)
  and `TenonMark.imageset` (untracked)
- NEW `scripts/generate-app-icon.sh` — regenerates the appiconset from the SVG masters
  via `sips` (untracked)

## Why / evidence
- `WindowChrome.swift:43` used to be `override var mouseDownCanMoveWindow: Bool { true }`,
  which hands the press to the window server. The window server never delivers the **second**
  click, so the empty title bar could be dragged but never double-clicked — the gesture every
  macOS title bar answers with zoom or minimise. Driving the drag from `mouseDown` +
  `performDrag(with:)` keeps the system drag intact (snapping, tiling, spaces) while leaving
  `clickCount >= 2` free to handle.
- The double-click action reads `AppleActionOnDoubleClick` from `UserDefaults`
  (System Settings ▸ Desktop & Dock). The key is **absent** until the user changes it away
  from the default, so the `default:` branch must mean zoom — treating absent as "no action"
  would break the majority case.
- `titleBarHeight` 46 → 36 puts the strip near the 28-pt band macOS lays the traffic lights
  out in, so the tabs read as one row with them rather than floating below their centre line.

## Known defect — being fixed elsewhere, do not duplicate
`ShellTitleBar.swift:69`'s `Image("TenonMark")` has **no bundle to load from under
`swift run tenon`**: the asset catalog is untracked and `Package.swift`'s `TenonApp`
target declares no `resources:`. SwiftPM does not run `actool`. The SF Symbol fallback was
deleted in the same hunk, so the mark renders as a blank 14×14 gap on the documented dev
launch path. This is **finding 4** of `.kanban/reports/review-landed.md` and is assigned to
the T-022 defect-fix worker (session `46aca5a4`), which owns `Package.swift` and
`ShellTitleBar.swift` this wave.

## Criteria
- [x] Dragging an empty part of the title bar moves the window, with system snapping and
      tiling unchanged
- [x] Double-clicking an empty part performs the user's configured action, defaulting to
      zoom when `AppleActionOnDoubleClick` is unset
- [x] The tab strip sits on the traffic lights' row rather than below it
- [x] `scripts/generate-app-icon.sh` regenerates every appiconset size from the SVG
      masters, so the PNGs are derived artifacts and not hand-maintained
- [x] The mark resolves under `swift run tenon` — **shipped by the T-022 fix**, verified
      2026-07-31 at `17bf0a6`: `Package.swift:84-89` declares `.process("Assets.xcassets")`
      on the `TenonApp` target, and `AppMark.resolve()` (`AppMark.swift:19-31`) tries the
      `actool`-compiled `NSImage(named:)` first, then reads the vector out of
      `Bundle.module` for the SwiftPM path where `actool` never ran. `ShellTitleBar.swift:69`
      consumes it with an SF Symbol fallback, so the title bar cannot draw nothing
- [x] The asset catalog is tracked in git, so the reference at `ShellTitleBar.swift:69` does
      not ship dangling for every other clone — **89 files** under
      `Sources/TenonApp/Assets.xcassets/` are tracked (`git ls-files`)
- [x] Committed with the rest of the pane/launcher changeset — working tree clean at
      `17bf0a6`, nothing from this task left unstaged

Human-verify-only (tracked as item 1 of `.kanban/reports/human-verification-checklist.md`):
the mark's pixels in a running window, title-bar drag/double-click, and the tab strip
sitting on the traffic lights' row.
