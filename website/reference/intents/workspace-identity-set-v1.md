---
title: workspace.identity.set.v1
description: "Changes the name, colour, or icon of the workspace identified by invocation scope."
---

# `workspace.identity.set.v1`

**Customise workspace identity**

Changes the name, colour, or icon of the workspace identified by invocation scope. Omitted fields stay unchanged. An empty name restores the folder name; `automatic` restores the derived colour; a symbol replaces any uploaded icon. Custom image data is base64 and is decoded, bounded, and normalized to a small PNG before it enters workspace state.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Provided by | `dev.tenon.core` |

## Input and output

::: warning Schema not reproduced here
`workspace.identity.set.v1` is callable from a shell, but the Tenon this page was generated against (Tenon 0.1.0 (build 1, wire v3)) did not serve it — the catalog beside this site is newer than that build. Update Tenon and re-run the generator, or ask your own build directly:

```sh
tenon-cli intent describe workspace.identity.set.v1
```

The definition itself is in [`CoreIntentCatalog.swift`](https://github.com/nguyenvanduocit/tenon/blob/main/Sources/TenonCore/CoreIntentCatalog.swift).
:::

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("workspace.identity.set.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send workspace.identity.set.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe workspace.identity.set.v1`.
