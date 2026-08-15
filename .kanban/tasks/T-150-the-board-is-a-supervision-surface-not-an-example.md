# T-150: The board stays a plugin and moves to compiled Swift

> Operator decision, 2026-08-14: plugin is the unit of identity, management, authority,
> contribution, and lifecycle; JavaScript is not part of that definition. Kanban remains a
> plugin but its implementation becomes Swift compiled into Tenon's bundled-plugin target.

- **priority**: medium
- **effort**: L
- **PRDs**: `TENON-PRD-014` (kanban), `TENON-PRD-010` (plugin runtime),
  `TENON-PRD-011` (interaction boundaries)
- **DONE 2026-08-16 — delivered whole by T-167.** Kanban ported with the other nine bundled
  plugins rather than on its own: `Sources/TenonBundledPlugins/KanbanPlugin.swift`,
  `KanbanBoardFormat.swift`, and `KanbanBoardView.swift` hold parsing, relocation, paging, run
  tracking, and view state as compiled Swift. The manifest keeps its `PluginID`,
  enable/disable, pane restoration, contributions, intents, and retirement; no host pane kind,
  typed host-service shortcut, or DIRECT inventory entry was added. The view-interaction and
  resource slice this card waited on landed as T-158 (view callbacks) and T-167 S3/S6/S7
  (instance state, timers, watches). EVIDENCE: `swift test --filter 'Kanban|BundledPlugin'`
  **66/0** with `KanbanPluginTests` **32/0**, full suite **2,285/0**, receipt in
  `docs/prds/kanban.prd.md:260`.
- **Does not depend on T-149 and adds no DIRECT inventory entry.**

## Why

The board is how Tenon organizes parallel workstreams, but product importance does not make
it part of the host semantic owner. It can still be installed, disabled, replaced, and have
its contributions retired as one `PluginID`; therefore it remains a separate plugin owner.
The implementation language changes to Swift so its parser, relocation, and view state are
compiled and typed without creating a second management path.

`PRT-FR-048` is the architectural base: a `bundled-swift` manifest resolves an exact compiled
program only from bundled provenance and then follows the same provider/event/contribution
lifecycle as JavaScript. Kanban must extend that backend through the existing plugin view and
resource abstractions; it must not receive `WorkspaceStore`, AppKit, SwiftUI host state, or
another typed host-service shortcut.

### Superseded direction, preserved as evidence

The earlier card proposed a host-native pane and a new DIRECT inventory entry. Its best
argument was that SwiftUI diffing and pure Swift parsing would remove JavaScript/view-tree
cost. The operator rejected the ownership conclusion: those are implementation benefits,
not proof that the board must lose plugin management. The measurements remain useful:

1. Plugin view drag/drop already exists (`PluginViewNode.swift:63-66`).
2. Plugin modal presentation already exists and is used by Kanban.
3. `PluginRuntime.setViewBody` reparses a full contribution with no equality check; T-151
   remains the cross-plugin fix for that JavaScript path.
4. Kanban is the strongest public-boundary dogfood, so keeping it a plugin preserves rather
   than creates that obligation.

## Order of work

- [x] Extend `TenonBundledPlugins` with owner-scoped view selection/submission, instance
      lifecycle, settings/storage/log, and resource ownership using existing mechanisms.
      Landed as T-158 (view callbacks) plus T-167 S2/S3/S6/S7.
- [x] Port board parsing, task relocation, paging, and run tracking to pure Swift values with
      red-first tests using the current acceptance examples. `KanbanBoardFormat.swift`,
      `KanbanPlugin.swift`; `KanbanPluginTests` 32/0.
- [x] Publish the same declarative plugin view contribution and route every finite host effect
      through the same canonical intents the JS implementation uses. `KanbanBoardView.swift`
      publishes the view; effects stay manifest-declared intents.
- [x] Change only the Kanban manifest to `runtime: bundled-swift`, then delete its `main.js`;
      keep the plugin directory, `PluginID`, enable/disable state, pane restoration, and PRD.
- [x] Update `TENON-PRD-014` decision history and verification receipt without adding a host
      pane kind or DIRECT entry. `docs/prds/kanban.prd.md:260`.

## Criteria

- [x] Board reads, renders, moves cards, and tracks runs at parity with the shipped plugin,
      asserted against `docs/prds/kanban.feature` — that file is unchanged by the port and
      `KanbanPluginTests` passes 32/0 against it.
- [x] Board parsing/relocation/write logic is pure Swift and tested without a window.
      `KanbanBoardFormat.swift` is exercised entirely from `TenonCoreTests`.
- [x] Disabling `dev.tenon.kanban` withdraws its panes/providers/resources; re-enabling restores
      it through `PluginHost`, not through a host feature flag. Covered by
      `BundledPluginResourceOwnershipTests` and the host lifecycle suites, 66/0 together.
- [x] The compiled plugin receives no typed host application service and every finite effect
      remains a manifest-declared intent. `BundledPluginMigrationGuardTests` sweeps the real
      inventory; `DirectInventoryGateTests` is untouched by this work.
- [x] A native visual receipt catches the scattered-card regression T-055 found.
      `TENON_VIEW_SNAPSHOT='dev.tenon.kanban/board:…'` renders the compiled board offscreen.
- [x] `plugins/kanban/main.js` is gone, while `plugins/kanban/manifest.json` and plugin identity
      remain.
- [x] Full suite green, `xcodegen generate` clean, every source `@domain:`-tagged, and
      `DirectInventoryGateTests` unchanged. Full suite **2,285/0**; `DomainTagFitnessTests`
      green inside it.

## Owner / files

Unclaimed. Expected files: `plugins/kanban/`, native bundled-plugin runtime/view support,
Kanban Swift sources/tests, and the Kanban/runtime PRD receipts. T-149's host-pane registry is
explicitly outside this task.
