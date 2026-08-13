# T-140: Nothing a closed workspace owned may outlive it
> Closing a workspace kills its foreground work today and misses three classes of survivor: a
> pane whose shell already exited, a process the plugin runtime spawned, and a web surface's
> stored session. Close the three that are closeable, and state the one that is not.

- **priority**: high
- **effort**: L
- **requirements**: `TERM-G-005`, `TERM-A-003`, `TERM-M-006` (PRD-009), `PRT-FR-042` (PRD-010)

## Owner / files (agent lock)

Session `40b0d244`, claimed 2026-08-12 15:3x.

- `Sources/TenonApp/GhosttySurface.swift` — G1, done
- `Sources/TenonCore/TerminalJobTermination.swift` — G1, done
- `Sources/TenonCore/PluginRuntime.swift`
- `Sources/TenonCore/PluginRuntimeBootstrap.swift`
- `Sources/TenonCore/PluginStreamProcess.swift` (new, `PRT-FR-042`)
- `Tests/TenonCoreTests/PluginStreamProcessTests.swift` (new)
- `Sources/TenonCore/PluginHost.swift`
- `Tests/TenonCoreTests/TerminalJobTerminationTests.swift`
- `Tests/TenonCoreTests/PluginResourceOwnershipTests.swift` (new)
- `docs/prds/terminal.prd.md`, `docs/prds/terminal.feature`
- `docs/prds/plugin-runtime.prd.md`, `docs/prds/plugin-runtime.feature`
- `docs/plugin-author-guide.md`

Released, no longer needed: `SurfacePool.swift`, `PluginWebSurfacePool.swift` (see the
correction below — G5 was not a defect).

NOT claimed, deliberately: `Sources/TenonApp/WorkspaceSidebarView.swift` is held by T-138.
The close-confirmation gate for a workspace row was deferred while that lock was held. The
lock later cleared and the independent follow-up shipped as T-142 / `WS-FR-026`.

## What survives a workspace close today

Measured by reading, not by running — the live probe is the first criterion below.

| # | Survivor | Evidence |
|---|---|---|
| G1 | A pane whose shell already exited: `terminate()` returns before it sweeps | `GhosttySurface.swift:1357` guards on `!processExited` and a live `foregroundPID` |
| G2 | A process that called `setsid()` and outlived its parent | `TerminalJobTermination.swift:118` filters by tty; a reparented daemon has none |
| G4 | Anything `tenon.process.stream` spawned | `PluginRuntime.swift:1497` — lifetime is the plugin generation, not the workspace |
| G5 | A plugin web surface's cookies and session | `PluginWebSurfacePool.swift:147-149` — only uninstall retires the data store |

### Correction: G4 and G5 are not the same kind of thing as G1 and G2

Listing them together was wrong, and it nearly bought a worse bug than the one being fixed.
G1/G2 are teardown missing an ownership relation that already exists (a tty, a pid). G4/G5
have **no such relation at any layer**: `tenon.process.stream(executable, arguments, options)`
takes no pane and no workspace (`PluginRuntimeBootstrap.swift:341`), and `WebSurfaceKey` is
`{installation, surfaceID}` (`PluginWebSurfacePool.swift:10-12`). Killing them on a workspace
close would kill work belonging to the workspaces still open.

So G5 stands as designed and leaves this task. G4 splits in two:

- The real defect, independent of workspaces: `cancelProcess` sends SIGTERM to the leader
  only (`PluginRuntime.swift:1649`), so descendants outlive every cancel, hot reload, and
  disable. `ProcessIntentProvider.swift:551-553` already does this correctly with
  `POSIX_SPAWN_SETPGROUP`; `process.stream` is the last path that does not. That is
  `PRT-FR-042`.
- The missing relation, decided by the operator 2026-08-12: plugins gain a way to say a
  resource belongs to a view instance, and the host retires it when that instance closes.

### The ownership relation, as decided

`onOpen` already hands the plugin its `instanceID`, and shipped plugins already use it to ask
which workspace owns them (`plugins/git/main.js:658-663`). The declaration is an `ownedBy`
field at the call site, on the existing single path per resource:

```js
tenon.process.stream("npm", ["run", "dev"], { onStdout: log, ownedBy: instanceID });
tenon.timers.every(1000, tick, { ownedBy: instanceID });
tenon.fs.watch(path, onChange, { ownedBy: instanceID });
```

Omitting it keeps today's meaning exactly — the resource belongs to the plugin generation —
so no shipped plugin changes behaviour. The host hook already exists:
`PluginHost.swift:1830` closes a view instance the moment its slot leaves the catalog, which
is what a workspace close produces for every pane it owned.

Withdrawn after reading the fence: the host-shares-the-tty refusal
(`signalTargets`, `:120-121`) is deliberate and pinned by
`testTheHostSharingTheTTYRefusesTheSweepEntirely`. It stops a `swift run` session from
killing the developer's own shell. It stays.

## The trap in G1

`signalTargets` requires the root pid to still be on the tty. That guard is doing double
duty: it also refuses a `/dev/ttysNNN` the kernel has since handed to somebody else. Drop it
for a dead shell and the sweep can signal an unrelated terminal.

The replacement guard is the pty itself: while the surface holds the master fd, the kernel
cannot reissue that tty. So the sweep must hold the surface alive across its own escalation
window rather than let `retainOnly` release it at once.

## Criteria

- [x] A pane whose shell exited still sweeps its tty on close (G1), and a test proves the
      tty-reuse guard was replaced, not removed —
      `TerminalJobTerminationTests` 21/0, 2026-08-12.
- [x] A plugin can declare a resource belongs to a view instance, and the host retires it when
      that instance closes, whether or not the plugin cleaned up (`PRT-FR-047`) —
      `PluginResourceOwnershipTests` 3/0, 2026-08-12.
- [x] PRD receipts written: PRD-009 close-teardown row, PRD-010 receipt table, two Gherkin
      scenarios, and the `ownedBy` section of `docs/plugin-author-guide.md`.
- [ ] A live probe records what actually survives a real workspace close: foreground command,
      `&` job, `nohup`, `setsid`, detached daemon. G1's fixture proves the rule; it does not
      prove the rule fires in the shipped app.
- [x] `tenon.process.stream` launches into its own process group, so cancel, overflow, and
      retirement reach descendants (`PRT-FR-042`) — `PluginStreamProcessTests` 4/0, full suite
      2074/0, 2026-08-12. The guide paragraph telling authors to avoid daemonizing commands is
      gone, replaced by what the runtime now guarantees and what it still cannot.
- [ ] G2's floor stated in the PRD instead of promised away: a process that leaves both its
      parent and its tty is unreachable without cgroup-class containment, which macOS does not
      offer an unprivileged app. `PRT-G-005` forbids claiming otherwise.

## Withdrawn

- **G3** — the host-shares-the-tty refusal is deliberate and pinned by
  `testTheHostSharingTheTTYRefusesTheSweepEntirely`. It stops a `swift run` session from
  killing the developer's own shell.
- **G5** — a web surface's data store is keyed by installation, not workspace. Retiring it on a
  workspace close would log the plugin out of the workspaces still open.

## Out of scope

- App-quit teardown (`TERM-M-006`) — the same machinery, a different entry point. Worth its
  own task, and arguably worse than the workspace-close gap it neighbours.
- Workspace-row close confirmation is no longer out of scope; T-142 / `WS-FR-026` shipped it
  through the shared tab/workspace close coordinator.
