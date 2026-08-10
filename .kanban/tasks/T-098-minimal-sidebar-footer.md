# T-098: Make the sidebar footer minimal
> Replace the visually heavy Help, Feedback, Settings, and version block with a compact, quiet footer that preserves every action.

- **priority**: medium
- **effort**: S

## Criteria
- [x] Help, Feedback, and Settings remain available from one compact footer row instead of three large card-style buttons.
- [x] The footer has lower visual weight than workspace content: no oversized tiles, excessive padding, or prominent standalone version label.
- [x] Version/build information remains discoverable from an appropriate secondary surface such as About or a subtle tooltip/menu, without occupying the primary sidebar hierarchy.
- [x] Existing Help, Feedback, and Settings actions keep their current destinations and behavior; this visual change adds no duplicate command path.
- [x] Layout remains usable at the sidebar's minimum and default widths, with localization and increased text size causing neither clipping nor overlap.
- [x] Every compact control has a tooltip, keyboard focus state, useful VoiceOver label, and a hit target that meets `docs/designs.md`; light/dark appearances use existing semantic colors and no footer-specific tokens.
- [x] The existing same-owner actions remain typed DIRECT/local control under `docs/architecture-interaction-boundaries.md`; no new public intent or capability is introduced for this restyle.
- [x] The footer is visually verified at minimum/default sidebar widths and in light/dark appearances, and tests keep the three actions reachable after the layout change.

## Owner / files (agent lock)

RELEASED — session `fe2ce402`, done 17:5x. Every file below is free.

## What shipped

**~68 pt of footer became one 34 pt row.** Before: three 44×38 `chromeRaised` tiles with
captions, a `ViewThatFits` pair that swapped them for 28 pt icons when the sidebar narrowed,
and a centred `v0.1.0 (1)` label under them. After: three flat 28 pt icon buttons on a single
row, the 1 pt separator kept, and no version anywhere in the sidebar.

**Icon-only at every width is what buys the height** — and it is also what removes the
clipping class the criteria ask about. A caption is the part a longer translation or a larger
text size grows; there is no caption left to grow, and `ViewThatFits` went with it. The names
did not disappear: `Label(...).labelStyle(.iconOnly)` keeps each one as the tooltip and the
VoiceOver label, so the spoken name and the drawn control cannot drift apart.

**The version moved to Settings → General → About** (`AppVersion.current.summary`), beside the
per-plugin versions Settings already reports. `AppVersion` takes a `Bundle` rather than
reaching for `.main`, which is what makes it assertable without an app.

**Every number is borrowed, none invented** (`SidebarFooterLayout`): 28 pt control and 6 pt
radius from `docs/designs.md`, 7 pt inset from the workspace rows above, 34 pt from the band a
pane's header strip occupies, and the hover wash is the rows' own `Color.primary.opacity(0.04)`
at the same value. Focus borrows the amber stroke `PaneHeaderTextFieldView` already focuses
with.

**No boundary change.** Same-owner host UI calling `openURL`/`openSettings` — typed DIRECT,
no `tenon` member, no intent, no principal, no new capability. `SidebarFooterAction` only names
what the three buttons already did; a test pins the two URLs and the Settings destination so
the restyle cannot quietly re-point one.

Files: `Sources/TenonApp/SidebarFooter.swift` (NEW, model + layout + view),
`Sources/TenonApp/AppVersion.swift` (NEW), `Sources/TenonApp/SidebarSnapshot.swift` (NEW),
`Sources/TenonApp/WorkspaceSidebarView.swift` (old footer deleted),
`Sources/TenonApp/PaneViewSnapshotWriter.swift` (`write(bare:size:to:)`),
`Sources/TenonApp/SettingsView.swift` (About section, additive),
`Sources/TenonApp/TenonApp.swift` (one line in `init()`),
`Tests/TenonAppStateTests/SidebarFooterTests.swift` (NEW), `CLAUDE.md`.
`docs/domains.md` needed no change: the three new files carry `workspace-model`, the tag the
sidebar, `ContentView` and `AppMark` already carry.

