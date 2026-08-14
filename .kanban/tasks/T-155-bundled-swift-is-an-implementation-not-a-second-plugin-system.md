# T-155: Bundled Swift is an implementation, not a second plugin system

> Add a compiled Swift backend behind the existing manifest/runtime seam, then port several
> shipped plugins without changing their identity, authority, or lifecycle.

- **priority**: high
- **effort**: M
- **PRDs**: `TENON-PRD-010` (plugin runtime), `TENON-PRD-011` (interaction boundaries)
- **DONE 2026-08-14. Operator-directed and left uncommitted in the shared tree.**

## Decision

`PluginID` remains the management and semantic-owner boundary. `runtime: bundled-swift`
selects an exact program linked into this Tenon build only for bundled-trust inventory. It
does not create a native extension SDK, grant typed host services, or turn the plugin into a
built-in pane. Calls inside one compiled plugin are local Swift; host effects remain intents,
facts remain events, and UI/status remains contribution state.

## Criteria

- [x] `TenonBundledPlugins` is a build target used by SwiftPM and Xcode app/test graphs.
- [x] Existing manifests default to JavaScript and still require `main.js`.
- [x] A bundled-Swift manifest needs no JavaScript entrypoint, resolves by exact `PluginID`,
      and is refused outside bundled-trust inventory.
- [x] Native event delivery is bounded and does not block publishers; shutdown returns by its
      deadline and reports a stalled callback pump.
- [x] Provider bindings match the manifest exactly and use `IntentProviderContext` for causal
      nested calls.
- [x] `core-commands`, `clock`, and `workspace-status` are compiled Swift; their three JS
      entrypoints are deleted while manifests and plugin management remain.
- [x] Host enable/disable coverage proves contribution withdrawal/restoration for a compiled
      plugin; shipped-plugin coverage exercises both backends.
- [x] `xcodegen generate`, focused tests, full relevant suite, and final diff/health review pass.

Verification: focused architecture/runtime sweep **55/0**, full suite **2240/0**, Xcode app
build succeeded, project generation was deterministic, and final diff/health review found no
new blocker.

## Explicit follow-up boundary

This slice covers intent providers, event observers, and status contributions. Compiled plugin
view callbacks, dynamic palette providers, and view-owned timer/watch/process resources are a
follow-up before Kanban, Git, File Explorer, or Claude Sessions can move safely. They extend
the same runtime protocol; they do not authorize direct host service access.
