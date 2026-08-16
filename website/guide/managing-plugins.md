# Managing plugins

Tenon ships with a set of bundled plugins and can load your own. This page is
about running them; [Writing a plugin](/plugins/) is about building them.

## Two inventories, two levels of trust

| Inventory | Where | New plugins arrive |
|---|---|---|
| **Bundled** | inside the app | enabled, with standing consent |
| **User** | your own plugin directory | **disabled**, with no standing consent |

A user-authored plugin is disabled before it has executed once. That is the
whole point of the split, and it is worth being precise about what enabling one
means.

::: danger Enabling a plugin grants in-process code execution
JavaScriptCore isolation is **not a hard process sandbox**. Enabling a plugin is
a decision to run its JavaScript inside Tenon's process — not merely to grant it
a list of capabilities.

What still limits it after that: its declared intents, permission checks,
workspace and pane scope, and consent. Those are real and fail closed. But read
the manifest and the source before you enable something you did not write.
:::

Disabling or removing a plugin revokes its runtime and cancels its resources —
timers, watches, process streams and pending calls all stop.

## Installation identity

A plugin's identity is tied to the inventory class it lives in, not just its ID.

Uninstalling and reinstalling gives it a fresh installation identity. So does
moving the same plugin ID between the bundled-equivalent and untrusted classes.
On a downgrade the plugin starts disabled and **cannot inherit** the former
principal's settings, storage, secrets or standing consent.

This is what stops a trusted-then-replaced plugin from silently keeping
authority it was granted under different circumstances.

## Loading your own plugins

Point Tenon at a directory:

```sh
TENON_PLUGINS_DIR=/absolute/path/to/plugins \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

Every subdirectory containing `manifest.json` and `main.js` is discovered.
They arrive **disabled**; enable them in Settings after reading them.

### The development fixture

For a controlled development loop, and only then:

```sh
TENON_PLUGINS_DIR=/absolute/path/to/plugins \
TENON_TRUST_PLUGIN_INVENTORY=1 \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

`TENON_TRUST_PLUGIN_INVENTORY=1` makes that one directory behave like the
bundled inventory: new plugins auto-enable and receive bundled standing consent.

Two details that are easy to get wrong:

- It is matched **exactly**. `TENON_TRUST_PLUGIN_INVENTORY=true` leaves the
  directory untrusted. This is deliberate — a trust flag should not be satisfied
  by an approximate value.
- It applies **only** to the `TENON_PLUGINS_DIR` override. The separate user
  plugin inventory never inherits it.

## Hot reload

Save a file and the host stages a **replacement generation**, activates it
atomically, then drains and tears down the old one — its calls, resources,
contributions and subscriptions all go with it.

A syntax, manifest, schema or binding error leaves the **last good generation
running**. This is the part to internalize while developing: a failed reload
looks like nothing happening. Check the plugin error and the attributed logs
rather than assuming your edit loaded.

## A broken plugin cannot take down Tenon

One is reported, marked failed, and reloads itself when you fix it. The
workspace keeps working, and so do the other plugins.

That is enforced by a test, not by hope — and it is why the terminal workspace
remains useful with no optional plugins installed at all.

## Where state lives

Durable state is under your Application Support directory: the workspace
catalog, plugin installation identities and enablement, plugin-private storage,
intent idempotency and consent data, and authored plugins.

Do not edit those files while Tenon is running. If the catalog is corrupt,
preserve a copy before moving it aside, and do **not** delete the whole tree —
installation IDs, enablement, private storage and consent records are
independent state that a blanket delete throws away.

## See also

- [Troubleshooting](/guide/troubleshooting) — a plugin that does not run.
- [Permissions](/reference/permissions) — what each one actually grants.
- [Quickstart](/plugins/quickstart) — write a complete working plugin.
