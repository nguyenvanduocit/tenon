# Bundled-Swift migration map — compiled shipped inventory

- **Status:** current — all shipped bundled plugins are compiled Swift programs
- **Anchors:** `.kanban/tasks/T-155-bundled-swift-is-an-implementation-not-a-second-plugin-system.md`
  (decision and follow-up boundary),
  [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)
  ("Implementation language never reclassifies the boundary"),
  `Tests/TenonCoreTests/BundledPluginViewRoutingTests.swift` (compiled callback coverage),
  `Tests/TenonCoreTests/BundledPluginMigrationGuardTests.swift` (entrypoint guard)

T-167 has ported all ten shipped bundled plugins — `clock`, `core-commands`,
`workspace-status`, `browser`, `hello-palette`, `view-gallery`, `file-explorer`,
`claude-sessions`, `git`, and `kanban`. The compiled runtime routes
select/submit/open/close through a bounded callback pump, tracks open instances, separates
static view registration from instance bodies, and accepts push contributions from
intent/timer/watch work. `BundledPluginViewRoutingTests` covers that seam directly.

Nothing here changes a plugin's classification. A `bundled-swift` manifest still owns a
plugin generation: views and status stay CONTRIBUTIONs, select/submit stay owner-scoped
EVENT facts, host effects stay declared INTENTs, and only the sealed bundled inventory may
select compiled code. The runtime work below extends `BundledPluginProgram` — the
package-internal program shape — not the public boundary.

## What the compiled runtime serves today

- `activate` / `receiveEvent` → one `BundledPluginContribution`; static view registrations and
  per-instance bodies are separate, then materialized into the host snapshot;
- `invokeIntent` with `IntentProviderContext` for causal nested sends;
- statically declared `subscribedEvents`, delivered through a bounded 256-entry mailbox;
- view select/submit/open/close callbacks share that mailbox and return replacement contributions;
- `BundledPluginContext.publishContribution` pushes a contribution back through the same pump;
- generation-owned timers and filesystem watches are bounded, permission-gated, and cancelled
  on generation retirement or instance close;
- two separately named event directions: `PluginHostRuntime.deliverEvent` carries a
  host-addressed fact into the generation, and `BundledPluginContext.emit` publishes one of
  the plugin's own manifest-declared channels back out;
- live manifest settings and plugin-private storage on `BundledPluginContext`
  (`setting`, `storageValue`, `setStorageValue`), refreshed by a delivered `settings.changed`
  and by a host-confirmed write; attributed logging.

## Runtime gaps, in dependency order

| # | Gap | Blocks | Shape of the work |
|---|---|---|---|
| 1 | **View event routing and instance state.** **Delivered 2026-08-14 (T-167 S3).** Registration, per-instance bodies, callback routing, open-instance snapshots, close pruning, and ordered callback delivery are covered by `BundledPluginViewRoutingTests`. | all five | No new `tenon` surface; callbacks remain owner-scoped EVENT facts. |
| 2 | **Compiled-program resources.** **Delivered in the current seam.** `timers.after/every/cancel` and `fs.watch` are bounded, generation-owned, instance-owned when requested, permission-gated, and retired with the owner. | git, kanban | Remaining port work is plugin-specific behavior and parser tests, not runtime plumbing. |
| 3 | **Storage read semantics on the compiled context.** Shipped 2026-08-14 (T-167 S2): `BundledPluginContext.storageValue` answers with the last host-confirmed write, so a refused write leaves the previous value readable. | claude-sessions | Delivered — `BundledPluginLocalStateTests.testStorageReadsTheCommittedValueAndARefusedWriteKeepsThePrevious`. |
| 4 | **Exact path semantics and structured actions.** `PluginPath` now matches the bootstrap's POSIX string rules, and `PluginNodeAction` carries string or structured values directly in both backends. | file-explorer, all views | Remaining work is to use the shared path seam in the file-explorer port. |
| 5 | **Bounded activation and fail-soft inventory.** Startup must obey `startupTimeout`; one untrusted/unregistered bundled program must fail its own record without aborting unrelated plugins. | all ports | Add red-first lifecycle/load tests before flipping manifests. |

Deliberately **not** on the list: dynamic palette providers (`palette.registerProvider` is
available but no shipped plugin uses it).

## Port status

The line counts below are the pre-port JavaScript source measurements from 2026-08-14. They
remain useful as migration evidence; the shipped implementations now live in
`Sources/TenonBundledPlugins`.

| Plugin | Pre-port JS lines | Status | Beyond the view: what the compiled port carries |
|---|---:|---|---|
| `clock` | — | ported | Status-bar clock contribution. |
| `core-commands` | — | ported | Core command providers and workspace actions. |
| `workspace-status` | — | ported | Workspace status-bar contribution. |
| `browser` | 137 | ported | 1 provided intent, 5 used intents, observes `web.did-navigate`, 2 settings. No timers, watch, or storage. |
| `hello-palette` | — | ported | Compiled palette provider; the JavaScript parity fixture lives under `Tests/Fixtures`. |
| `view-gallery` | — | ported | Static and instanced view-gallery contributions. |
| `file-explorer` | 494 | ported | 5 provided intents, 14 used intents, observes `settings.changed` / `workspace.changed` / `pane.cwd-changed` / `workspace.slot-focused` / `workspace.slot-closed`. Path helpers use the shared Swift seam. |
| `claude-sessions` | 1,009 | ported | 2 provided intents, favourites in plugin storage, observes `settings.changed` / `workspace.changed`, and keeps scan logic as ordinary Swift. |
| `git` | 843 | ported | 400 ms debounce, 15 s poll, recursive repository watch, status-bar text, 6 provided intents, and six observed channels. |
| `kanban` | 1,021 | ported | Debounce and tracking timers, recursive watch, `board.changed`, and staged board writes through the existing host resource. |

**Completed port order:** browser → file-explorer → claude-sessions → git → kanban, with the
small providers ported alongside the runtime seam. All compiled implementations follow the
same manifest-backed boundaries; third-party JavaScript remains supported and hot-reloadable.

## Rules every port keeps (enforced, not remembered)

- The manifest keeps its exact `id`, permissions, `intents.uses/provides`, events, and
  settings; only `runtime: bundled-swift` is added and `main.js` is deleted **in the same
  change** — `BundledPluginMigrationGuardTests` reddens on a shadowing entrypoint.
- View callback behavior is covered by `BundledPluginViewRoutingTests`; the migration guard no
  longer asserts that compiled plugins publish no views. A port must still add its own handler,
  instance, contribution, and negative lifecycle coverage before its manifest flips.
- `ShippedPluginsTests` continues to stage every declared handler for both backends; a
  compiled port missing a program or a handler fails there by exact id.
