# T-003: Recent workspaces in sidebar context menu
> Show up to 5 recently opened workspaces below "Add Workspace…" so they re-open in one click

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
released — task done

## Criteria
- [x] RecentWorkspaceStore: dedup by path, newest-first, capped, JSON-persisted (survives relaunch)
- [x] WorkspaceStore.addWorkspace records the opened workspace
- [x] Sidebar context menu lists up to 5 recent workspaces (excluding currently-open ones) below "Add Workspace…", each re-opens on click
- [x] swift build green; core logic covered by tests (full suite: 195 tests, 0 failures)
