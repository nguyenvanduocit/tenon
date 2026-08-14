# T-151: A view update carries only what changed

> `tenon.views.set` has replace-the-whole-tree semantics and the host reparses every node on
> every call. Every shipped plugin pays full serialization for a one-badge change.

- **priority**: medium
- **effort**: M
- **PRDs**: `TENON-PRD-005` (plugin view vocabulary), `TENON-PRD-010` (plugin runtime bounds)
- **Unclaimed.** Independent of T-149/T-150 — this is the fix for the plugin boundary itself.

## Why

`PluginRuntime.setViewBody` (`Sources/TenonCore/PluginRuntime.swift:1864-1893`) parses the
whole `specification` through `PluginRuntimeValueParsing.viewBody` and overwrites
`viewBodies[viewID][key]`, then calls `markStateChanged()`. There is no comparison against
the previous body and no revision guard: an identical resend costs a full parse and a full
downstream invalidation.

The plugins pay it on every interaction. Kanban rebuilds its entire tree and calls
`tenon.views.set` (`plugins/kanban/main.js:526`) from six sites — every move, every click,
every file-watcher fire (lines 276, 436, 804, 811, 932). `git` (843 lines) and
`claude-sessions` (769 lines) have the same shape.

This is the missing CONTRIBUTION the interaction law asks an author to *name* rather than
route around: there is no way for a plugin to say "this one node changed". Fixing it here
serves every plugin, including any future third-party one, which is the direction
`docs/architecture-interaction-boundaries.md:474` says the law wants.

## Criteria

- [ ] An identical resend of the same body is cheap and does not invalidate downstream —
      asserted by test, not by inspection.
- [ ] A partial update path exists in the public `tenon` surface with the same async API shape
      as the rest of it, or `views.set` gains structural sharing that makes one so; whichever
      is chosen is recorded with its reason in the owning PRD's decision log.
- [ ] The public surface pin (`testRuntimeExportsOnlyTheClassifiedPublicSurface`) is updated
      in the same change if a member is added — invariant 1 stays exact.
- [ ] Bounds hold: no unbounded queue, payload, or retained diff state (invariant 10).
- [ ] A measurement in the task record: cost of one card move before and after, so the claim
      is a number and not an adjective.

## Owner / files (agent lock)

Unclaimed. Files this will hold when claimed:

- `Sources/TenonCore/PluginRuntime.swift`
- `Sources/TenonCore/PluginRuntimeValueParsing.swift`
- `Tests/TenonCoreTests/` additions
- `docs/prds/plugin-ui.prd.md` / `.feature`
