# Sending intents

An intent is how your plugin makes a finite request of another owner and gets
one reply. Declare it, send it, check the envelope.

## Declare it first

```json
{
  "permissions": ["process.exec"],
  "intents": { "uses": ["process.exec.v1"] }
}
```

Two separate things, both required. `process.exec.v1` is the **contract** you
call; `process.exec` is the **capability** that permits it. Declaring one
without the other fails.

## Send it

```js
const result = await tenon.intents.send(
  "process.exec.v1",
  {
    command: "/usr/bin/git",
    arguments: ["status", "--short"],
    workingDirectory: "/absolute/project/path",
  },
  { timeoutMs: 30000 },
)

if (!result.ok) {
  tenon.log("git failed", result.error.code)
  return
}
tenon.log(result.value.standardOutput.text)
```

::: tip Output is a shape, not a string
`standardOutput` and `standardError` are `{ kind: "inline", text, byteCount }`,
not bare strings — a bound that is visible in the type rather than enforced by
truncating your string behind your back. Read `.text`, and `byteCount` when you
care whether you got everything.
:::

`send` always resolves **once**, to `{ ok: true, value }` or
`{ ok: false, error }`. It does not throw for a failed intent, and there is no
second callback path. One shape, everywhere.

## Scope goes in options, not input

A target workspace, tab, or pane belongs in `options.scope` — it is not
duplicated inside every input schema:

```js
await tenon.intents.send(
  "terminal.write.v1",
  { text: "git status\r" },
  { scope: { paneID } },
)
```

**Scope designates a target; it does not grant it.** Policy still authorizes the
resolved resource for your plugin.

## The sender rule

This is the one convention to internalize.

> A function that sends takes the sender as its **last** parameter, defaulting
> to `tenon.intents`, and always calls `await call.send(name, input, options)`.
> A handler passes its own `call` into every function it calls that sends.

```js
async function refresh(root, call = tenon.intents) {
  const result = await call.send("filesystem.directory.list.v2", { path: root })
  // …
}

tenon.intents.handle("dev.example.files.refresh.v1", (input, call) => {
  call.throwIfCancelled()
  return refresh(input.root, call)      // ← pass it through
})
```

### What passing `call` buys

- the invocation's workspace and pane targeting is kept;
- the work is clamped to the **parent deadline**;
- it joins the causal chain used for cycle and depth accounting;
- it is **cancelled with the invoking command**.

### When to omit it deliberately

Omitting the sender sends under the ambient focused workspace and pane, as a
fresh root request with its own budget.

That is what you want for a long supervised run started from a short-deadline
palette command: inheriting a 5-second deadline would kill it. Omit the sender
so it keeps its own.

Either way, **the request runs under your plugin's declared authority. Caller
authority is never inherited.**

## Discovering what you may call

```js
const contracts = await tenon.intents.list()
```

This returns the **policy-filtered** contracts visible to your plugin — not the
whole catalog. It is also the only way to read the exact schema of a plugin-only
contract, which is why some pages in the
[intent reference](/reference/intents/) point you here.

## Handling failure

```js
if (!result.ok) {
  switch (result.error.code) {
    case "dev.tenon.core.user-cancelled":
      return                                   // they said no; that is an answer
    case "dev.tenon.core.terminal-unavailable":
      return fallback()
    default:
      tenon.log("unexpected", result.error.code)
  }
}
```

Each contract lists its own `domainErrors` on its reference page, on top of the
lifecycle errors any intent can settle with. See [Errors](/reference/errors).

Two failures that are the system working, not bugs to route around:

- **A policy-confirmed operation expiring.** CLI and agent callers get no
  standing consent, so an unattended one expires rather than silently
  escalating.
- **A deadline being exceeded.** It covers admission, confirmation, provider
  execution and settlement. Raising it can diagnose slow work; it is not a way
  to hold a request open. That is a [resource](/plugins/resources).

## Bounds

Payloads and queues are bounded, and every request settles exactly once. If you
are reaching for a bigger payload, the contract usually has a paged form —
`terminal.viewport.read.v1` is a viewport snapshot and
`terminal.scrollback.read.v1` is the cursor-paged history, because a viewport
read must never silently grow into an unbounded dump.

Paged contracts need the cursor walked. Reading one page does not error; it
returns a plausible wrong answer.
