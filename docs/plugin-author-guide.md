# Plugin author guide

**Status:** current implementation guide · **Reviewed:** 2026-08-06

This guide documents the shipped JavaScriptCore runtime. The exhaustive public surface and
the rule for adding interactions live in
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md). When an
example here disagrees with that normative inventory, the inventory wins.

## Start a plugin

A plugin is one directory containing `manifest.json` and `main.js`:

```text
my-plugin/
  manifest.json
  main.js
```

Use a stable reverse-DNS ID. The manifest must include the `intents` envelope even when the
plugin sends or provides no intents:

```json
{
  "id": "dev.example.my-plugin",
  "name": "my-plugin",
  "displayName": "My Plugin",
  "version": "0.1.0",
  "permissions": [],
  "intents": { "uses": [], "provides": [] }
}
```

For development, point Tenon at the parent directory:

```sh
TENON_PLUGINS_DIR=/absolute/path/to/plugins \
  /path/to/Tenon.app/Contents/MacOS/Tenon
```

A writable or user-authored inventory is not a sandbox. Newly discovered plugins there
start disabled and do not receive standing intent consent. Enabling one is an explicit
decision to execute its JavaScript in Tenon's process; intent declarations and capability
policy still gate access to host operations. For a controlled development fixture only,
`TENON_TRUST_PLUGIN_INVENTORY=1` makes the primary override behave like the bundled
inventory: new plugins auto-enable and receive bundled standing consent. The separate user
inventory never inherits that flag. Moving a plugin ID between trusted and untrusted
inventories rotates its installation identity; enablement is withdrawn on downgrade, and
settings, storage, secrets, and standing consent from the old principal are not inherited.

The host watches plugin files and stages a replacement generation before swapping it in.
A syntax or binding error leaves the last good generation active. Runtime retirement
cancels subscriptions, timers, watches, process streams, and pending intent calls.

## Choose the interaction first

Use the first matching mechanism:

| Need | Mechanism | Public spelling |
|---|---|---|
| finite host/plugin request with one reply | INTENT | `tenon.intents.send/handle` |
| immutable fact, no reply | EVENT | `tenon.events.emit/on` |
| multiple values or caller-owned lifetime | RESOURCE | timers, `process.stream`, `fs.watch` |
| state/metadata rendered or indexed by the host | CONTRIBUTION | views, status, palette |
| private settings/state/diagnostics | SCOPED FACILITY | settings, storage, log |
| code within this plugin | DIRECT | ordinary JavaScript function call |

Do not self-send an intent to structure one plugin's code. Keep the implementation in an
ordinary function and bind an intent handler only when another principal must invoke it.

## Call a canonical intent

Declare every sent intent in `manifest.intents.uses`, plus the capabilities required by
the contract:

```json
{
  "permissions": ["process.exec"],
  "intents": { "uses": ["process.exec.v1"] }
}
```

```js
const result = await tenon.intents.send("process.exec.v1", {
  command: "/usr/bin/git",
  arguments: ["status", "--short"],
  workingDirectory: "/absolute/project/path"
}, { timeoutMs: 30000 });

if (!result.ok) {
  tenon.log("git failed", result.error.code);
  return;
}
tenon.log(result.value.stdout);
```

`send` always resolves once to `{ ok: true, value }` or `{ ok: false, error }`. A target
workspace or pane belongs in `options.scope`, not in every input object:

```js
await tenon.intents.send(
  "terminal.write.v1",
  { text: "git status\r" },
  { scope: { paneID } }
);
```

`await tenon.intents.list()` returns the policy-filtered contracts visible to this plugin.
The closed core intent inventory is in
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md#canonical-core-intent-inventory).

## Provide an intent

A plugin-owned contract is declared statically so the host can validate, authorize, and
project it before JavaScript runs:

```json
{
  "intents": {
    "uses": ["ui.toast.v1"],
    "provides": [{
      "name": "dev.example.my-plugin.greet.v1",
      "title": "Say Hello",
      "description": "Shows a greeting.",
      "audiences": ["plugin", "user"],
      "effects": {
        "kind": "write",
        "idempotency": "none",
        "confirmation": "never",
        "external": false
      },
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "properties": { "name": { "type": "string" } },
        "required": ["name"],
        "additionalProperties": false
      },
      "outputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": false
      },
      "palette": {
        "category": "Example",
        "icon": "hand.wave",
        "keywords": ["hello", "greet"]
      }
    }]
  }
}
```

Bind each provision exactly once during initial evaluation:

