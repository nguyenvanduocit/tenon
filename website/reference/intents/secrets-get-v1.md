---
title: secrets.get.v1
description: "Reads one value from the caller's isolated secret namespace."
---

# `secrets.get.v1`

**Read secret**

Reads one value from the caller's isolated secret namespace.

## At a glance

| | |
|---|---|
| Callable by | `plugin` |
| Provided by | `dev.tenon.core` |

::: tip Not reachable from `tenon-cli`
`secrets.get.v1` is not in the `cli` audience, so a shell cannot send it. Naming an intent never grants authority — audience is checked before anything else.
:::

## Input and output

::: warning Schema not reproduced here
`secrets.get.v1` is served only to plugins, so the CLI discovery path this page is generated from cannot read its schema — and a hand-copied schema on a website is a schema that goes stale. Ask the runtime instead, from inside a plugin that declares it in `intents.uses`:

```js
const contracts = await tenon.intents.list()
const contract = contracts.find(c => c.name === "secrets.get.v1")
tenon.log(JSON.stringify(contract.inputSchema, null, 2))
```

The definition itself is in [`CoreIntentCatalog.swift`](https://github.com/nguyenvanduocit/tenon/blob/main/Sources/TenonCore/CoreIntentCatalog.swift).
:::

## Call it

From a plugin — declare it in `intents.uses` first:

```js
const result = await tenon.intents.send("secrets.get.v1", {})
if (!result.ok) throw new Error(result.error.code)
```
