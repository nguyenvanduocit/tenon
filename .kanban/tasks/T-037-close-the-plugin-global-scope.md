# T-037: Close the plugin global scope
> CLAUDE.md invariant 1 says plugins see only the `tenon` global and that `console` is
> deleted. Neither is true: `console` is live in every plugin context, nothing in
> `Sources/` deletes it, and the test the invariant named as its enforcement does not
> exist. The first and most fundamental sandbox boundary is documentation only.

- **priority**: critical
- **effort**: S

## Owner / files (agent lock)
RELEASED 00:23 — done by Orca worker task_55a47a204dd8 (dispatch ctx_efe4d2bc7df6).
All files free.

Expected files:
- `Sources/TenonCore/PluginRuntimeBootstrap.swift` — the deletion, next to the existing
  `delete globalThis.__tenonNativePost;`
- `Tests/TenonCoreTests/PluginBuiltinsTests.swift` — the scope-closure test, beside
  `testRuntimeExportsOnlyTheClassifiedPublicSurface` at `:86`
- `CLAUDE.md` — invariant 1 loses its "not yet enforced" clause once the test exists

## Why / evidence
Measured in `.kanban/reports/t020-boundary-audit.md`, Finding 1, and confirmed
independently by the PM before this task was filed.

- A fresh `JSContext` exposes `console` — modern JavaScriptCore ships a global
  ConsoleObject. `PluginRuntime.swift:200` builds the context and nothing removes it.
- `rg console Sources/` returns **zero hits**. The deletion the invariant describes
  does not exist anywhere in the target. The audit traces its loss to the runtime rewrite
  in `163c8bf`/`8620bc3`.
- `testPluginsSeeOnlyTheTenonGlobal`, named in CLAUDE.md as the test that fails when
  something leaks, **does not exist**. `rg` over `Tests/` returns nothing.
- The real surface test, `PluginBuiltinsTests.swift:86`
  `testRuntimeExportsOnlyTheClassifiedPublicSurface`, enumerates only the members of
  `tenon`. It never inspects `globalThis`, which is exactly why this regression survived a
  653-test suite.
- Consequence today: a plugin can call `console.log` and reach os_log **unattributed**,
  bypassing the per-plugin attribution `tenon.log` exists to provide — the side channel a
  closed surface is meant to prevent. And any global a future macOS adds to JSC arrives in
  plugin scope silently, because nothing closes the scope.

## Decision — the `__tenon*` hooks stay on `globalThis`, exempt by name (2026-07-31)
The 20 `__tenon*` host hooks remain plugin-visible. Reasoning:

1. **They are the host's call channel, not a plugin capability.** The host invokes them
   by global lookup — `PluginRuntime.swift:447` `context.objectForKeyedSubscript(functionName)`
   — on every settle/emit/timer/view callback. Hiding them behind a closure-captured
   table means the host must retain per-generation `JSValue` hook references instead,
   which (a) rewrites the call path in `PluginRuntime.swift`, a file outside this task's
   scope, and (b) reintroduces exactly the `runtime → context → JSValue → runtime`
   retention shape whose leak T-017 fixed. The cost buys no security: the hooks already
   cross no principal boundary.
2. **A plugin cannot replace them** — every hook is installed
   `configurable: false, writable: false` (`PluginRuntimeBootstrap.swift:438-818`), so
   there is no spoofing path, only calling.
3. **Calling one is self-harm, confined to the caller's own generation.** The host keeps
   authoritative request state; e.g. `__tenonSettleIntent` with an unknown token returns
   `false`, and settling your own pending intent with a fabricated result only lies to
   yourself. No cross-principal effect exists.
4. **Visibility is pinned, not open.** The exemption is encoded by NAME:
   `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` lists all 20 hooks in its
   expected `Object.getOwnPropertyNames(globalThis)` set, so adding a 21st hook — or
   removing one — fails the suite until the test is updated deliberately. The exemption
   cannot silently widen, which is the failure mode that lost the `console` deletion in
   `163c8bf`/`8620bc3`.

Invariant 1 in `CLAUDE.md` now states the exemption affirmatively and names the test.

## Criteria
- [x] `console` is deleted in every plugin context; `typeof console` evaluates to
      `"undefined"` from plugin code — `delete globalThis.console;` at
      `PluginRuntimeBootstrap.swift:8`, asserted by the new test's first check
- [x] A test pins `Object.getOwnPropertyNames(globalThis)` against the exact expected set —
      62 ECMAScript builtins + 20 named `__tenon*` hooks + `tenon` — so that the NEXT
      global to appear fails the suite rather than arriving unnoticed
      (`PluginBuiltinsTests.swift` `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon`)
- [x] That test is proven load-bearing: deletion removed → RED at 00:20 (both asserts:
      `typeof console` came back `"object"`, property list carried `"console"`), deletion
      restored → GREEN at 00:21
- [x] The `__tenon*` hook decision is made and recorded in this file with its reasoning
      (see `## Decision` above: kept, exempt by name, pinned in the test)
- [x] CLAUDE.md invariant 1 states the rule and names the test that now enforces it, with
      no "not yet enforced" clause left behind
- [x] `swift build` exit 0 and the full suite green at or above the current baseline —
      `swift test` **724 tests / 0 failures** at 00:22 (claim-time baseline 723; +1 = the
      new scope-closure test), `swift build` exit 0
