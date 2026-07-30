# T-037: Close the plugin global scope
> CLAUDE.md invariant 1 says plugins see only the `tenon` global and that `console` is
> deleted. Neither is true: `console` is live in every plugin context, nothing in
> `Sources/` deletes it, and the test the invariant named as its enforcement does not
> exist. The first and most fundamental sandbox boundary is documentation only.

- **priority**: critical
- **effort**: S

## Owner / files (agent lock)
UNCLAIMED.

Expected files:
- `poc/Sources/TenonCore/PluginRuntimeBootstrap.swift` — the deletion, next to the existing
  `delete globalThis.__tenonNativePost;`
- `poc/Tests/TenonCoreTests/PluginBuiltinsTests.swift` — the scope-closure test, beside
  `testRuntimeExportsOnlyTheClassifiedPublicSurface` at `:86`
- `CLAUDE.md` — invariant 1 loses its "not yet enforced" clause once the test exists

## Why / evidence
Measured in `.kanban/reports/t020-boundary-audit.md`, Finding 1, and confirmed
independently by the PM before this task was filed.

- A fresh `JSContext` exposes `console` — modern JavaScriptCore ships a global
  ConsoleObject. `PluginRuntime.swift:200` builds the context and nothing removes it.
- `rg console poc/Sources/` returns **zero hits**. The deletion the invariant describes
  does not exist anywhere in the target. The audit traces its loss to the runtime rewrite
  in `163c8bf`/`8620bc3`.
- `testPluginsSeeOnlyTheTenonGlobal`, named in CLAUDE.md as the test that fails when
  something leaks, **does not exist**. `rg` over `poc/Tests/` returns nothing.
- The real surface test, `PluginBuiltinsTests.swift:86`
  `testRuntimeExportsOnlyTheClassifiedPublicSurface`, enumerates only the members of
  `tenon`. It never inspects `globalThis`, which is exactly why this regression survived a
  653-test suite.
- Consequence today: a plugin can call `console.log` and reach os_log **unattributed**,
  bypassing the per-plugin attribution `tenon.log` exists to provide — the side channel a
  closed surface is meant to prevent. And any global a future macOS adds to JSC arrives in
  plugin scope silently, because nothing closes the scope.

## Open decision — do not skip it
`PluginRuntimeBootstrap.swift:438-745` installs roughly 20 `__tenon*` host hooks on
`globalThis`. They are `configurable: false, writable: false`, so a plugin cannot replace
them, and the blast radius of calling one is confined to that plugin's own generation —
self-harm, not a cross-principal hole. But they are plugin-visible and plugin-callable,
which contradicts the letter of invariant 1. Decide explicitly: either hide them behind a
closure-captured table so the invariant is literally true, or keep them and write down why
they are exempt. Do not leave the question implicit.

## Criteria
- [ ] `console` is deleted in every plugin context; `typeof console` evaluates to
      `"undefined"` from plugin code
- [ ] A test pins `Object.getOwnPropertyNames(globalThis)` against the exact expected set —
      ECMAScript builtins plus `tenon` — so that the NEXT global to appear fails the suite
      rather than arriving unnoticed
- [ ] That test is proven load-bearing: remove the deletion, watch it go red, restore
- [ ] The `__tenon*` hook decision is made and recorded in this file with its reasoning
- [ ] CLAUDE.md invariant 1 states the rule and names the test that now enforces it, with
      no "not yet enforced" clause left behind
- [ ] `swift build` exit 0 and the full suite green at or above the current baseline
