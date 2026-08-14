# T-156: A bundled port cannot outrun its runtime

> Guard the T-155 follow-up boundary in the test suite and write the migration map for the
> five remaining JS plugins, so the next port fails loudly instead of shipping silent UI.

- **priority**: medium
- **effort**: S
- **PRDs**: `TENON-PRD-010` (plugin runtime), `TENON-PRD-011` (interaction boundaries)

## Why now

T-155 landed the compiled backend for `clock`, `core-commands`, and `workspace-status` and
named its own boundary: view callbacks, dynamic palette providers, and view-owned resources
are a follow-up before Kanban, Git, File Explorer, or Claude Sessions can move. That boundary
lives only in prose today. `BundledPluginRuntimeActor.invokeViewSelect/invokeViewSubmit`
return `false`, so a bundled-swift plugin that publishes views would render UI whose every
click is silently dropped — and `ShippedPluginsTests` would stay green, because staging
succeeds. All five remaining JS plugins register an instanced view.

## Criteria

- [x] A sweep over the real shipped inventory asserts no `bundled-swift` plugin directory
      retains a `main.js` (generalizes the clock-only check to every port, present and next).
- [x] The three ported ids are pinned as bundled-swift so a silent regression to JS turns red.
- [x] For every shipped bundled-swift plugin, a started runtime publishes no views, and the
      runtime reports view select/submit unhandled — the assertion that must be consciously
      replaced with routing coverage when the view-callback follow-up lands.
- [x] `docs/plugin-migration-bundled-swift.md` maps each of browser, git, file-explorer,
      claude-sessions, kanban to the exact runtime capabilities its port waits on, in
      dependency order.
- [x] Focused tests pass; no edit to `BundledPluginRuntime.swift` or existing plugin files.

## Evidence

DONE 2026-08-14. Locks released. Focused sweep 17/0
(`BundledPluginMigrationGuardTests|BundledPluginRuntimeTests|ShippedPluginsTests|CoreCommandsPluginTests`),
full suite 2251/0, mutation probe (`plugins/clock/main.js`) reddened the entrypoint sweep by
exact id and was removed with peer state (` D plugins/clock/main.js`) verified intact.
Files shipped: `Tests/TenonCoreTests/BundledPluginMigrationGuardTests.swift`,
`docs/plugin-migration-bundled-swift.md`, one `docs/README.md` index row, pbxproj via
`xcodegen generate`. Left uncommitted by instruction.