## Evidence

- RED first: 12 tests, 22 assertion failures against stubbed constants; green after the
  implementation. Full suite **1678 / 2**, and both failures are another session's in-flight
  `WorkspaceIdentityTests` (T-097) on files this task never touched — reported, not fixed.
- **6/6 mutations caught**, each its own build and `cmp`-verified restore. M1 control 28→40 pt
  (3 tests fail — the band, the height, and the min-width fit), M2 height 34→68 pt, M3 the
  width rule drops its gap term, M4 Feedback lands on the project root instead of `issues/new`,
  M5 the Settings identifier renamed, M6 a blank version key kept as `""` instead of unknown.
  M1 and M2 each had to be re-run: their first attempts died on peer compile breaks in
  `TabReorderTests`/`ShellTitleBar`/`TabStripReorderTests`, which the harness reports as
  "no Executed line" rather than as a survival.
- Two geometry assertions passed vacuously against the zero-valued stubs and are only
  load-bearing because M1/M2 fire on them — that is what those two mutations are for.
- Visually verified through a NEW `TENON_SIDEBAR_SNAPSHOT` renderer that mounts the real
  `WorkspaceSidebarView` over a real `WorkspaceStore`, with no pane chrome around it: 232 pt
  default and 110 pt (`SidebarResize.minWidth`), plus a before-picture of the old footer for
  the weight comparison. Nothing clips at 110 pt; the row sits leading-aligned under the
  separator with the workspace names truncating exactly as they already did.
- Version format checked against the installed bundle: `/Applications/Tenon.app` carries
  `0.1.0` / `1`, so Settings reads `v0.1.0 (1)` — the same string the sidebar used to show.
  Under `swift run tenon` there is no `Info.plist` and it reads `v— (—)`, which is why the
  fallback is a visible dash rather than an empty field.

## Limits, stated not sold past

- **There is no light appearance to verify.** `TenonTheme` is a single fixed dark palette of
  `NSColor(hex:)` literals with no `prefers-light` variant anywhere in the app, so the
  criterion's light half has no surface. What was checkable was checked: the footer introduces
  no token of its own and reuses only `TenonTheme.line`, `.muted`, `.amber` and the rows'
  existing hover value.
- **The focus ring is not photographed.** An offscreen `cacheDisplay` render has no key window
  and no first responder, so the amber stroke's rendering is unverified visually; the code path
  is the one `PaneHeaderTextFieldView` uses. It appears only under Full Keyboard Access, which
  is also true of the previous footer's system ring.
- **Settings' About row is not photographed either** — a window cannot be captured from a
  headless shell, and the About row is in a `Settings` scene rather than a pane. The string it
  renders is asserted; its placement is not.
- **`Sources/TenonApp/TenonApp.swift` is claimed by T-071.** One line was added inside `init()`
  — `SidebarSnapshot.renderIfRequested()`, beside the three existing snapshot hooks — a region
  that task is not working in. If it conflicts, that line is the whole change and is safe to drop.
- **`Sources/TenonApp/WorkspaceSidebarView.swift` is being co-edited** by the T-097 session,
  which added `WorkspaceMark`, `WorkspaceRowAnnouncement` and a Customise popover to the rows
  while this task deleted the footer types below them. Both changes are in the tree and neither
  overwrote the other; nothing of theirs was stashed, reverted or restored.
- The tag on the new files is `workspace-model` by precedent (`AppMark.swift` and
  `ContentView.swift` carry it for shell chrome that is not a workspace value). A `shell-chrome`
  domain is arguably the honest one; splitting `workspace-model` is not this task's call.
- Not committed.

## Reference
The reported footer shows three large square buttons in a row with a separate centered `v0.1.0 (1)` label below them. The target is a materially denser, calmer treatment, not merely smaller text inside the same tiles.
