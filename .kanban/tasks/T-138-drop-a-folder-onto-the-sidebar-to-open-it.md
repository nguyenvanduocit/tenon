# T-138: Drop a folder onto the sidebar to open it

> Dragging a folder from Finder onto the workspace sidebar opens a workspace rooted at that
> folder — the same outcome "Add Workspace…" reaches through an open panel, without the panel.

- **priority**: medium
- **effort**: S
- **PRD**: `TENON-PRD-001` (`docs/prds/workspace-shell.prd.md`) — sidebar and workspace catalog
- **requirements**: `WS-FR-025`

## Why

Opening a workspace today costs a right-click, a menu, an `NSOpenPanel`, and a navigation
back to a folder the operator already has in front of them in Finder. The drop is the
shortest path between "this folder" and "supervise work in this folder", and every rule it
needs already exists in the catalog: `WorkspaceStore.addWorkspace` records the recent entry,
and `RecentWorkspaceStore.folderKey` is the identity two URLs naming one folder compare on.

## Decisions (product owner, 2026-08-12)

- A dropped **file** is refused, not reinterpreted. The sidebar accepts `public.folder` only,
  so the pointer shows a refusal over a file instead of the app guessing at a parent folder.
- **Several folders at once all open**, in the order they were dropped; the last one lands
  active, which is what a run of `addWorkspace` calls already does.
- A folder that is **already open** selects its existing row rather than adding a duplicate —
  the rule `openRecent` applies to the recents menu, applied to the same identity key.

## Owner / files (agent lock)

Released 2026-08-12 16:2x by session `809e80b7`. The files below are free; they are listed
as what this task changed, not as a claim on them.

- `Sources/TenonCore/WorkspaceFolderDrop.swift` (new)
- `Sources/TenonApp/WorkspaceSidebarView.swift`
- `Tests/TenonCoreTests/WorkspaceFolderDropTests.swift` (new)
- `Tenon.xcodeproj/project.pbxproj` (xcodegen regeneration for the two new files)
- `docs/prds/workspace-shell.prd.md`, `docs/prds/workspace-shell.feature`

## Criteria

- [x] A folder dropped on the sidebar opens a workspace rooted at it, named by `WorkspaceName.derived`
- [x] A folder already open selects that workspace instead of adding a second one
- [x] A dropped file changes nothing, and the sidebar never offers itself as its target
- [x] Several folders dropped together all open, last one active
- [ ] The drop target is visible while a folder hovers it and gone once it leaves — **UNVERIFIED**: no offscreen route mounts a drag, so the amber ring and the pointer's refusal over a file are AppKit's answer to the declared `public.folder` type and to `isTargeted`, read at source rather than photographed
- [x] Rules asserted in `TenonCoreTests` without a window; red before green
- [x] `WS-FR-025` written with a tagged scenario, delivery row, and a dated receipt

## Evidence

- `WorkspaceFolderDropTests` **9 / 0**. Red first at **7 of 9** against a stub returning no
  actions; the two that passed under the stub are the refusal cases, so each was proved by
  mutation rather than by its own first run.
- Mutations, one at a time, each restored byte-identically afterwards:
  drop the `isDirectory` guard → **3 red**; drop the same-drop dedupe → **1 red**;
  match an open workspace on raw `URL` equality instead of `RecentWorkspaceStore.folderKey`
  → **1 red**.
- Full suite **2063 tests, 4 failures — none in this file set**:
  `CLISocketServerTests.testTheHandlerReceivesTheKernelsPeerProcessIDForTheConnection`
  (T-136's lane, that file is dirty with its work) and
  `PluginWebSurfacePoolTests.testCrossOriginSubframeCannotRedirectTheSurface` (recorded
  as load-sensitive by T-124). Both suites re-run in isolation: **31 / 0**.
- `swift build` clean. Sidebar photographed at both bounds after the drop zone was wrapped
  around the row list — rows and footer unchanged at 232 pt and at `SidebarResize.minWidth`.

## Notes for whoever commits this

`Tenon.xcodeproj/project.pbxproj` was regenerated for the two new files, but it was already
dirty with another lane's test files before this task started. Committing it commits their
entries too.
