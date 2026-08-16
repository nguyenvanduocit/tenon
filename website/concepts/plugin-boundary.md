# The plugin boundary

A JavaScript plugin is a directory with a stable reverse-DNS `id`, a
`manifest.json`, and a `main.js`. It runs in its own isolated JavaScriptCore
context and sees exactly one thing from the host. Bundled Swift implementations
keep the same manifest and public boundary but run as compiled app code.

## Plugins see only `tenon`

Inside a plugin's global scope there is `tenon`, the ECMAScript builtins, and
the host's own call hooks. Nothing else.

`require` was never there. Neither was `setTimeout`, nor `fetch`. And the
bootstrap **deletes `console`** — a plugin logging through it would reach the
system log unattributed, going around `tenon.log`'s per-plugin attribution.

Two tests pin this: one on the members of `tenon`, one on
`Object.getOwnPropertyNames(globalThis)`. The second is the interesting one,
because it means a new global appearing from a future JavaScriptCore — or from
the host's own bootstrap — turns the suite red rather than silently widening the
boundary.

**A new capability is a new member on `tenon`, never a new global.**

## Native types never cross

Terminal, WebKit, AppKit and Foundation I/O state crosses the boundary only as
bounded values, targeted events, contributions, resource handles, or intent
results. A plugin never holds a native host object.

That is what makes generation retirement safe: there is no reference for a
retired context to keep alive.

## Bundled and third-party plugins get the same surface

Every plugin runtime receives the identical public surface and the identical
plugin principal rules. A bundled plugin has no private door, no extra API, and
no exemption from declaring its intents.

What bundled plugins *do* get is **standing consent** — they arrive enabled,
with consent already granted, because they shipped inside the signed app.
User-inventory plugins arrive disabled with no standing consent. That is a
difference in trust, not in surface area.

`runtime: bundled-swift` is reserved for implementations compiled into Tenon's
own sealed inventory. It is not a native plugin SDK; a user manifest naming it
is refused before activation.

## Generations, and why a broken plugin is survivable

Editing a plugin does not mutate a running one. The host **stages a replacement
generation**, activates it atomically, then drains the retired one — cancelling
its calls, resources, contributions and subscriptions.

If staging fails — a syntax error, a bad manifest, a schema that will not
validate, a handler bound twice — **the last good generation stays active**.

So a broken plugin is logged, marked failed, and reloads itself when you fix it.
It does not take the host down; a test covers that behavior.

The developer-facing consequence is worth internalizing: a failed reload looks
like nothing happening, because the working version is still running. Check the
plugin error, not the symptom.

## Retirement settles everything, once

When a generation retires it settles pending calls exactly once, cancels
resources, removes contributions and subscriptions, and cannot call back into a
destroyed context.

Resources can also be tied to a **view instance** rather than the plugin. Pass
`ownedBy: instanceID` and the host retires that timer, watcher or process stream
when the instance closes — which is what happens to every pane in a workspace
you close. Before that existed, a repeating timer in a pane outlived the pane
for the life of the app.

## Isolation is not a sandbox

**JavaScriptCore isolation is not a hard process sandbox.** Enabling a plugin
runs its JavaScript inside Tenon. Intent declarations, permission checks, scopes
and consent still fail closed, but they are policy rather than a process boundary.
Read the manifest and source of anything you did not write; see [Managing plugins](/guide/managing-plugins#two-inventories-two-levels-of-trust)
for the full trust warning.

## Why plugins matter

Plugins let new harness adapters, supervision experiments, provenance and
evidence sources evolve without private host paths or duplicated domain logic.
The public contract is the only plugin contract; Tenon's built-in surfaces call
typed Swift services directly.
