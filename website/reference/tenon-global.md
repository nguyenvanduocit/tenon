# The `tenon` global

The complete public surface a plugin sees. Thirty members, and this is all of
them — a test pins this exact list, so it cannot drift underneath you.

```js
Object.getOwnPropertyNames(tenon)
// agents, apiVersion, events, fs, intents, log, palette, path,
// process, settings, statusBar, storage, timers, views
```

## Metadata

| Member | Notes |
|---|---|
| `tenon.apiVersion` | immutable runtime version |

## Intents

| Member | Notes |
|---|---|
| `tenon.intents.send(name, input, options?)` | resolves once to `{ok:true,value}` or `{ok:false,error}` |
| `tenon.intents.handle(name, handler)` | bind once, during initial evaluation |
| `tenon.intents.list()` | the policy-filtered contracts visible to this plugin |

`options` carries `{ scope: { workspaceID, tabID, paneID }, timeoutMs,
idempotencyKey }`. A handler receives `(input, call)`; `call.send(…)` keeps the
invocation's scope, deadline, causal chain and cancellation, and
`call.throwIfCancelled()` bails out early.

→ [Sending intents](/plugins/sending-intents) · [Providing intents](/plugins/providing-intents)

## Events

| Member | Notes |
|---|---|
| `tenon.events.on(name, handler)` | returns an unsubscribe function |
| `tenon.events.emit(name, payload)` | no reply; the host qualifies the channel with your id |

Both directions need a manifest declaration — `events.observes` uses the fully
qualified name, `events.publishes` uses your local one.

→ [Events](/plugins/events)

## Views

| Member | Notes |
|---|---|
| `tenon.views.register(id, spec)` | `{ title, instanced }` |
| `tenon.views.set(id, spec)` | `{ header?, body, modal? }` — a full snapshot |
| `tenon.views.onSelect(id, handler)` | `(action, value)` — buttons, header items, drops |
| `tenon.views.onSubmit(id, handler)` | a header `textfield` committing |
| `tenon.views.onOpen(id, handler)` | `(instanceID)` for an instanced view |
| `tenon.views.onClose(id, handler)` | `(instanceID)` |

→ [Views](/plugins/views)

## Palette

| Member | Notes |
|---|---|
| `tenon.palette.registerProvider(id, spec)` | CONTRIBUTION |
| `tenon.palette.setResults(id, revision, results)` | publish for that exact revision |
| `tenon.palette.onQuery(id, handler)` | owner-scoped query EVENT |

→ [Palette contributions](/plugins/palette)

## Status bar

| Member | Notes |
|---|---|
| `tenon.statusBar.set(text)` | one status contribution |

## Resources

| Member | Notes |
|---|---|
| `tenon.timers.after(ms, fn, options?)` | one-shot |
| `tenon.timers.every(ms, fn, options?)` | repeating |
| `tenon.timers.cancel(handle)` | explicit cancel |
| `tenon.process.stream(cmd, args, options)` | `{ cwd, ownedBy?, onStdout, onStderr, onExit }` |
| `tenon.fs.watch(path, options, handler)` | `{ recursive, ownedBy? }` |

`options.ownedBy` takes a view `instanceID`, so the host retires the resource
when the instance closes.

→ [Resources and lifetime](/plugins/resources)

## Scoped facilities

The allowlist is **closed**. These three, and nothing else.

| Member | Notes |
|---|---|
| `tenon.settings.get(key)` | read-only; declared in the manifest |
| `tenon.storage.get(key)` | plugin-private, non-secret JSON |
| `tenon.storage.set(key, value)` | — |
| `tenon.log(…args)` | per-plugin attributed |

→ [Settings and storage](/plugins/settings-and-storage)

## Path helpers

Pure string functions. **No filesystem I/O**, and no permission needed, because
they touch nothing.

| Member |
|---|
| `tenon.path.join(…parts)` |
| `tenon.path.normalize(p)` |
| `tenon.path.basename(p)` |
| `tenon.path.dirname(p)` |
| `tenon.path.extname(p)` |

## Agents

| Member | Notes |
|---|---|
| `tenon.agents.run(request, sender?)` | the supervised run-to-result loop |

Composition over your **own** declared `terminal.open/wait/write/scrollback.read`
intents, not a new capability. Declare all four.

→ [Starting agents](/plugins/starting-agents)

## What is not here

No filesystem read or write. No process exec. No terminal write. No clipboard.
No network. No UI prompt. No secrets. No workspace control.

Every one of those is a real capability, and every one arrives as a
[declared canonical intent](/reference/intents/) rather than a handwritten
helper. That is the rule, not an accident of what has been implemented so far:
finite cross-owner work defaults to INTENT.

## What is not in scope at all

`require`, `setTimeout` and `fetch` were never present. `console` is **deleted**
by the bootstrap — logging through it would reach the system log unattributed,
around `tenon.log`'s per-plugin attribution.

`Object.getOwnPropertyNames(globalThis)` is pinned to exactly the closed set of
`tenon`, the ECMAScript builtins, and the host's own non-configurable,
non-writable call hooks. A new global — from a future JavaScriptCore or from the
host's own bootstrap — turns the test suite red.

**A new capability is a new member on `tenon`, never a new global.**

→ [The plugin boundary](/concepts/plugin-boundary)
