# T-167: Every bundled plugin's implementation becomes compiled Swift

> Operator directive 2026-08-14 16:23: convert all seven JavaScript bundled plugins to
> compiled Swift programs. The JavaScript runtime stays a supported boundary for third-party
> plugins; what changes is that no shipped plugin is written in it.

- **priority**: high
- **effort**: XL
- **PRDs**: `TENON-PRD-010` (plugin-runtime), `TENON-PRD-014` (kanban), `TENON-PRD-005` (views)
- **CLAIMED by session `cabfc72c` 2026-08-14 17:2x, operator-directed. Fifth card in Doing,
  over the WIP limit, by explicit instruction.**
- **Supersedes** `docs/plugin-migration-bundled-swift.md`'s five-port plan and its
  "hello-palette stays JavaScript" decision (that doc's `:44-45`).

## Owner / files (agent lock)

Seam, TenonBundledPlugins:
- `Sources/TenonBundledPlugins/BundledPluginProgram.swift`
- `Sources/TenonBundledPlugins/BundledPluginRuntime.swift`

Seam, TenonCore (see collision note):
- `Sources/TenonCore/PluginHostModels.swift`
- `Sources/TenonCore/PluginHost.swift`
- `Sources/TenonCore/PluginRuntime.swift`
- `Tests/TenonCoreTests/BundledPluginLocalStateTests.swift` (new, S1 + S2)
- `Tests/TenonCoreTests/{PluginHost,PluginBuiltins,PluginPlatform}Tests.swift` (`emit` → `deliverEvent`)
- `Sources/TenonCore/PluginRuntimeValueParsing.swift`
- `Sources/TenonCore/PluginViewNode.swift`
- `Sources/TenonCore/PluginPath.swift` (new)

Ports (new files):
- `Sources/TenonBundledPlugins/HelloPalettePlugin.swift`
- `Sources/TenonBundledPlugins/BrowserPlugin.swift`
- `Sources/TenonBundledPlugins/FileExplorerPlugin.swift`, `FileExplorerTree.swift`
- `Sources/TenonBundledPlugins/ClaudeSessionsPlugin.swift`, `ClaudeSessionsScan.swift`, `ClaudeSessionsView.swift`
- `Sources/TenonBundledPlugins/GitPlugin.swift`, `GitStatusParser.swift`, `GitPluginView.swift`
- `Sources/TenonBundledPlugins/KanbanPlugin.swift`, `KanbanBoardFormat.swift`, `KanbanBoardView.swift`
- `Sources/TenonBundledPlugins/ViewGalleryPlugin.swift`

Tests and manifests:
- `Tests/TenonCoreTests/BundledPluginMigrationGuardTests.swift`
- `Tests/TenonCoreTests/BundledPluginViewRoutingTests.swift`
- `Tests/TenonCoreTests/BundledPluginResourceOwnershipTests.swift`
- `Tests/TenonCoreTests/{Kanban,GitPluginParse,Browser,AgentSessionFavourites,WorkspaceScopedViewState,ShippedPlugins}*.swift`
- `plugins/*/manifest.json`, `plugins/*/main.js`
- `docs/plugin-migration-bundled-swift.md`, `Tenon.xcodeproj/project.pbxproj`

**Collision note.** T-140 (session `40b0d244`, claimed 2026-08-12 15:3x) lists
`PluginHost.swift`, `PluginRuntime.swift`, `PluginRuntimeBootstrap.swift` and
`docs/prds/plugin-runtime.prd.md`. None of those files is dirty in the working tree and the
last commit touching `PluginRuntime.swift` is `039f11b` (2026-08-12), so the claim reads as
stale rather than live. This task edits `PluginRuntime.swift` and `PluginHost.swift` and only
*reads* `PluginRuntimeBootstrap.swift`. Escalate to the operator if that session resumes.

## Evidence this plan rests on

Surveyed 2026-08-14 by eleven agents over every line of the seven plugins and the seam
(workflow `wf_abd0a41b-8b8`). Three claims in `docs/plugin-migration-bundled-swift.md` were
refuted and are corrected by this task, not carried forward:

1. View routing and `openViewInstances` are listed there as missing gaps; both shipped in
   `a6c5f80`, the same commit that wrote the doc (`BundledPluginRuntime.swift:344-414`, `:456`).
2. `tenon.path.*` is called free because "Swift already has" it. `PluginRuntimeBootstrap.swift:233-252`
   is a pure string normalizer: no `~` expansion, no symlink resolution, `basename("/") == "/"`,
   empty relative result becomes `"."`. Foundation differs on all four, and `file-explorer`'s
   tree root is the literal string `"~"` (`plugins/file-explorer/main.js:64`).
3. Dynamic palette providers are deferred because "only hello-palette uses them".
   `rg 'tenon\.palette|tenon\.agents' plugins/` returns nothing — no shipped plugin uses either.

Standing defect found by the survey: `PluginHostRuntime.emit` names two opposite directions.
`PluginRuntime.swift:407-417` implements host→plugin delivery; `BundledPluginRuntime.swift:254-260`
implements plugin→host publish behind an `events.publishes` guard. The tree's only call site,
`PluginHost.swift:1338`, means delivery — so every bundled plugin's `settings.changed` throws
`undeclaredEventPublication` today and is swallowed at `:1345-1349`.

## Operator decisions recorded

- All seven port; `plugins/` ships no JS. `hello-palette`'s JavaScript was first kept as a
  fixture under `Tests/`, which nothing ever read — **reversed 2026-08-16**: the fixture is
  deleted, and the two `ShippedPluginsTests` cases that only ran against `runtime: javascript`
  are replaced by `testEveryCompiledPluginOnlyNamesIntentsItsOwnManifestDeclares`, which reads
  each plugin's own Swift sources for versioned intent IDs its manifest never declared
  (mutation-checked in both a program file and a split-out file). `ShippedPluginsTests` never
  covered FSEvents, before this task or after it.
- `PluginViewNode` gains a structured action both backends can emit; the `\u{1}`+JSON encoder
  (`PluginRuntimeValueParsing.swift:699-709`) and `decodeActionIdentifier`
  (`PluginRuntime.swift:2107-2116`) are deleted in that same change — they have zero tests and,
  after the ports, zero callers.
- Taken from the invariants without asking: `activate` becomes bounded by the unread
  `configuration.startupTimeout` (invariant 10); `PluginHost.loadAll` stops aborting the whole
  inventory when one bundled program is untrusted or unregistered (invariant 4).

## Criteria

Seam, in dependency order — each lands red-first with its own test:

- [x] S1 Split `emit` into host→plugin delivery and plugin→host publish; a bundled plugin
      observes `settings.changed`. `PluginHostRuntime.deliverEvent` is the delivery member both
      backends implement; publication moved to `BundledPluginContext.emit`, still gated by the
      manifest's `events.publishes` and the generation's phase.
- [x] S2 Live settings/storage on the compiled context, replacing the frozen
      `PluginRuntimeLocalState` captured at `BundledPluginRuntime.swift:136-141`.
      `BundledPluginLocalState` holds them for the generation's life; a delivered
      `settings.changed` refreshes a setting before the callback is enqueued, and only a
      host-confirmed `persistStorage` commits a storage value.
- [x] S3 Separate view registration from per-instance bodies, and add a push contribution
      channel so an intent handler and a timer can render. `BundledPluginViewRoutingTests`
      covers callback ordering, instance tracking/pruning, and replacement contributions;
      `BundledPluginResourceOwnershipTests` covers an intent-pushed contribution.
- [x] S4 Retire `testBundledPluginsPublishNoViewsWhileTheRuntimeDropsViewCallbacks`, replace
      the old guard with entrypoint-only coverage, and correct `docs/plugin-migration-bundled-swift.md`.
- [x] S5 One shared path helper with the JS bootstrap's exact POSIX semantics. `PluginPath`
      is parity-tested against the bootstrap rules.
- [x] S6 Generation- and instance-scoped `timers.after/every/cancel`.
- [x] S7 Generation- and instance-scoped `fs.watch` with its permission gate, plus real
      `permissionViolations` reporting (`BundledPluginRuntime.swift:459` hardcodes `[]`).
- [x] S8 Structured view action on both backends; encoder and decoder deleted. `PluginNodeAction`
      carries named or owned structured values directly through both runtimes.
- [x] S9 Bounded `activate`; `loadAll` marks one plugin failed instead of aborting all.

Ports, each with its manifest flipped to `bundled-swift`, its `main.js` deleted, and its
existing tests re-hosted onto the compiled backend:

- [x] P1 `hello-palette` (compiled provider; the JS entrypoint is deleted)
- [x] P2 `browser`
- [x] P3 `file-explorer`
- [x] P4 `claude-sessions`
- [x] P5 `git`
- [x] P6 `kanban`
- [x] P7 `view-gallery`

Closing:

- [x] `rg -l 'main\.js' plugins/` returns nothing; `plugins/*/manifest.json` all say `bundled-swift`.
- [x] All re-hosted suites pass on the compiled backend; full suite is 2,285/0.
- [x] `xcodegen generate` leaves no diff.
- [x] `TENON-PRD-010` and `TENON-PRD-014` decision logs record the supersession, the
      hot-reload consequence (compiled plugins move to the app's release cadence), and a
      dated verification receipt.
