# Choosing a mechanism

Read this once before you add your second feature. Most plugin bugs that survive
review come from choosing the wrong mechanism, not from writing the wrong code.

## The decision order

Take the **first** row that matches. Not the most convenient one — the first.

| Need | Mechanism | Public spelling |
|---|---|---|
| State or metadata the host renders or indexes | CONTRIBUTION | `views.*`, `statusBar.set`, `palette.*` |
| An immutable fact that already happened, no reply | EVENT | `events.emit`, `events.on` |
| Multiple values over time, or a lifetime you own | RESOURCE | `timers.*`, `process.stream`, `fs.watch` |
| Your own settings, private state, or diagnostics | SCOPED FACILITY | `settings.get`, `storage.get/set`, `log` |
| Code inside this plugin | DIRECT | an ordinary function call |
| A finite request to another owner, with one reply | INTENT | `intents.send`, `intents.handle` |

INTENT is last for a reason: it is the most expensive and most governed
mechanism, and it is the one people reach for first.

## The three mistakes

### Self-sending an intent to structure your own code

```js
// Wrong — an intent as a module system.
tenon.intents.handle("dev.example.notes.reindex.v1", reindex)
await tenon.intents.send("dev.example.notes.reindex.v1", {})
```

```js
// Right — it is your own code. Call it.
await reindex()
```

An intent is your plugin's **external contract**. Bind a handler only when
another principal genuinely needs to invoke it. Functions inside one generation
call each other directly.

### Using an event where you needed an answer

`emit` has no reply and exposes no observers. You cannot learn whether anyone
received it, whether it worked, or what it produced.

If you need success or failure back from one receiver, that is an INTENT. If you
are stating a fact and do not care who hears it, that is an EVENT.

### Holding an intent open instead of using a resource

An intent settles **once**. Raising `timeoutMs` to keep one alive while output
trickles in is fighting the design, and the deadline covers admission,
confirmation, execution and settlement anyway.

Multiple values over time is a RESOURCE — `process.stream` for a long command,
`fs.watch` for changes, `timers.every` for a schedule.

The one apparent exception proves the rule: `terminal.wait.v1` can take 30
seconds, and is still an intent. Elapsed time is not what makes something a
resource — the caller gets exactly one result and no handle survives
settlement. The provider's observer is an internal implementation detail owned
and canceled with the request.

## Deciding is not optional

Every finite filesystem, process, workspace, terminal, browser, UI, secrets,
network and clipboard operation reaches the host as a **declared canonical
intent**. There is no handwritten helper for any of them, and there will not be
one added for convenience.

The [scoped-facility allowlist is closed](/concepts/intent-bus#the-scoped-facility-allowlist-is-closed):
settings, plugin-private storage, and log. `tenon.path.*` is pure string code
and performs no I/O. Everything else defaults to INTENT.

## Same-owner code stays direct

Tenon's own built-in UI calls typed Swift services directly, because it shares
one semantic owner with them. It does **not** impersonate a plugin or route
through the public bus to talk to itself.

The rule that falls out of that, and applies to you: **two public paths for one
semantic operation are forbidden**. If an operation already exists as a
contract, do not add a second way to do it.

## See also

- [The intent bus](/concepts/intent-bus) — what the checks actually are.
- [Sending intents](/plugins/sending-intents)
- [Events](/plugins/events)
- [Resources and lifetime](/plugins/resources)
