# T-002: Personalize workflow via Settings
> App-level preferences: default content for new tab/split/workspace, browser config surfacing, sidebar launch state, accent color.
- **priority**: high
- **effort**: M

## Criteria
- [x] `AppPreferences` pure value + `DefaultPaneContent` mapping live in TenonCore, unit-tested
- [x] `newTab` / `splitActiveSlot` / `splitSlot` / `addWorkspace` honor configured default content
- [x] Settings window has General / Browser / Plugins tabs
- [x] Browser config (home, search, UA, remember) surfaced in Settings
- [x] Sidebar visible-on-launch + default width configurable and honored
- [x] Accent color preset configurable
- [x] Preferences persist across restart (UserDefaults JSON blob)
- [x] swift build + swift test green (190 tests, 0 failures); app launches without crash
- [x] Settings redesigned to modern macOS System Settings look (NavigationSplitView sidebar + grouped Form) — SettingsView.swift

## Owner / files (agent lock) — session 537832b5
Cleared: work complete, build green. Files touched (all built):
TenonCore/AppPreferences.swift, TenonApp/AppPreferencesStore.swift, TenonApp/SettingsView.swift,
TenonApp/TenonTheme.swift, TenonApp/ContentView.swift; content params in TenonCore/Workspace.swift.
Shared files (TenonApp.swift, WorkspaceStore.swift) co-edited with the RecentStore task — merged clean.
Visual confirmation of the redesigned Settings pane is pending a human look (headless shell cannot screenshot).
