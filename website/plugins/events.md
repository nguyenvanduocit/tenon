# Events

An event is an **immutable fact that already happened**. It has no reply, and it
exposes no observers to the publisher.

If you need to know whether it worked, you needed an
[intent](/plugins/sending-intents).

## Observing host events

```js
const stop = tenon.events.on("terminal.title-changed", (event) => {
  tenon.log("terminal title →", event.title)
})

stop()   // unsubscribe; retirement also does this for you
```

`on` returns an unsubscribe function. Some topics require a permission —
`terminal.*` needs `terminal.read` — so declare it in the manifest.

## Publishing your own

Two independent manifest declarations, one for each direction:

```json
{
  "events": {
    "publishes": ["index.changed"],
    "observes": ["dev.example.other/cache.changed"]
  }
}
```

```js
tenon.events.emit("index.changed", { files: 3 })

const stop = tenon.events.on("dev.example.other/cache.changed", refresh)
```

## The host owns qualification

A publisher uses only its **local** name. The host emits it as
`dev.example.my-plugin/index.changed`.

This is not a naming convenience — it is why **a plugin can only publish under
its own id**. You cannot spell another plugin's channel into `emit` and have
observers believe it. Forging a fact is structurally impossible rather than
merely discouraged.

An observer declares the **fully qualified** channel, because it is choosing
whom to trust.

## Emit has no reply

`emit` returns nothing useful and tells you nothing about who received it. That
is the contract, not a limitation to work around.

```js
// Wrong — waiting for an answer that will never come.
tenon.events.emit("please.reindex", {})
await somehowWaitForIt()
```

If the publisher needs success or failure from **one** receiver, define an
intent. If you are stating that something happened and do not care who hears,
that is exactly what events are for.

## Automation schedules arrive as events

A manifest schedule fires back as the owner-scoped `automation.fired` event:

```json
{ "automation": { "schedules": [{ "id": "tick", "every": "1m" }] } }
```

```js
tenon.events.on("automation.fired", (event) => {
  if (event.id === "tick") refresh()
})
```

See [Automations](/plugins/automations).

## Lifetime

Subscriptions belong to the generation. When it retires — a reload, a disable, a
removal — they are cancelled with it, and the host cannot call back into a
destroyed context.

You may still unsubscribe by hand for logic reasons. You do not have to for
cleanup reasons.