```js
async function greet(name, call = tenon.intents) {
  const result = await call.send("ui.toast.v1", {
    message: `Hello, ${name}`,
    kind: "success"
  });
  if (!result.ok) throw new Error(result.error.code);
  return {};
}

tenon.intents.handle("dev.example.my-plugin.greet.v1", (input, call) => {
  call.throwIfCancelled();
  return greet(input.name, call);
});
```

One sender shape everywhere: a function that sends takes the sender as its **last**
parameter, defaulting to `tenon.intents`, and always calls `await call.send(name, input,
options)`. A handler passes its own `call` into every function it calls that sends.

Passing `call` keeps that invocation's workspace/pane targeting, clamps the work to the
parent deadline, joins the causal chain used for cycle and depth accounting, and cancels
it with the invoking command. Omitting the sender sends under the ambient focused
workspace/pane as a root plugin request. Either way the request runs under this plugin's
own declared authority; caller authority is never inherited.

`palette.launcher: true` exposes a provision in ordinary launchers. Add
`palette.fillsPane: true` only when the intent can fill a pane supplied in invocation
scope.

## Publish and observe events

Host event subscriptions use `tenon.events.on(name, handler)` and return an unsubscribe
function. Plugin-published channels require two independent manifest declarations:

```json
{
  "events": {
    "publishes": ["index.changed"],
    "observes": ["dev.example.other/cache.changed"]
  }
}
```

```js
tenon.events.emit("index.changed", { files: 3 });
const stop = tenon.events.on("dev.example.other/cache.changed", refresh);
```

A publisher uses only its local name; the host emits it as
`dev.example.my-plugin/index.changed`. Emit has no reply and exposes no observers. If the
publisher needs success/failure from one receiver, define an intent instead.

## Contributions and resources

Views and status are declarative snapshots:

```js
tenon.views.register("main", { title: "My Plugin", instanced: false });
tenon.views.set("main", {
  header: {
    trailing: [
      { type: "iconButton", id: "refresh", systemName: "arrow.clockwise",
        tooltip: "Refresh" }
    ]
  },
  body: { type: "text", value: "Ready" }
});
tenon.views.onSelect("main", action => handleAction(action));
tenon.statusBar.set("my-plugin: ready");
```

`header` puts a view's own state and controls in the ONE chrome header its pane already
draws — `leading` and `trailing` runs of a flat ten-item vocabulary, reaching a rows pane and
a `body` pane alike. Its clicks arrive at the same `onSelect` a row click does, and a header
`textfield` commits through `onSubmit`. Omitting the key clears the previous header.
[`design-pane-header.md`](design-pane-header.md) is the full schema.

For dynamic palette results, register a provider, observe revisioned queries, then publish
results for that exact revision with `tenon.palette.setResults`. Each result invokes an
intent this plugin provides; it is not a second command API.

Use a resource only when values or lifetime outlive the initial call:

```js
const timer = tenon.timers.every(1000, refresh);
const watch = tenon.fs.watch(root, { recursive: true }, refresh);
const process = tenon.process.stream("/usr/bin/git", ["status"], {
  cwd: root,
  onStdout(chunk) { tenon.log(chunk); },
  onExit(result) { tenon.log("exit", result.code); }
});

// Optional explicit cleanup; generation retirement also cancels all three.
tenon.timers.cancel(timer);
watch.cancel();
process.cancel();
```

Current limitation: streaming execution is backed by Foundation `Process`. Cancellation
terminates the process leader, but does not yet prove that every descendant has exited.
Do not use `process.stream` to supervise commands that daemonize or spawn persistent child
processes; use the finite `process.exec.v1` path where collected output is sufficient.

`tenon.agents.run(request, sender = tenon.intents)` is a finite JavaScript composition
helper. Declare `terminal.open.v1`, `terminal.wait.v1`, `terminal.write.v1`, and
`terminal.scrollback.read.v1` in `uses` before calling it. It follows the same sender rule
as any other function that sends: pass the invoking `call` and the whole run is scoped to
that invocation's pane, capped at that intent's deadline, and cancelled with it. A long
supervised run started from a short-deadline command should omit the sender so it keeps
its own budget.

## Scoped facilities and path helpers

`tenon.settings.get`, `tenon.storage.get/set`, and `tenon.log` are the complete scoped
facility allowlist. Storage is plugin-private non-secret JSON state; secrets use Keychain
intents. `tenon.path.join/normalize/basename/dirname/extname` are pure string helpers and
perform no filesystem I/O.

For a migration from the removed helper API, see
[`plugin-migration-v0.2.md`](plugin-migration-v0.2.md). For load failures, permissions, and
state recovery, see [`operations.md`](operations.md).
