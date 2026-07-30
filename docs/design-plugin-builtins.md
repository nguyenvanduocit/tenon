# Plugin runtime built-ins

**Status:** normative surface reconciliation · **Date:** 2026-07-25
**Boundary law:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Goal

The plugin runtime exposes a small, complete vocabulary whose mechanism follows the
interaction's semantics. A plugin author never has to guess whether a finite host operation
uses a handwritten helper, a callback enum, or the intent dispatcher.

The top-level namespace inventory is closed. The method-level inventory in the boundary
law is exact; matching an existing namespace does not authorize a new method.

| Surface | Mechanism |
|---|---|
| `tenon.apiVersion` | reserved immutable runtime metadata |
| `tenon.intents` | INTENT adapter + provider/discovery control plane |
| `tenon.settings` | SCOPED FACILITY |
| `tenon.storage` | SCOPED FACILITY |
| `tenon.log` | SCOPED FACILITY |
| `tenon.path` | pure DIRECT JavaScript utility |
| `tenon.events` | EVENT |
| `tenon.timers` | RESOURCE |
| `tenon.process.stream` | RESOURCE |
| `tenon.fs.watch` | RESOURCE |
| `tenon.statusBar` | CONTRIBUTION |
| `tenon.views` | CONTRIBUTION publication + EVENT callback subscription |

Finite filesystem, process execution, workspace, terminal, browser, UI, secrets, network,
clipboard, and OS operations are canonical intents.

## Async contract

Every intent invocation returns one Promise resolving to the canonical `IntentResult`.
There is no callback spelling for finite request/reply operations.

```js
const result = await tenon.intents.send(
  "process.exec.v1",
  {
    command: "/usr/bin/git",
    arguments: ["status", "--short"],
    workingDirectory: repo
  }
);

if (!result.ok) {
  tenon.log(result.error.code);
}
```

Resource callbacks remain callbacks because a resource deliberately produces more than one
fact during its lifetime. Contribution callbacks remain owner-scoped UI facts.

## INTENT

### Caller

```js
const result = await tenon.intents.send(name, input, {
  timeoutMs: 30000,
  idempotencyKey: "optional",
  target: { providerID: "optional-explicit-provider" }
});
```

Rules:

- `name` MUST appear in `manifest.intents.uses`;
- input is copied once into bounded `IntentValue`;
- errors settle the result exactly once and never disappear into a log;
- target selection cannot bypass contract audience, permission, scope, provider consent,
  or readiness;
- runtime retirement settles/cancels every outstanding call owned by that generation.

### Provider

```js
tenon.intents.handle("dev.tenon.git.refresh.v1", async (input, call) => {
  call.throwIfCancelled();
  const result = await call.send("process.exec.v1", {
    command: "/usr/bin/git",
    arguments: ["status", "--short"]
  });
  if (!result.ok) throw new Error(result.error.code);
  return { refreshed: true };
});
```

The name MUST appear in `manifest.intents.provides`. Binding is valid only during staging,
exactly once per provision. Static manifest declaration makes contracts discoverable before
plugin evaluation. A provider MUST use `call.send` for nested requests so causal scope is
preserved by default. Explicit retargeting is re-authorized under that provider/plugin
principal's own grants; caller authority is never inherited.

### Discovery

`await tenon.intents.list()` returns the policy-filtered projection for this plugin
principal. It is reserved catalog control plane, not an intent sent through itself.

## SCOPED FACILITY

The exact allowlist is:

```js
const home = tenon.settings.get("homeURL");
const state = tenon.storage.get("viewState");
tenon.storage.set("viewState", { expanded: true });
tenon.log("loaded", state);
```

Settings reads are scoped to this plugin's declared settings. Storage is this plugin's
non-secret namespace. Logs are attributed to this runtime generation.

Secrets are excluded: they use `secrets.get.v1`, `secrets.set.v1`, and
`secrets.delete.v1` because Keychain access is sensitive authority. A future fourth
facility requires an architecture-law change and fitness-test update.

## Pure DIRECT path utilities

`tenon.path` performs string transformations inside the JavaScript bootstrap:

```js
tenon.path.join(root, "Sources", "main.swift");
tenon.path.normalize(value);
tenon.path.basename(value);
tenon.path.dirname(value);
tenon.path.extname(value);
```

These functions do no I/O, cross no native bridge, read no host state, and require no
permission. Filesystem existence, listing, read, write, create, move, and trash are intents.

## EVENT

