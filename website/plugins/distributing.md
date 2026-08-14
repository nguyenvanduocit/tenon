# Distributing a plugin

A plugin is a directory. Distributing one means getting that directory onto
someone's machine and into a plugin inventory.

There is no registry, no signing story, and no marketplace. That is the current
state, stated plainly rather than implied by omission.

## What you ship

```text
my-plugin/
  manifest.json
  main.js
  README.md        ← optional, and the most useful optional file you can add
```

Nothing is bundled, transpiled or minified. The host evaluates `main.js` as it
is, in a JavaScriptCore context with no module loader — `require` and `import`
are not available. One file, top-level functions.

## What a person is deciding when they install yours

Be direct about this in your README, because it is the truth:

::: danger Enabling a plugin grants in-process code execution
JavaScriptCore isolation is **not a hard process sandbox**. Enabling a plugin is
a decision to run its JavaScript inside Tenon's process — not merely to grant it
a list of capabilities.

Intent declarations, permission checks, scopes and consent still limit which
host operations it can invoke, and they fail closed. But they are policy, not a
process boundary.
:::

A user-inventory plugin therefore arrives **disabled**, with no standing
consent, and stays that way until someone reads it and decides.

## Earning that decision

Your manifest is the thing they read. Make it easy to say yes to.

- **Declare the fewest permissions that work.** Every extra one is a reason to
  hesitate. `filesystem.write` on a plugin that only reads is not a rounding
  error; it is a lie in the file they are using to judge you.
- **Keep `network.allow` tight.** An exact host beats `*.example.com`, and
  `*.example.com` beats a long list. Remember it does **not** match the apex
  domain.
- **Declare honest `effects`.** Marking a write as `read` to avoid a
  confirmation prompt is not a shortcut; the whole policy layer then acts on the
  lie.
- **Write a README that says what it does and why each permission is there.**
  One paragraph per permission is enough and it is the difference between
  "enabled" and "deleted".

## Versioning your contracts

Every intent you provide is versioned from its first release:
`dev.example.my-plugin.greet.v1`.

A contract is a promise. When you need to change the shape, add `.v2` and keep
`.v1` working until you are ready to drop it — then drop it completely rather
than leaving a shim. Callers can discover what exists with
`tenon.intents.list()`.

Your `version` field is your own; nothing in the host reads it as a
compatibility signal.

## Testing before you publish

Point Tenon at your development directory:

```sh
TENON_PLUGINS_DIR=~/tenon-plugins \
TENON_TRUST_PLUGIN_INVENTORY=1 \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

Then test the paths people actually hit:

1. **A fresh install.** Delete your `tenon.storage` state and run again — a
   plugin that only works with state it wrote last week is broken on arrival.
2. **A failed reload.** Break the file on purpose and confirm the error you get
   is one you could diagnose from the logs.
3. **A denied permission.** Remove one from the manifest and confirm you fail
   usefully instead of throwing an unhandled error into the void.
4. **A closed pane.** If you create resources for a view instance, close the
   pane and confirm they stop. See [`ownedBy`](/plugins/resources).
5. **A second workspace.** If you resolve "the current workspace", confirm you
   [walk every page](/plugins/quickstart) of `workspace.state.v1` rather than
   reading the first one.

## Contributing to Tenon itself

The bundled plugins live in
[`plugins/`](https://github.com/nguyenvanduocit/tenon/tree/main/plugins) in the
repository, and `ShippedPluginsTests` exercises the real shipped JavaScript —
including an on-disk edit that must propagate through FSEvents into host state.

If you are changing plugin-host behaviour, extend those tests rather than
relying on a manual app run.
