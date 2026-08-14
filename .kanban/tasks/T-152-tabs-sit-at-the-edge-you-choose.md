# T-152: Tabs sit at the edge you choose

> A General setting lets the person place the tab strip at the top or bottom of the
> workspace. Top remains the default, so existing installs do not move until asked.

- **priority**: medium
- **effort**: M
- **Unclaimed.** Wait for T-144 to release `Sources/TenonApp/ShellTitleBar.swift` before
  claiming this task.

## Why

The tab strip has one fixed home today: the top title-bar row assembled by `ContentView` and
`ShellTitleBar`. Different terminal workflows reserve opposite edges for navigation, but
Tenon offers no preference and moving the strip locally would split interactions that are
currently one surface.

This setting moves the tab strip, not the window title bar. Traffic lights, sidebar controls,
resource summary, and other unrelated title-bar chrome stay at the top. The tab chips, `+`
launcher, close and context-menu affordances, drag/reorder surface, and drop targeting move as
one unit so choosing Bottom does not create a reduced tab bar.

## Criteria

- [ ] `AppPreferences` carries a Codable top/bottom tab-strip position. Missing data from an
      older preferences blob decodes to Top, and the choice persists across relaunch.
- [ ] General Settings exposes a native, keyboard-accessible control labelled for tab
      position with exactly `Top` and `Bottom`; changing it updates the active window without
      requiring a restart.
- [ ] Top preserves the current layout. Bottom places the complete tab strip below the
      workspace content while window controls and unrelated title-bar chrome remain at the
      top.
- [ ] Tab selection, `+` launcher, close/context menu, drag reorder, cross-pane drop targeting,
      focus, and accessibility identifiers behave identically in both positions; there is one
      interaction implementation rather than top and bottom copies.
- [ ] Workspace and terminal content consume the correct remaining height in both positions,
      with no overlap, clipped hit target, or dead strip when the sidebar is expanded or
      collapsed and when the window is narrow.
- [ ] Preference round-trip/default tests and layout/interaction coverage exercise both
      positions. Native visual verification records Top and Bottom with multiple tabs, a
      narrow window, and the sidebar both expanded and collapsed.
- [ ] The implementation follows `docs/designs.md`; the owning Settings/workspace PRD and
      feature scenarios record the setting and its default.

## Owner / files (agent lock)

Unclaimed. Expected files when claimed:

- `Sources/TenonCore/AppPreferences.swift`
- `Sources/TenonApp/SettingsView.swift`
- `Sources/TenonApp/ContentView.swift`
- `Sources/TenonApp/ShellTitleBar.swift`
- `Tests/TenonCoreTests/AppPreferencesTests.swift`
- `Tests/TenonAppStateTests/` tab-strip layout/interaction coverage
- the owning Settings/workspace PRD and feature files
