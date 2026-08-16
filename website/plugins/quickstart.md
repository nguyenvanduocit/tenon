# Quickstart

A complete working plugin, from nothing. It puts a row in the command palette,
runs a real command, and shows the result.

## 1. Make the directory

```sh
mkdir -p ~/tenon-plugins/git-status
cd ~/tenon-plugins/git-status
```

## 2. Write the manifest

Everything the host must know before it evaluates a single line of your
JavaScript goes here — that is what makes it possible to validate, authorize and
project your plugin before it runs.

```json
{
  "id": "dev.example.git-status",
  "name": "git-status",
  "displayName": "Git Status",
  "version": "0.1.0",
  "permissions": ["process.exec"],
  "intents": {
    "uses": ["process.exec.v1", "workspace.state.v1"],
    "provides": [
      {
        "name": "dev.example.git-status.show.v1",
        "title": "Show Git Status",
        "description": "Runs git status and reports what it found.",
        "audiences": ["plugin", "user"],
        "effects": {
          "kind": "read",
          "idempotency": "none",
          "confirmation": "never",
          "external": false
        },
        "inputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "palette": {
          "category": "Git",
          "icon": "arrow.triangle.branch",
          "keywords": ["git", "status", "changes"]
        }
      }
    ]
  }
}
```

Three things worth noticing before moving on:

- **`intents.uses` is mandatory even when empty.** Sending an intent you did not
  declare fails — declaration is not documentation, it is the grant.
- **`permissions` and `uses` are both required.** `process.exec.v1` is the
  contract you call; `process.exec` is the capability that lets you.
- **The `intents` envelope must be present** even for a plugin that neither
  sends nor provides anything.

## 3. Write `main.js`

```js
// git-status — run one command and say what it found.

const VIEW = "main"

tenon.views.register(VIEW, { title: "Git Status", instanced: false })

// Which directory are we in? Ask the host — there is no ambient "current
// workspace" variable, because a plugin can be looking at any of them.
//
// `workspace.state.v1` pages, so walk every page: the node you want can be past
// the first one, and stopping early returns the WRONG workspace rather than an
// error. Sixteen pages of 256 reach 4,096 nodes, past any real tree.
async function workspacePath(call = tenon.intents) {
  let cursor = null
  for (let page = 0; page < 16; page++) {
    const input = cursor ? { limit: 256, cursor } : { limit: 256 }
    const result = await call.send("workspace.state.v1", input)
    if (!result.ok) return ""

    for (const node of result.value.nodes ?? []) {
      if (node.kind === "workspace" && node.id === result.value.activeWorkspaceID) {
        return node.path ?? ""
      }
    }

    cursor = result.value.nextCursor
    if (!cursor) break
  }
  return ""
}

async function readStatus(call = tenon.intents) {
  const cwd = await workspacePath(call)
  if (!cwd) return { lines: [], error: "no-workspace" }

  const result = await call.send(
    "process.exec.v1",
    {
      command: "/usr/bin/git",
      arguments: ["status", "--short"],
      workingDirectory: cwd,
    },
    { timeoutMs: 30000 },
  )

  if (!result.ok) {
    tenon.log("git failed:", result.error.code)
    return { lines: [], error: result.error.code }
  }

  // standardOutput is { kind: "inline", text, byteCount } — not a bare string.
  const lines = result.value.standardOutput.text.split("\n").filter(Boolean)
  return { lines }
}

function render(state) {
  tenon.views.set(VIEW, {
    header: {
      trailing: [
        {
          type: "iconButton",
          id: "refresh",
          systemName: "arrow.clockwise",
          tooltip: "Refresh",
        },
      ],
    },
    body: {
      type: "vstack",
      spacing: 6,
      children: state.error
        ? [{ type: "text", value: `git failed: ${state.error}`, color: "red" }]
        : state.lines.length === 0
          ? [{ type: "text", value: "Clean.", color: "muted" }]
          : state.lines.map((line) => ({ type: "text", value: line, style: "code" })),
    },
  })
  tenon.statusBar.set(`git: ${state.lines.length} changed`)
}

async function refresh(call) {
  render(await readStatus(call))
}

// onSelect receives the action string — a header item's `id`, a button's
// `action` — plus a value slot used by fields and drops.
tenon.views.onSelect(VIEW, (action) => {
  if (action === "refresh") refresh()
})

tenon.intents.handle("dev.example.git-status.show.v1", async (input, call) => {
  call.throwIfCancelled()
  await refresh(call)
  return {}
})

refresh()
```

The shape to copy: `readStatus` takes `call` as its last parameter with a
default, the handler passes its own `call` in, and nothing throws across the
boundary except through the result envelope.

::: warning Paged results are a real trap
`workspace.state.v1` is bounded and paged — every list-shaped contract here is,
because [nothing is unbounded](/concepts/intent-bus#everything-is-bounded).
Reading only the first page does not fail; it returns a *plausible wrong
answer*. The bundled `git` plugin shipped exactly that bug: `selected` is a flag
on one node among all of them, so a workspace past node 128 made it report the
other repo. Walk the cursor.
:::

## 4. Load it

```sh
TENON_PLUGINS_DIR=~/tenon-plugins \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```

Your plugin arrives **disabled**, because a user inventory is untrusted. Open
Settings and enable it.

::: tip A faster development loop
`TENON_TRUST_PLUGIN_INVENTORY=1` makes that one directory behave like the
bundled inventory — new plugins auto-enable with standing consent. It is matched
exactly, so `=true` leaves it untrusted, and it never applies to the separate
user inventory.

```sh
TENON_PLUGINS_DIR=~/tenon-plugins \
TENON_TRUST_PLUGIN_INVENTORY=1 \
  /Applications/Tenon.app/Contents/MacOS/Tenon
```
:::

## 5. Run it

Press `⌘K` and type "git status". Your palette row is there because the host
projected the provision's `palette` metadata — you did not register a command
anywhere.

Add the view as a pane and the refresh button works.

## 6. Edit and save

Change the status bar text and save. The host stages a replacement generation,
activates it, and drains the old one.

Now break it on purpose — delete a closing brace and save.

**Nothing happens.** The old generation is still running, because a staged
generation that fails to load never replaces the working one. Check the plugin
error and the attributed log output to see why the reload failed.

## What to read next

- [Choosing a mechanism](/plugins/choosing-a-mechanism) — before you add the
  second feature.
- [The manifest](/plugins/manifest) — every field.
- [Views](/plugins/views) — the full view vocabulary.
- [All intents](/reference/intents/) — what you can call.