```js
const unsubscribe = tenon.events.on("workspace.slot-focused", event => {
  // react to an immutable fact
});
unsubscribe();
```

Event names state facts. Event handlers do not return a result to the publisher. Runtime
retirement removes all subscriptions. Sensitive event families remain policy-gated.

## RESOURCE / STREAM / TASK

### Timers

```js
const handle = tenon.timers.every(15000, refresh);
tenon.timers.after(300, save);
tenon.timers.cancel(handle);
```

Timers belong to one plugin generation and die with it. They are not globals and are not
intents.

### Streaming process

```js
const run = tenon.process.stream("/usr/bin/git", ["status", "--porcelain"], {
  cwd: repo,
  env: { LC_ALL: "C" },
  onStdout(chunk) { /* bounded chunk */ },
  onStderr(chunk) { /* bounded chunk */ },
  onOverflow(info) { /* explicit loss/backpressure */ },
  onExit(result) { /* one terminal fact */ }
});
run.cancel();
```

`process.stream` uses the `process.exec` capability but has resource semantics: multiple
outputs, explicit overflow, cancellation, and teardown. A collect-and-return process uses
`process.exec.v1`.

### Filesystem watch

```js
const watch = tenon.fs.watch(repo, { recursive: true }, event => refresh(event));
watch.cancel();
```

The watch uses `filesystem.read` authority. Its callback reports facts; it does not accept
commands. Watch ownership, event queue, overflow, debounce, cancellation, and generation
teardown are bounded and explicit.

## CONTRIBUTION

### Structured actions

View nodes and rows may contribute structured action values:

```js
tenon.views.set("changes", {
  body: {
    type: "button",
    label: "Discard",
    action: { operation: "discard", path: file }
  }
});

tenon.views.onSelect("changes", action => {
  if (action.operation === "discard") discard(action.path);
});
```

The host owns stable canonical encoding and native rendering. The plugin receives its own
value back as an owner-scoped UI fact.

### Views and status

```js
tenon.views.register("changes", { title: "Changes", instanced: false });
tenon.views.set("changes", specification);
tenon.views.onSelect("changes", handler);
tenon.views.onSubmit("changes", handler);
tenon.views.onOpen("changes", handler);
tenon.views.onClose("changes", handler);

tenon.statusBar.set("main");
```

These publish declarative state. They do not imperatively mutate workspace, terminal,
browser, filesystem, or OS state. Such mutations use intents.

## Canonical finite examples

```js
await tenon.intents.send("ui.toast.v1", {
  message: "Pushed to origin/main",
  kind: "success"
});

const pick = await tenon.intents.send("ui.pick.v1", {
  title: "Switch branch",
  items
});

const response = await tenon.intents.send("network.fetch.v1", {
  url: "https://api.github.com/rate_limit",
  method: "GET",
  headers: {}
});

await tenon.intents.send("file.reveal.v1", { path });
await tenon.intents.send("clipboard.write.v1", { text: path });
```

Every example name MUST be declared in `manifest.intents.uses`; required capabilities and
network host allowlists remain manifest policy.

## Historical audit (non-normative)

Earlier shipped plugins accumulated one helper per finite capability plus a runtime command
registry. They also mixed Promise and callback spellings for the same request/reply shape
and exposed an unrendered sidebar contribution with no shipped caller. That fragmentation
is the evidence for the canonical intent path and pane-hosted views. Those helpers,
registrations, and the sidebar surface are not compatibility contracts.

The resource-lifetime work also exposed a retain cycle:
`runtime → JSContext → native block → runtime`. The regression invariant remains that
retiring a runtime deallocates its context and cancels timers, watches, streams, pending
calls, and callbacks.

## Fitness functions

- the top-level `tenon` inventory matches this table exactly;
- the scoped-facility allowlist remains exactly settings, storage, and log;
- `tenon.path.*` performs no native post or I/O;
- every sent/handled intent is manifest-declared;
- no finite capability has a handwritten top-level API;
- resource queues are bounded and die with the runtime;
- contributions cannot mutate host domain state while being decoded/rendered;
- plugin runtime deallocation and hot-reload teardown tests pass;
- shipped plugins use only this public surface;
- Swift 6 build and full tests pass.

Falsification: a finite capability needing provider/policy/discovery is an intent; a call
needing multiple results or lifetime cancellation is a resource; a value the host renders
is a contribution. If a proposed API does not fit one of those statements, return to the
ordered boundary law before adding it.
