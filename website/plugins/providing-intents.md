# Providing intents

A contract your plugin serves is declared **statically**, in the manifest, so
the host can validate, authorize and project it before your JavaScript runs.

That ordering is why a palette row for your intent can exist before your code
has executed, and why a malformed contract is refused at load rather than
discovered at call time.

## Declare the contract

```json
{
  "intents": {
    "uses": ["ui.toast.v1"],
    "provides": [
      {
        "name": "dev.example.my-plugin.greet.v1",
        "title": "Say Hello",
        "description": "Shows a greeting.",
        "audiences": ["plugin", "user"],
        "effects": {
          "kind": "write",
          "idempotency": "none",
          "confirmation": "never",
          "external": false
        },
        "inputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "properties": { "name": { "type": "string" } },
          "required": ["name"],
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "palette": {
          "category": "Example",
          "icon": "hand.wave",
          "keywords": ["hello", "greet"]
        }
      }
    ]
  }
}
```

### Naming

Prefix with your plugin id and version from the first release:
`dev.example.my-plugin.greet.v1`. A contract is a promise, and a versioned name
is how you keep it while changing your mind later.

### `effects`

State what it does before it does it. These are read by policy, not just by
humans.

| Field | Values |
|---|---|
| `kind` | `read`, `write`, `destructive` |
| `idempotency` | whether repeating it is safe |
| `confirmation` | `never`, `policy`, `always` |
| `external` | whether it leaves the machine |

Be honest here. Declaring `read` for something that writes is not a shortcut
past a confirmation prompt — it is a lie the whole policy layer then acts on.

### `inputSchema` / `outputSchema`

Real JSON Schema, validated on both sides. `additionalProperties: false` is the
right default: it turns a caller's typo into an error instead of a silently
ignored field.

### `audiences`

Who may call it. `user` is what makes it invocable from the palette.

## Bind the handler

Exactly once, during initial evaluation:

```js
async function greet(name, call = tenon.intents) {
  const result = await call.send("ui.toast.v1", {
    message: `Hello, ${name}`,
    kind: "success",
  })
  if (!result.ok) throw new Error(result.error.code)
  return {}
}

tenon.intents.handle("dev.example.my-plugin.greet.v1", (input, call) => {
  call.throwIfCancelled()
  return greet(input.name, call)
})
```

Binding twice, or binding a name not in `provides`, fails staging — which leaves
the last good generation running and looks like your edit did nothing. See
[Hot reload](/plugins/hot-reload).

## `call` is not optional plumbing

The handler receives a `call` scoped to *this* invocation. Pass it into every
function that sends.

```js
tenon.intents.handle(NAME, (input, call) => {
  call.throwIfCancelled()      // cheap, and the caller may already be gone
  return doWork(input, call)   // not tenon.intents
})
```

Using `tenon.intents` inside a handler instead silently detaches the work from
its invocation: it loses that pane's targeting, escapes the parent deadline,
drops out of cycle accounting, and keeps running after the caller cancels.

`throwIfCancelled()` early, and again around long stretches, keeps a cancelled
command from doing work nobody is waiting for.

## Return a value, or throw

Return an object matching your `outputSchema`. Throwing settles the intent as a
failure — which is the right thing when the failure is real:

```js
if (!result.ok) throw new Error(result.error.code)
```

## Palette projection

`palette` is presentation metadata **on the contract**, not a separate command
registration. The palette row and a programmatic send invoke the same contract
through the same checks.

- `palette.launcher: true` exposes it in ordinary launchers.
- `palette.fillsPane: true` marks an intent that can fill a pane supplied in
  invocation scope — add it only when that is actually true.

For rows that depend on what the user typed, register a provider instead:
[Palette contributions](/plugins/palette).

## Do not self-send

```js
// Wrong: an intent as this plugin's module system.
await tenon.intents.send("dev.example.my-plugin.reindex.v1", {})
```

Keep the implementation in an ordinary function and bind an intent handler only
when **another principal** must invoke it. Intents are your external contracts.
