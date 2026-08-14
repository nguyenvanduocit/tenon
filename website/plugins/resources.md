# Resources and lifetime

Use a resource when values or lifetime **outlive the initial call**. An
[intent](/plugins/sending-intents) settles once; a resource keeps going until
something cancels it.

```js
const timer = tenon.timers.every(1000, refresh)
const watch = tenon.fs.watch(root, { recursive: true }, refresh)
const proc = tenon.process.stream("/usr/bin/git", ["status"], {
  cwd: root,
  onStdout(chunk) { tenon.log(chunk) },
  onExit(result) { tenon.log("exit", result.code) },
})

// Optional. Generation retirement cancels all three anyway.
tenon.timers.cancel(timer)
watch.cancel()
proc.cancel()
```

`tenon.timers.after` is the one-shot form.

## `ownedBy` — the one that prevents a real bug

A resource created for a **view instance** should say so. Pass the `instanceID`
the instance handler was given, and the host retires that resource when the
instance closes:

```js
tenon.views.onOpen(VIEW, function (instanceID) {
  tenon.timers.every(1000, refresh, { ownedBy: instanceID })
  tenon.fs.watch(root, { recursive: true, ownedBy: instanceID }, refresh)
  tenon.process.stream("npm", ["run", "dev"], {
    cwd: root,
    ownedBy: instanceID,
    onStdout(chunk) { tenon.log(chunk) },
  })
})
```

Closing a pane is one way an instance ends. **Closing a workspace is another** —
and it closes every pane in it at once.

The host retires `ownedBy` resources *after* your own `onClose` has run, so
cancelling by hand still happens first and this finds nothing left. What it
covers is the pane you did not write an `onClose` for. Before it existed, a
repeating timer in a closed pane kept firing for the life of the app.

### When to omit it

Omit `ownedBy` for anything that genuinely belongs to the **plugin** rather than
to one pane: a status-bar clock, a watcher feeding the palette. Those keep the
lifetime they always had, which ends at generation retirement.

The question to ask is simply *whose* thing is this — the pane's, or the
plugin's.

## Streamed processes lead their own process group

A command started with `process.stream` leads its own POSIX process group.
Cancelling it — or overflowing it, or retiring the generation — ends **the whole
job, including children it forked after launch**.

That is what makes `npm run dev` safe to start from a pane: killing it kills the
dev server it spawned, not just the wrapper.

::: warning The honest limit
A command that deliberately leaves that group — by calling `setsid`, or
daemonizing into `launchd` — is beyond anything an unprivileged macOS app can
reach. Nothing here can clean that up.

Where collected output is enough, use `process.exec.v1` instead of a stream.
:::

## Everything is bounded

Queues, payloads, lifetimes and generations all have limits. A stream that
overflows its buffer is cancelled rather than allowed to grow without bound.

This is the same rule that makes `terminal.viewport.read.v1` a viewport snapshot
and `terminal.scrollback.read.v1` a separately bounded, cursor-paged contract —
a read must never silently become an unbounded dump.

## Retirement

When a generation retires — reload, disable, remove — the host:

1. settles pending intent calls **exactly once**;
2. cancels timers, watches and process streams;
3. removes contributions and event subscriptions;
4. guarantees it cannot call back into the destroyed context.

So explicit cleanup is a **logic** decision, not a hygiene requirement. Cancel a
timer because you no longer want it to fire, not because you are afraid of
leaking it.

## Do not fake a resource with an intent

Raising `timeoutMs` to hold an intent open while output arrives is fighting the
design. The deadline covers admission, confirmation, provider execution and
settlement, and the call settles once regardless.

Multiple values over time is a resource. See
[Choosing a mechanism](/plugins/choosing-a-mechanism).
