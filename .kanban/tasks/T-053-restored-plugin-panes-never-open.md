# T-053: Restored plugin panes stay "Plugin view unavailable" until the first workspace mutation
> Launch the app with a persisted plugin pane and it renders the placeholder forever: the restored catalog never reaches `reconcileViewInstances`, so no view instance is opened until something else mutates the workspace.
- **priority**: high
- **effort**: S

## Owner / files (agent lock)
Released — DONE 23:2x, session ed76fd97. All claimed files are FREE.

## Root cause (verified live, 23:0x)
Found while verifying T-052 in the running app (debug build, launched 22:51 with three
persisted kanban panes): every one showed "Plugin view unavailable" although the plugin
runtime was alive — a storage probe hot-reloaded into the shipped JS proved eval ran and
`views.onOpen` never fired. The chain:
- `WorkspaceStore.apply` publishes events (and `PluginHost.emit(workspaceEvents:in:)`
  ends with `reconcileViewInstances(from:)`) only on a real **mutation**; restoring the
  catalog at launch is not one.
- `AppComposition.performStart` (TenonApp.swift:508) reconciles **web surfaces** against
  the restored catalog after `host.loadAll()` but never calls
  `host.reconcileViewInstances(from: store.catalog)`.
- So `lastWorkspaceCatalog` stays nil; the post-load and post-reload reconcile hooks in
  PluginHost (:1195, :1984) are no-ops. The pane sits dead until any workspace mutation.
Measured: one CLI `workspace.pane.focus.v1` made all three panes open and the 113 KB
board render (`cols:5` via the probe) — reconcile itself is correct; it is never invoked.

## Criteria
- [x] Relaunch test: a persisted `.pluginView` pane is open (its `PluginViewSection`
  published) after `composition.start()` alone — no mutation, red before the fix —
  `RestoredPluginPanesTests.testARestoredPluginPaneIsOpenAfterStartAlone`, genuine
  red first (`XCTAssertNotNil failed — a restored plugin pane must be opened by
  start() itself, not by the next workspace mutation`)
- [x] Fix is the symmetric sibling of the existing web-surface reconcile in
  `performStart`, not a second protocol — one call beside
  `webSurfaces.reconcile(catalog:host:)`, TenonApp.swift:519
- [x] Mutation proof M46: removing the reconcile call reddens exactly the new test on
  its named assertion; restore cmp-verified byte-identical
- [x] Full `swift test` green: **910 / 0** (was 909). Independent reviewer
  (feature-dev:code-reviewer) verdict: sound, no defects — traced the
  `isReconcilingViews` guard-drop (redundant, not lossy), double-open impossibility
  (`desired.subtracting(current)` empty on follow-up), and confirmed the test has no
  alternate trigger (`loadAll`'s reconcile is gated on nil `lastWorkspaceCatalog`,
  `start()` performs zero store mutations)
