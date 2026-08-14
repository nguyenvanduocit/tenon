# Automations

A schedule is a **wall-clock cadence declared in the manifest**. The host fires
it back to you as the owner-scoped `automation.fired` event.

```json
{
  "automation": {
    "schedules": [
      { "id": "tick", "every": "1m" },
      { "id": "morning", "daily": "09:00", "grace": "2h" }
    ]
  }
}
```

```js
tenon.events.on("automation.fired", async (event) => {
  if (event.scheduleId === "morning") await runAudit()
})
```

## The grammar

Validation is **fail-closed at manifest decode**, with strict unknown-field
rejection. A malformed schedule is refused before your code runs.

| Field | Rule |
|---|---|
| `id` | unique per plugin, 1…64 bytes |
| `every` \| `daily` | **exactly one** per schedule |
| `every` | `"<positive integer><s\|m\|h\|d>"`, minimum `1m`, maximum `7d` |
| `daily` | zero-padded 24-hour `"HH:mm"` |
| `grace` | optional `1m`…`7d`; defaults to one interval for `every`, `6h` for `daily` |

At most **8 schedules per plugin**.

### Sub-minute cadence is deliberately inexpressible

`every` has a floor of `1m`. If you want a tick every second, that is
`tenon.timers.every` — a [resource](/plugins/resources) you own.

A schedule is a wall-clock automation, not a tick source. Conflating them means
the scheduler has to reason about thousands of pending firings and the
distinction stops meaning anything.

### `daily` has no timezone, on purpose

`daily` resolves against the machine's calendar at computation time. There is
deliberately no stored timezone field.

The reasoning is worth repeating because it generalizes: a competing tool stores
one and then evaluates everything in host-local time anyway. **Dead metadata
that promises what the code does not do is worse than honestly documented local
time.**

## Firing semantics

The scheduler holds a `nextDue` per (plugin, schedule). A tick fires every
schedule whose `nextDue` has passed — with three rules that matter:

- **At most the latest missed occurrence.** A laptop asleep for six hours does
  not wake up and fire six times.
- **Only within `grace`.** Staler misses skip silently and the schedule re-arms
  from now. That is what `grace` is for: how late is still useful?
- **A double tick at one instant fires nothing twice.**

## The payload

```js
{
  scheduleId: "morning",
  scheduledFor: "2026-08-14T09:00:00Z",   // ISO-8601
  late: false,                            // ran >2 minutes behind its instant
  trigger: "scheduled"                    // or "manual", from Run Now
}
```

`trigger` distinguishes the tick loop from an operator pressing **Run Now** in
the Automation view. A manual firing is a user-directed action and does not
disturb the schedule's own cadence.

`late` lets you decide for yourself — a stale summary may still be worth
sending, a stale deploy is not.

## A worked example

```json
{
  "id": "dev.example.daily-audit",
  "name": "daily-audit",
  "version": "1",
  "permissions": ["process.exec"],
  "intents": { "uses": ["process.exec.v1", "ui.toast.v1"], "provides": [] },
  "automation": { "schedules": [{ "id": "morning", "daily": "09:00" }] }
}
```

```js
tenon.events.on("automation.fired", async function (e) {
  const result = await tenon.intents.send("process.exec.v1", {
    command: "/usr/bin/git",
    arguments: ["status", "--short"],
    workingDirectory: "/path/to/repo",
  })
  if (!result.ok) return

  const out = result.value.standardOutput
  const dirty = out.kind === "inline" && out.text.trim() !== ""
  if (!dirty) return                            // the condition is plain JavaScript

  await tenon.intents.send("ui.toast.v1", {
    message: "daily-audit: worktree dirty since " + e.scheduledFor,
    kind: "warning",
  })
})
```

Notice there is no rule engine, no condition DSL and no action registry. The
schedule provides the *trigger*; the condition is an `if` and the action is an
intent you already know how to send. Anything expressible in JavaScript is
expressible in an automation.

## Lifetime

Schedules belong to the plugin, not to a pane. Moving a pane does not move them,
and closing one does not stop them.

The host reports a situation summary — active schedule count, the next eligible
event, and schedules that need attention. **Delivered means only that a live
plugin generation accepted `automation.fired`**; it does not mean your handler
succeeded. If you want that recorded, record it.
