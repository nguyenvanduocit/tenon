# T-124: One row chrome, three kinds of row
> `PaletteRow` takes `CommandMatch`, so a row that is not a ranked command must either fabricate one or hand-roll itself — and both workarounds already shipped.

- **priority**: medium
- **effort**: S
- **PRD**: TENON-PRD-002 `docs/prds/command-surfaces.prd.md` — `CMD-NFR-005` (hover is already promised), `CMD-FR-007` (footer stays outside ranking), new `CMD-NFR-008`

## Owner / files (agent lock)

**Released 2026-08-11 22:2x.** The split landed; no file below is held.

Finished by session `a3cd4139` after session `f3e2d2dc` stopped at 10:43 having written only
`PaletteRowChrome.swift` and the red fitness test. Files touched, all of them from the original
claim:

- `Sources/TenonApp/PaletteRowChrome.swift` (new, written by the first session, now composed)
- `Sources/TenonApp/PaletteOverlay.swift`, `Sources/TenonApp/LauncherMenu.swift`,
  `Sources/TenonApp/LauncherListHeight.swift`
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` (lines 353-360, 576-590, 799-880 —
  disjoint from T-128's install region at 6-87)
- `docs/prds/command-surfaces.prd.md`, `docs/prds/command-surfaces.feature`

## The defect the user photographed

The tab launcher's fixed `Copy Tab ID` footer never highlights: no hover wash, no selection wash. Every other row in the same popover has both.

## Root cause

`PaletteRow` (`PaletteOverlay.swift:436`) is where the highlight lives — `@State isHovered`, `.onHover`, and the rounded pill painted from `highlight` (`:497-513`). Its only input is `match: CommandMatch`, which is the **output type of the ranking system**: it carries `score` and `titleMatch`. So at the level of the type signature, *looking like a row* is welded to *being a ranked command*.

`Copy Tab ID` cannot be a ranked command. It is a host-native DIRECT action (`WorkspaceIdentifierClipboard.copy(tab.id)`, `ShellTitleBar.swift:470`), and invariant 8 forbids built-in UI a generic app intent principal. So there is no honest `CommandMatch` to hand `PaletteRow`, and `LauncherMenu.swift:111` hand-rolled a bare `Button` instead. The highlight was never dropped — it was never reachable.

**This is not a one-off.** `PaletteOverlay.swift:272-288` hit the same wall for dynamic plugin results and took the opposite escape: it fabricates `CommandMatch(command: Command(...), score: 0, titleMatch: [])` — a synthetic ranking answer for something that was never ranked. Two call sites, one cause, two opposite workarounds:

| call site | escape taken | price |
|---|---|---|
| `PaletteOverlay.swift:276` | fabricate a `CommandMatch` | keeps the highlight, lies about being ranked |
| `LauncherMenu.swift:111` | refuse to lie, hand-roll | honest, loses the highlight |

An abstraction that makes every non-conforming caller choose between lying and copying is at the wrong altitude.

## The promise that already existed

`CMD-NFR-005` is **shipped** and reads: *"Launcher, rows, caret, hover, type, color, and geometry MUST use `TenonTheme` and `docs/designs.md`."* Its evidence column says `source/design review` — a human looking. That is why a shipped requirement went unmet in plain sight, and why this change owes it a test seam rather than a new requirement.

## The change

Split `PaletteRow` by altitude. `PaletteRowChrome` owns icon column, title slot, subtitle/key accessories, density metrics, hover and selection pill, and knows nothing about `CommandMatch`. Three rows compose on it:

- ranked command → chrome + fuzzy-accented title (today's `PaletteRow`, unchanged behaviour)
- dynamic provider result → chrome + plain title (deletes the fabricated `CommandMatch`)
- `Copy Tab ID` → chrome + plain title, `isSelected` permanently `false`

`Copy Tab ID` stays out of `count`, so ↓/↑ never reaches it and search never sees it: `CMD-FR-007` and `CMD-A-002` are untouched. The only special case left is the one that deserves to be special — it does not take part in ranking.

## Criteria

- [x] `PaletteRowChrome` exists, references no `CommandMatch`/`Command`, and is the only place a launcher/palette row highlight is written — `PaletteOverlay.swift` and `LauncherMenu.swift` now contain neither `isHovered` nor `.onHover`
- [x] The `Copy Tab ID` footer draws hover through that chrome at `Density.compact` metrics (28 pt, `railInset` 6, `cornerRadius` 6), and still never draws the selected accent (`isSelected: false`, `LauncherMenu.swift:112-125`)
- [x] The fabricated `CommandMatch` at `PaletteOverlay.swift:277` is gone — the appended result draws `PaletteRowChrome` with its plain title (`PaletteOverlay.swift:272-284`)
- [x] `LauncherListHeight.row` reads `PaletteRowChrome.Density.compact.height`, and `utilityHeight` is now `row + separatorRule` = 29, so it follows the footer instead of restating 31
- [x] Ranked-row appearance is unchanged — **read, not photographed**: the `Density` values moved across byte-identical, the per-character `Text` colours still win over the chrome's outer `TenonTheme.text`, the icon fallback is the same `"command"`, and the assigned chord rides the chrome as `trailing:`
- [x] `InteractionBoundaryFitnessTests` pins the shared chrome — the older anchor at :580 now reads `title: Text("Copy Tab ID")` instead of the hand-rolled `Button(...)`, and the new test fails if either surface restates the highlight
- [x] Red first — **inherited, not personally reproduced**: the failing run belongs to the triage pass (`Executed 1 test, with 7 failures`). This session saw one strand go red on its own change: `testRegisteredProductBindingsFollowManifestProjectionAndSharedInvoker` failed on `Text(key.display)` the moment the row stopped writing it, and the anchor was moved to `trailing: match.command.key?.display` rather than dropped
- [x] `CMD-NFR-008` added; `CMD-NFR-005`'s evidence is now the fitness test for its row half (caret and type stay design review); delivery row and dated receipt appended
- [x] `swift test` — **1968 tests, 3 failures, none in this capability**: `AgentTranscriptPathTests` (T-126/T-123 lane), `PluginWebSurfacePoolTests.testCrossOriginSubframeCannotRedirectTheSurface`, and `ScriptSurfaceFitnessTests` (T-128's script move, docs still naming old paths). `InteractionBoundaryFitnessTests` **21 / 0**
- [ ] Photographed — **UNTICKED 2026-08-12: no picture exists, and the reason given for that was wrong.** The original note claimed it was structurally impossible because every offscreen route (`TENON_VIEW_SNAPSHOT`, `TENON_DIFF_SNAPSHOT`, `TENON_CHANGES_SNAPSHOT`, `TENON_TIMELINE_SNAPSHOT`, `TENON_SIDEBAR_SNAPSHOT`) mounts a pane, the diff, the changes panel, the timeline or the sidebar, that the launcher is an `NSPopover` none of them reach, and that a route would mean editing `TenonApp.swift`. The first two facts are true and the conclusion does not follow: `Tests/TenonAppStateTests` already does `@testable import TenonApp` and renders its SwiftUI views offscreen through `NSHostingView` with no window and no permission — `WorkspaceIdentityFormTests.swift:202 testTheFormRendersOffscreen` and `WorkspaceRecentLauncherTests.swift:23`, both re-read on 2026-08-12. `LauncherMenu` is reachable the same way, in the same target, without touching `TenonApp.swift`. What genuinely needs a real pointer is only "the wash follows the cursor"; the footer's 28 pt geometry, its chrome membership and its rendered appearance were photographable the whole time and were not photographed

## Verification 2026-08-12 — CONFIRMED

An independent pass tried to refute the shipped claim and could not. It re-ran
`InteractionBoundaryFitnessTests` + `LauncherListHeightTests` **24 / 0** and the full suite
**2001 / 0** — all three foreign failures in the receipt above have since been fixed by their
own lanes — read the structure rather than trusting it (`rg 'isHovered|\.onHover'` over
`PaletteOverlay.swift` and `LauncherMenu.swift` returns nothing; the `Density` values moved
byte-identically; `utilityHeight` = 29 follows a 28 pt footer), checked each of the three test
anchors as narrowed rather than weakened, and reconstructed red-first from the diff instead of
inheriting it.

Two findings it added:

- The "Photographed" criterion is unticked above, with the false structural reason corrected.
- `Sources/TenonApp/QuickCommandViews.swift:362` still hand-rolls `.onHover { hovering = $0 }`,
  so the first criterion's "the only place a launcher/palette row highlight is written" is true
  of `PaletteOverlay.swift` and `LauncherMenu.swift` and not of the tree. Outside this task's
  file set — worth a follow-up rather than a re-open.

## Honest limits to record at the end

- Whether hover *looks* right is a pointer-driven property; a headless suite can prove the wash is wired and its colour token, not that a person sees it move.
- The chrome test bans the ranking vocabulary in **code**, with comment tails stripped first: the type's own rationale has to be free to name the thing it refuses, and a `//` line cannot create a dependency.
- The footer's type is now the compact row's 12 pt rather than the 11 pt medium it was drawn at alone. That is the point — it reads as one of the rows — but it is a visible change nobody has looked at yet.
