# Hot reload and generations

Save a file and your plugin reloads. The staging sequence explains what happens
when a replacement generation fails.

## Staging, not mutation

The host does **not** mutate a running plugin. It:

1. **stages** a replacement generation — a fresh isolated JavaScriptCore context;
2. evaluates your code in it and binds its handlers;
3. **activates** it atomically;
4. **drains and retires** the old generation.

Retirement settles its pending calls exactly once, cancels its timers, watches
and process streams, removes its contributions and subscriptions, and guarantees
the host cannot call back into the destroyed context.

## A failed reload changes nothing

If staging fails — a syntax error, a bad manifest, a schema that will not
validate, a handler bound twice or bound to a name not in `provides` — **the
last good generation stays active**.

::: warning This is the thing that will confuse you
Your plugin keeps working. The status bar still updates. The palette row is
still there. It looks exactly like your edit did nothing, because from the
outside, nothing happened.

**Check the plugin error and the attributed logs.** Do not assume your code
loaded because the plugin is alive — the *previous* version is alive.
:::

Try it deliberately once: delete a closing brace, save, and watch nothing change.
Then restore the brace and confirm the replacement loads.

## Bind exactly once, during initial evaluation

```js
tenon.intents.handle("dev.example.my-plugin.greet.v1", handler)
```

At the top level of `main.js`, not inside a callback and not conditionally. The
host validates bindings against `intents.provides` while staging; a second bind
of the same name fails the generation.

The same applies to `views.register` and `palette.registerProvider` — these are
registrations, not runtime operations.

## What survives a reload

| | Survives |
|---|---|
| Your module-level variables | **no** — a fresh context |
| `tenon.storage` | yes |
| Settings | yes |
| Secrets | yes |
| Timers, watches, streams | no — canceled with the generation |
| View instances (panes) | yes — the pane stays, your view re-renders |
| Contributions | re-published by the new generation |

Anything you need across a reload belongs in
[`tenon.storage`](/plugins/settings-and-storage), not in a module variable.

## A broken plugin cannot take down Tenon

It is logged, marked failed, and reloads itself when you fix it. The workspace
keeps working and so do the other plugins.

This is enforced by a test named for the behavior rather than left to hope, and
it is why the terminal workspace stays useful with no optional plugins installed
at all.

## Disabling and removing

Disabling or removing a plugin retires its runtime the same way: resources
canceled, contributions removed, subscriptions dropped.

Uninstall and reinstall gives it a **fresh installation identity** — new
storage, no inherited secrets, no standing consent. So does moving the same ID
between the bundled-equivalent and untrusted inventory classes. A downgrade
starts disabled and cannot inherit the former principal's state.

That is what stops a plugin that was trusted, then replaced, from silently
keeping authority granted under different circumstances.

## Developing against a live app

```sh
TENON_PLUGINS_DIR=~/tenon-plugins \
TENON_TRUST_PLUGIN_INVENTORY=1 \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

The trust flag auto-enables newly discovered plugins in that one directory and
seeds standing consent, so a save-reload loop does not mean re-enabling
something every time.

It is matched **exactly** — `=true` leaves the directory untrusted — and it never
applies to the separate user inventory. See
[Managing plugins](/guide/managing-plugins).
