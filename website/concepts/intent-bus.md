# The intent bus

Every finite request that crosses from one owner to another — plugin to host,
CLI to host, agent to host — arrives as an **intent**: a named, versioned
contract with a JSON Schema for its input and output, declared effects, and an
explicit audience.

There are 51 canonical ones. [All of them are listed](/reference/intents/), and
that list is generated rather than written.

## Naming an intent grants nothing

This is the sentence to keep. Authorization is a sequence of separate,
fail-closed checks, and the name is only how you say which one you want:

| Check | Question it answers |
|---|---|
| Manifest declaration | did this plugin declare it in `intents.uses` / `provides`? |
| Audience | may this *kind* of caller — plugin, cli, agent — call it at all? |
| Capability | does the manifest hold the permission the contract requires? |
| Scope | is this workspace / tab / pane one this caller may target? |
| Consent | has a policy-confirmed operation actually been confirmed? |
| Provider eligibility | is there a registered provider allowed to serve it? |
| Admission | does it fit the queue, payload and concurrency bounds? |

Each is separate and each fails closed. There is no path where passing one
implies another.

## Discovery fails closed too

A caller that may not use a contract does not get to learn it exists.

```sh
$ tenon-cli intent describe ui.toast.v1
{"code":"intent_not_found","message":"intent 'ui.toast.v1' is not callable by the CLI principal"}

$ tenon-cli intent describe totally.made.up.v1
{"code":"intent_not_found","message":"intent 'totally.made.up.v1' is not callable by the CLI principal"}
```

Those are the same answer, and that is the design. `intent list` returns the
policy-filtered projection for *that* principal, not the catalog.

It has a real consequence for this site: the intent reference is generated from
two sources, because a CLI-driven generator genuinely cannot see the
plugin-only contracts. Rather than hiding that, the generated pages
[say which ones and why](/reference/intents/).

## Audiences are exact

A core contract's audience is either `{plugin, cli, agent}` or `{plugin}`.
There is no "everyone" and no generic app principal for built-in UI.

The second point matters: **Tenon's own UI does not impersonate a plugin.**
Built-in Swift calls typed application services directly, because it shares one
semantic owner with them. Public intent providers adapt to those same services.
One semantic operation, one implementation, two ways in — never two competing
implementations.

## Effects are declared, not inferred

Every contract states what it does before it does it:

- **kind** — `read`, `write`, `destructive`
- **confirmation** — `never`, `policy`, `always`
- **idempotency** — whether repeating it is safe
- **external** — whether it leaves the machine

`confirmation: policy` means a live interactive confirmation may be required.
CLI and agent callers get **no standing consent**, so an unattended
policy-confirmed operation **expires** rather than silently escalating. A
deadline exceeded there is the system working correctly, not a bug to route
around by raising the timeout.

## Everything is bounded

Queues, payloads, lifetimes and generations all have limits. A deadline covers
the whole thing — admission, confirmation, provider execution, settlement — and
a request settles exactly once.

A slow provider may delay its own response. It may not block the socket accept
loop, the built-in UI, or an unrelated provider: the accept and read loop runs
on its own thread, framing and bounded JSON decode happen off the main actor,
and UI effects hop to the main actor only for the minimal native operation.

A wait that takes 30 seconds does not make it a stream. `terminal.wait.v1`
observes asynchronously, settles once, and hands back no handle. When it times
out it settles **normally** with `met: false` — "it did not finish in time" and
"something went wrong" are different facts and are reported differently.

## When an intent is the wrong answer

Intents are for **finite cross-owner requests with one reply**. Reaching for one
elsewhere is the most common design mistake in a plugin:

| Need | Use |
|---|---|
| finite request, one reply, another owner | INTENT |
| an immutable fact, no reply | EVENT |
| many values, or a lifetime you own | RESOURCE |
| state the host renders or indexes | CONTRIBUTION |
| your own settings, storage, logs | SCOPED FACILITY |
| code inside your own plugin | just call the function |

Do **not** self-send an intent to structure one plugin's code. Intents are a
plugin's external contracts, not its module system.
[Choosing a mechanism](/plugins/choosing-a-mechanism) is the full decision
order.

## The scoped-facility allowlist is closed

Exactly three finite plugin→host operations skip the intent path:
`tenon.settings`, `tenon.storage`, and `tenon.log`. `tenon.path.*` is pure local
string code and touches no filesystem.

Everything else defaults to INTENT. The list is closed, not a starting point —
a new capability means a new contract, not a new shortcut.
