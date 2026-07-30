# T-018: Plugin builtins round 2 — fs.watch, commands.execute, net.fetch, secrets

> The rest of the builtin sweep started in T-017: stop plugins polling the filesystem,
> let a plugin call another plugin's command, and open the two capabilities that gate a
> whole class of plugins — network and secret storage.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 0c434576 — ACTIVE

Mine (claiming):
- `poc/Sources/TenonCore/PluginRuntime.swift` — NEW blocks: `tenon.fs.watch`, `tenon.commands.execute`,
  `tenon.net`, `tenon.secrets`
- `poc/Sources/TenonCore/PluginHost.swift` — command routing across plugins, watcher ownership
- `poc/Sources/TenonCore/PluginManifest.swift` — `network.allow` allowlist + 2 new permissions
- `poc/Sources/TenonCore/PathWatcher.swift` — NEW (FSEvents for an arbitrary path)
- `poc/Sources/TenonCore/SecretStore.swift` — NEW (Keychain)
- `poc/Tests/TenonCoreTests/PluginBuiltinsTests.swift` — mine from T-017
- `poc/plugins/git/main.js`, `poc/plugins/file-explorer/main.js` (only if released by T-016)

NOT touching: anything held by T-015 (`claude-sessions/**`, `PaneTarget.swift`, `SurfacePool.swift`)
or T-016 (`Package.swift`, `Vendor/**`, `SourceEditorView.swift`, `SyntaxHighlighting.swift`,
`FileSlotView.swift`, `file-explorer/**`, `FileExplorerPluginTests.swift`).

## Corrected scope

Workspace events were listed as missing in the T-017 design write-up. **They already exist** —
`WorkspaceStore.swift:179` emits `workspace.changed` plus per-event topics
(`workspace.tab-opened`, `workspace.selected`, …). What is missing is plugins *using* them
instead of polling; the git plugin gets that here.

Keybinding contribution (`register({key: "cmd+shift+g"})`) is also NOT in this task:
`shortcut` currently only renders as palette text, and binding it for real is a SwiftUI
menu-composition problem with no headless test. Separate task.

## Criteria
- [x] `tenon.fs.watch(path, {recursive}, cb)` behind `filesystem.read`; returns a handle with
      `cancel()`; every watcher dies with the runtime
- [x] `tenon.commands.execute(id)` runs another plugin's command through the host; unknown id
      answers `{ok:false,error}`, never throws
- [x] `tenon.net.fetch(url, opts)` behind a new `network` permission AND a manifest
      `network.allow` host allowlist — an undeclared host is refused even with the permission
- [x] `tenon.secrets.get/set/delete` behind a new `secrets` permission, stored in the Keychain,
      never in the plugins directory
- [x] `knownPermissions` grows to exactly 10; every new capability keeps a blocked+allowed pair
- [x] git plugin refreshes on `workspace.selected` instead of only on its timer
- [x] `swift build` clean + full suite green

## Outcome

Shipped. `docs/design-plugin-builtins.md` covers T-017 + T-018 as one record.

**371/371 green, `swift build` clean.** `knownPermissions` is now 10 (`network`, `secrets`).
`network` is the first permission that is not sufficient on its own — the manifest must also
list hosts under `network.allow`, and an off-list request is refused *and* recorded as a
permission violation.

git plugin now: watches its repo through `fs.watch` (debounced 400 ms) with the 15 s timer as
the backstop, and re-resolves on `workspace.selected` instead of showing the previous repo
until the next tick. It declares `filesystem.read` for the watch.

⚠️ One line touched outside my claim: `PluginCapabilityTests.swift:34` — the
`knownPermissions` equality assertion, extended 8 → 10. Same line T-014 flagged as a likely
rebase point.

**Not done, deliberately** (both now recorded in the design doc): keybinding contribution
(SwiftUI menu composition, nothing headless to assert) and terminal output as an event
(blocked upstream — T-009 proved `ghostty_surface_read_text` returns the viewport, not
scrollback).
