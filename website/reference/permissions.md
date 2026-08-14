# Permissions

Ten exist. They cover only sensitive capabilities — reading terminal state,
writing into the terminal, reading and writing the filesystem, spawning
processes, driving the workspace, and the four below that each have their own
reasoning.

```json
{ "permissions": ["process.exec", "filesystem.read"] }
```

| Permission | Grants |
|---|---|
| `terminal.read` | reading terminal state, and `terminal.*` event topics |
| `terminal.write` | writing into a terminal |
| `filesystem.read` | reading the filesystem |
| `filesystem.write` | writing the filesystem |
| `process.exec` | spawning processes |
| `workspace.control` | driving the workspace |
| `web.view` | a web surface |
| `shell.open` | handing a path to the OS — reveal in Finder, or open in the owning app |
| `network` | HTTP requests — **not sufficient alone** |
| `secrets` | this plugin's own Keychain items |

An unknown permission string is reported rather than silently ignored.

## A permission is not a contract

Two separate declarations, both required:

```json
{
  "permissions": ["process.exec"],
  "intents": { "uses": ["process.exec.v1"] }
}
```

`process.exec.v1` is the **contract** you call. `process.exec` is the
**capability** that permits it. Declaring either alone fails.

They are separate because they answer different questions. The contract says
what operation you want; the permission says whether this principal may perform
that class of operation at all. Naming an intent never grants authority.

## `network` grants nothing on its own

Unlike every other permission, `network` must be paired with an explicit host
allowlist:

```json
{
  "permissions": ["network"],
  "network": { "allow": ["api.github.com", "*.example.com"] }
}
```

- An entry is an exact host or a wildcard covering subdomains.
- **`*.example.com` does not match `example.com` itself.** Add the apex
  separately if you need it.
- Matching is case-insensitive.
- An empty or missing allowlist grants access to **nothing**.

"Can reach the network" is deliberately never the same grant as "can reach
anywhere". A plugin that talks to one API should be readable as a plugin that
talks to one API.

## `shell.open` is a real escalation

The host performs it, because AppKit lives in the shell rather than in the
plugin runtime. It is still a permission, because **launching another
application is a genuine privilege** — a path handed to the OS becomes whatever
app claims that type, running with your user's authority and outside anything
Tenon can bound.

## `secrets` is separate from storage on purpose

`tenon.storage` needs no permission because it is plugin-private, non-secret
JSON in a file next to the plugins. That is the right place for a cursor or a
cache key.

It is the wrong place for a token, so secrets are a different thing entirely: a
Keychain namespace per caller, reached through `secrets.get.v1`,
`secrets.set.v1` and `secrets.delete.v1` with the `secrets` permission. They are
also plugin-only contracts — a shell cannot read them.

Secrets do not survive an installation-identity rotation.

## Declare the fewest that work

The manifest is what a person reads before deciding to run your code in Tenon's
process. Every permission you list that you do not use is a reason to hesitate,
and `filesystem.write` on a plugin that only reads is not a rounding error — it
is a false statement in the document being used to judge you.

## Permissions are not the whole check

Holding a permission is one of several separate, fail-closed checks:

manifest declaration → audience → capability → scope → consent → provider
eligibility → admission.

Each is separate and each fails closed. Passing one implies nothing about
another. See [The intent bus](/concepts/intent-bus).

## And permissions are not a sandbox

**JavaScriptCore isolation is not a hard process sandbox.** Enabling a plugin
grants in-process code execution inside Tenon, not merely the capabilities in
its manifest.

The checks above are real and they fail closed, but they are policy, not a
process boundary. A hard isolation boundary for untrusted plugin JavaScript is
open work. Until then, read the manifest **and the source** of anything you did
not write.
