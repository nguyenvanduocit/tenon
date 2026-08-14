---
title: network.fetch.v1
description: "Performs one bounded HTTP request to a policy-authorized host."
---

# `network.fetch.v1`

**Fetch network resource**

Performs one bounded HTTP request to a policy-authorized host.

## At a glance

| | |
|---|---|
| Callable by | `agent`, `cli`, `plugin` |
| Provided by | `dev.tenon.core` |

## Input and output

::: warning Schema not reproduced here
`network.fetch.v1` is callable from a shell, but the Tenon this page was generated against (Tenon 0.1.0 (build 1, wire v3)) did not serve it — the catalog beside this site is newer than that build. Update Tenon and re-run the generator, or ask your own build directly:

```sh
tenon-cli intent describe network.fetch.v1
```

The definition itself is in [`CoreIntentCatalog.swift`](https://github.com/nguyenvanduocit/tenon/blob/main/Sources/TenonCore/CoreIntentCatalog.swift).
:::

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("network.fetch.v1", {})
if (!result.ok) throw new Error(result.error.code)
```

From a shell:

```sh
tenon-cli intent send network.fetch.v1 --input '{}'
```

Ask your own build for this same contract with `tenon-cli intent describe network.fetch.v1`.
