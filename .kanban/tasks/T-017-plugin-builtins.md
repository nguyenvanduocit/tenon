# T-017: Plugin builtins — timers, structured actions, exec options, tenon.ui

> Every hack in the shipped plugins is a missing builtin. Add the ones that erase them:
> a real timer API, structured view-action payloads, a proper `process.exec`, and the
> host-owned prompt/pick/confirm/toast surface.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
session 0c434576 — ACTIVE

Mine (claiming):
- `poc/Sources/TenonCore/PluginRuntime.swift` — NEW blocks only: `tenon.timers`, `tenon.path`,
  `tenon.ui`; `process.exec` opts arg + `process.stream`; action payload in `parseRows`/`parseNode`
- `poc/Sources/TenonCore/PluginHost.swift` — timer ownership/teardown, `UIRequest` plumbing
- `poc/Sources/TenonCore/PluginViewNode.swift` — action payload type (String → JSON value)
- `poc/Sources/TenonApp/BuiltInSlotViews.swift` — action payload call sites
- `poc/Sources/TenonApp/TenonApp.swift` — `onUIRequest` wiring
- `poc/Sources/TenonApp/PluginUIPrompt.swift` — NEW (pick/prompt/confirm overlay)
- `poc/Tests/TenonCoreTests/PluginBuiltinsTests.swift` — NEW (all of the above)
- `poc/plugins/git/main.js`, `poc/plugins/view-gallery/main.js`
- `docs/design-plugin-builtins.md` — NEW

NOT touching (held by @3bf9127e T-015): `plugins/claude-sessions/**`, `PaneTarget.swift`,
`SurfacePool.swift`, `PaneTargetTests.swift`, `ShippedPluginsTests.swift`.
New tests go in a NEW file so `PluginCapabilityTests.swift` stays free.

## Why — the evidence, in shipped plugin code

| Hack | Missing builtin |
|---|---|
| `String.fromCharCode(31)` packed into an action id (`git/main.js:11,125,327`) | structured action payload |
| `repoGeneration` / `generation` race guards (`git/main.js:13`) | cancellable async |
| `tickCount` + `events.on("tick")` polling (`git/main.js:17`) | per-plugin timers |
| `git -C repo` everywhere (`git/main.js:57`), script smuggled through argv | `exec` `cwd` + `stdin` |
| `lastError` rendered as a view row (`git/main.js:70`) | toast / dialog |
| hand-written `shellPath()` quoting | `tenon.path.*` |

## Phases
- **0 — Promise PoC**: does JavaScriptCore drain the microtask queue when the callback is
  handed back from `DispatchQueue.main.async`? Decides the async shape of every new API.
- **1 — docs**: `docs/design-plugin-builtins.md` decision record.
- **2 — Tier 1**: `tenon.timers`, structured action payload, `process.exec(opts)` + `stream`.
- **3 — `tenon.ui.*`**: pick / prompt / confirm / toast, free tier.

## Criteria
- [x] Promise availability + microtask drain settled by a test, shape decided and recorded
- [x] `tenon.timers.after/every/cancel/debounce`; every timer dies with the runtime (reload/disable)
- [x] View actions carry an arbitrary JSON payload end to end (`views.set` → host → `onSelect`)
- [x] `process.exec(cmd, args, opts, cb)` honours `cwd`/`env`/`stdin`/`timeout`; `stream` yields lines + `cancel()`
- [x] `tenon.ui.pick/prompt/confirm/toast` reach the shell as host commands, free tier, no new permission
- [x] `tenon.path.join/dirname/basename/ext/expand` — pure, zero permission
- [x] `git` plugin rewritten onto the new builtins: no `US` separator, no tick-polling, no `-C` threading
- [x] Invariants 1/2/3/5/6 intact — `testPluginsSeeOnlyTheTenonGlobal` still green
- [x] `swift build` clean + full suite green — **364/364**

## Outcome

Shipped. `docs/design-plugin-builtins.md` is the decision record.

**Bug found and fixed en route — `PluginRuntime` never deallocated.** A nested helper inside
`installAPI` that touched `self` was captured strongly by the blocks living in the JSContext
the runtime owns: `runtime → context → block → runtime`. "Hot reload drops the runtime" held
only for the dictionary entry — every reload and every disable leaked a whole JSContext with
its plugin state. Surfaced by `testTimersDieWithTheRuntime` (a timer kept firing after its
plugin was disabled), root-caused with a bisecting probe, fixed by making the helper a
method. `testRuntimeDeallocatesWhenReleased` guards it.

**GUI unsmoked** (repo convention): the `tenon.ui` overlay — pick list, prompt, confirm,
toast — carries no unit-testable rules, so its pixels are human-verify-only. Open the
Gallery view; its new "Asking the user" card drives all four.

⚠️ One line touched outside my claim: `ShippedPluginsTests.swift:51` asserted the gallery has
exactly 3 cards, and the gallery now has 4 (the `tenon.ui` demo). Changed the constant and
the message only — @3bf9127e, rebase that one line if it collides.
