# Bundled-Swift migration map — the five view plugins

- **Status:** current — the working map for the ports T-155 left open
- **Anchors:** `.kanban/tasks/T-155-bundled-swift-is-an-implementation-not-a-second-plugin-system.md`
  (decision and follow-up boundary),
  [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)
  ("Implementation language never reclassifies the boundary"),
  `Tests/TenonCoreTests/BundledPluginMigrationGuardTests.swift` (the guard this map pairs with)

T-155 ported `clock`, `core-commands`, and `workspace-status` — the three plugins with no
view. The five that remain (`browser`, `git`, `file-explorer`, `claude-sessions`, `kanban`)
all register an **instanced view**, and the compiled runtime does not route view callbacks
yet: `BundledPluginRuntimeActor.invokeViewSelect/invokeViewSubmit` return `false`,
`openViewInstance/closeViewInstance` reach no program code, and `PluginRuntimeSnapshot.
openViewInstances` is always empty. A port taken today would stage cleanly, render its view,
and drop every click. The guard test keeps that state unshippable; this map says what has to
land, in what order, to lift it.

Nothing here changes a plugin's classification. A `bundled-swift` manifest still owns a
plugin generation: views and status stay CONTRIBUTIONs, select/submit stay owner-scoped
EVENT facts, host effects stay declared INTENTs, and only the sealed bundled inventory may
select compiled code. The runtime work below extends `BundledPluginProgram` — the
package-internal program shape — not the public boundary.

## What the compiled runtime serves today

- `activate` / `receiveEvent` → one `BundledPluginContribution` (status-bar text + static
  views) republished through the snapshot path;
- `invokeIntent` with `IntentProviderContext` for causal nested sends;
- statically declared `subscribedEvents`, delivered through a bounded 256-entry mailbox;
- `emit` for manifest-declared published channels;
- manifest settings via `PluginRuntimeLocalState`, storage via
  `PluginRuntimeConfiguration.PersistStorage`, attributed logging.

## Runtime gaps, in dependency order

| # | Gap | Blocks | Shape of the work |
|---|---|---|---|
| 1 | **View event routing.** `BundledPluginProgram` needs a view-event entry (select, submit, open, close — instance-scoped) that `invokeViewSelect/invokeViewSubmit/openViewInstance/closeViewInstance` call, returning an optional replacement contribution like `receiveEvent` does. | all five | Same EVENT classification the JS runtime uses; no new `tenon` surface, no host services. |
| 2 | **View-instance state.** All five views declare `instanced: true`; the actor must track open instances so `openViewInstances` in the snapshot stops being hardcoded `[]` and per-instance republish works. | all five | Actor-local state, torn down on shutdown (invariant 10). |
| 3 | **Compiled-program resources: timers and fs.watch.** `timers.after/every/cancel` and `fs.watch` with generation-scoped cancellation on retirement. `process.stream` is needed by none of the five. | git, kanban | Mirror the JS resource bounds; retirement cancels everything the generation owns. |
| 4 | **Storage read semantics on the compiled context.** The write path exists (`persistStorage`); `claude-sessions` also depends on the documented read-back cache behaviour of `tenon.storage.get` after a refused host write. | claude-sessions | Small; verify parity with the JS facility before relying on it. |

Deliberately **not** on the list: dynamic palette providers (`palette.registerProvider` is
used only by `hello-palette`, which stays JavaScript as the teaching example) and
`tenon.path.*` (pure string helpers Swift already has).

## Per-plugin map

Measured from `plugins/*/main.js` and each manifest on 2026-08-14.

| Plugin | Lines | Waits on gap | Beyond the view: what the port carries |
|---|---:|---|---|
| `browser` | 137 | 1, 2 | 1 provided intent, 5 used intents, observes `web.did-navigate`, 2 settings. No timers, no watch, no storage. |
| `file-explorer` | 494 | 1, 2 | 5 provided intents, 14 used intents, observes `settings.changed` / `workspace.changed` / `pane.cwd-changed` / `workspace.slot-focused` / `workspace.slot-closed`. Path helpers become plain Swift. |
| `claude-sessions` | 1,009 | 1, 2, 4 | 2 provided intents, favourites in plugin storage, observes `settings.changed` / `workspace.changed`. Heavy scan logic is pure and moves as ordinary Swift. |
| `git` | 843 | 1, 2, 3 | 400 ms debounce (`timers.after`), 15 s poll (`timers.every`), recursive `fs.watch` on the repo, status-bar text (already supported), 6 provided intents, six observed channels. |
| `kanban` | 1,021 | 1, 2, 3 | Debounce + tracking timers, recursive `fs.watch`, publishes `board.changed` (`emit` already supported), staged `filesystem.file.write.v1` for the 113 KB board (host-side resource, unchanged). Owned by T-150; T-151's full-tree resend cost is the other reason this one goes last. |

**Port order: browser → file-explorer → claude-sessions → git → kanban.** The first three
need no new resource machinery, so gaps 1–2 alone unlock them smallest-first; git and kanban
wait for gap 3, and kanban additionally belongs to T-150's scope and decision log.

## Rules every port keeps (enforced, not remembered)

- The manifest keeps its exact `id`, permissions, `intents.uses/provides`, events, and
  settings; only `runtime: bundled-swift` is added and `main.js` is deleted **in the same
  change** — `BundledPluginMigrationGuardTests` reddens on a shadowing entrypoint.
- No bundled-swift plugin publishes a view until gap 1 lands —
  `testBundledPluginsPublishNoViewsWhileTheRuntimeDropsViewCallbacks` reddens, and its
  companion assertion reddens when routing lands, forcing the guard to become routing
  coverage in that same change.
- `ShippedPluginsTests` continues to stage every declared handler for both backends; a
  compiled port missing a program or a handler fails there by exact id.
