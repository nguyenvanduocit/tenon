# Writing a plugin

A plugin is one directory:

```text
my-plugin/
  manifest.json
  main.js
```

It runs in an isolated JavaScriptCore context, sees exactly one host global
called `tenon`, and reloads when you save. Bundled and third-party plugins get
the same surface — there is no private door.

## Start here

- **[Quickstart](/plugins/quickstart)** — a plugin that runs, in about ten
  minutes.
- **[The manifest](/plugins/manifest)** — everything declared before your
  JavaScript is evaluated, and why.
- **[Choosing a mechanism](/plugins/choosing-a-mechanism)** — the decision order
  that keeps you out of trouble. Read this once, early.

## The whole public surface

Thirty members, and this is all of them. A test pins this exact list, so it
cannot drift underneath you.

| Group | Members | What it is |
|---|---|---|
| metadata | `apiVersion` | immutable runtime version |
| [intents](/plugins/sending-intents) | `intents.send`, `intents.handle`, `intents.list` | finite cross-owner requests |
| [events](/plugins/events) | `events.on`, `events.emit` | immutable facts, no reply |
| [views](/plugins/views) | `views.register`, `views.set`, `views.onSelect`, `views.onSubmit`, `views.onOpen`, `views.onClose` | declarative pane content |
| [palette](/plugins/palette) | `palette.registerProvider`, `palette.setResults`, `palette.onQuery` | dynamic palette results |
| status | `statusBar.set` | one status contribution |
| [timers](/plugins/resources) | `timers.after`, `timers.every`, `timers.cancel` | caller-owned schedules |
| [process](/plugins/resources) | `process.stream` | a long-running command |
| [fs](/plugins/resources) | `fs.watch` | filesystem watch |
| [settings / storage / log](/plugins/settings-and-storage) | `settings.get`, `storage.get`, `storage.set`, `log` | the closed scoped-facility allowlist |
| path | `path.join`, `path.normalize`, `path.basename`, `path.dirname`, `path.extname` | pure strings, no I/O |
| [agents](/plugins/starting-agents) | `agents.run` | supervised run-to-result over your own declared intents |

Notice what is *not* there: no filesystem read, no process exec, no terminal
write, no clipboard, no network, no UI prompt. Those are all real capabilities
and they all arrive as [canonical intents](/reference/intents/) instead of
handwritten helpers.

## What plugins cannot see

`require`, `setTimeout` and `fetch` were never in scope. `console` is deleted by
the bootstrap — logging through it would reach the system log unattributed,
around `tenon.log`'s per-plugin attribution.

A second test pins `Object.getOwnPropertyNames(globalThis)` to exactly the
closed set, so a new global from a future JavaScriptCore fails the suite instead
of quietly widening the boundary. See
[The plugin boundary](/concepts/plugin-boundary).

## One API shape everywhere

Every asynchronous call resolves once to a result envelope:

```js
const result = await tenon.intents.send(name, input, options)
if (!result.ok) {
  tenon.log("failed:", result.error.code)
  return
}
use(result.value)
```

No callbacks-or-promises duality, no throwing-or-returning duality. Load-time
errors offer suggestions rather than leaving you with a silent `undefined`.

This is deliberate and has a stated reason: **a language model should be able to
read these docs and write a working plugin on the first try.** A large share of
the people extending an agent-supervision tool are agents.

## The sender rule

One convention runs through everything, and getting it right is most of writing
a correct plugin:

> A function that sends takes the sender as its **last** parameter, defaulting
> to `tenon.intents`, and always calls `await call.send(name, input, options)`.
> A handler passes its own `call` into every function it calls that sends.

```js
async function greet(name, call = tenon.intents) {
  return await call.send("ui.toast.v1", { message: `Hello, ${name}`, kind: "success" })
}

tenon.intents.handle("dev.example.greeter.greet.v1", (input, call) => {
  call.throwIfCancelled()
  return greet(input.name, call)          // pass `call` through
})
```

Passing `call` keeps that invocation's workspace and pane targeting, clamps the
work to the parent deadline, joins the causal chain used for cycle and depth
accounting, and cancels it with the invoking command.

Omitting it sends under the ambient focused workspace and pane, as a fresh root
request with its own budget — which is what a long supervised run started from a
short-deadline command actually wants.

Either way the request runs under **your plugin's** declared authority. Caller
authority is never inherited.

## Building blocks

<div class="vp-doc">

- [Sending intents](/plugins/sending-intents)
- [Providing intents](/plugins/providing-intents)
- [Events](/plugins/events)
- [Views](/plugins/views)
- [Palette contributions](/plugins/palette)
- [Settings and storage](/plugins/settings-and-storage)
- [Resources and lifetime](/plugins/resources)
- [Automations](/plugins/automations)
- [Starting agents](/plugins/starting-agents)
- [Hot reload and generations](/plugins/hot-reload)
- [Distributing a plugin](/plugins/distributing)

</div>
