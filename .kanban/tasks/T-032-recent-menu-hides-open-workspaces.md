# T-032: Recent-workspaces menu stops offering the workspaces that are open
> The sidebar's Add-Workspace menu listed the open workspace as a "recent" one, so the
> folder already sitting one row above was offered again as something to open.

- **priority**: medium
- **effort**: XS

## Owner / files (agent lock)
session `1a79a1bf`

Claimed files:
- `Sources/TenonCore/RecentWorkspaceStore.swift` — NEW `recent(excludingFolders:)` + `folderKey`
- `Sources/TenonCore/WorkspaceStore.swift` — NEW `openWorkspaceFolders` (declaration ~37,
  one line in `init`, three lines at the end of `apply`, one private `folders(in:)`). Nothing
  else in this file — @d25d3c17 T-026's `duplicateSlot` is untouched.
- `Sources/TenonApp/WorkspaceSidebarView.swift` — the menu's filter + `openRecent`
- `Tests/TenonCoreTests/RecentWorkspaceStoreTests.swift` — append

## Criteria
- [x] The recent list in the sidebar menu excludes every workspace currently in the catalog,
      and offers it again as soon as it closes
- [x] Filtering happens before the 5-item cap, so open workspaces don't eat menu slots
- [x] Paths are matched by standardized folder, not `URL` identity — the open panel hands back
      `/tmp/a/` while the recents file rehydrates `/tmp/a`
- [x] The menu still doesn't read `store.catalog`: `openWorkspaceFolders` republishes when a
      workspace opens or closes and stays silent through tab/pane churn (asserted with
      `withObservationTracking`, the rule the "menu snaps to a narrower width" comment protects)
- [x] `swift test` — 595 tests, 3 failures, all three T-021's pre-existing provenance/consent
      reds (`AppStatePathsTests` ×2, `BundledPluginConsentTests`), unchanged by this task
