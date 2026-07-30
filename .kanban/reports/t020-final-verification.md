# T-020 final verification — independent verifier pass, 2026-07-31 00:29–00:5x

Worker: Orca `task_a4f813d702ff` (dispatch `ctx_39a78acca18a`, terminal
`term_05bb75aa-e4b0-45b8-a8ba-e84c4fc058c8`). Tree verified: `main` @ `e3c5435`
(17 commits landed tonight between 22:16 `17f36a0` and 00:36 `e3c5435`; the brief's
"thirteen" grew by four while this pass ran) + T-006's live uncommitted palette-provider
work. Method: every claim below is a measurement this slice ran itself or a file:line it
read itself; nothing is inherited from a commit message or another worker's write-up.

## Verdict

**APPROVED — the committed integrated result at `e3c5435` deserves approval.** The
caveats below are named, owned, and none of them block: the two warnings found are fixed
in this slice, and every remaining red sits inside T-006's declared in-flight window, in
files T-006 claims, caused by deltas that exist only in their uncommitted state.

This approval could have been withheld, and nearly was on two counts: the tree's
"zero Swift warnings" claims turned out to be measured on incremental builds (worthless
for warnings), and a full-recompile sweep found two real warnings in committed code —
either of which would have made the warnings-as-errors criterion a lie the moment the
flag landed. Both were fixed (one word each) before the flag went on.

## Measurements (all mine)

| When | What | Result |
|---|---|---|
| 00:30 | `swift build` baseline | exit 0 in 7.95 s — **incremental, so its 0-warning output proves nothing**; stated to show why earlier zero-warning claims were unsound |
| 00:32 | `swift test --filter testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` | GREEN (0.019 s) |
| 00:33 | same test, `delete globalThis.console;` removed | **RED for the right reason** — both asserts, `"console"` visible in the actual `globalThis` list |
| 00:34 | file restored byte-identical (sha256 `8f2de472…` = HEAD; clean `git status`) | GREEN again |
| 00:36 | full-recompile sweep #1 (`swift test -Xswiftc -DTENON_WARNSCAN`) | died after 340 compile tasks on T-006's mid-save (`PluginRuntime.swift` "modified during the build"); before dying it found the tree's ONE source-target warning: `WorkspaceCatalogStore.swift:557` |
| 00:39–00:40 | full-recompile sweep #2, complete | **730 tests / 2 failures / 30.3 s**; only remaining Swift warning `LauncherCommandsTests.swift:103`; both failures named and owned below |
| 00:44 | `swift build` with warnings-as-errors ON | **Build complete, 41.29 s, exit 0** — zero Swift diagnostics; exactly the 2 GhosttyKit ImGui linker warnings remained *warnings* (the scoping requirement held) |
| 00:44 | `swift test` under the flag | xctest process **crashed inside T-006's untracked `PaletteProviderTests.swift`**: `PinnedThreadExecutor.swift:100` precondition "received work after shutdown began" — no totals obtainable |
| 00:47 | retry | died at build on T-006's mid-refactor `PaletteOverlay.swift:342` (`IntentID` vs `CommandMatch` type errors) |
| 00:5x | last attempt after a settle window | see the addendum at the bottom |

## Criterion "fitness tests reject undeclared surfaces, stale request paths, audience drift" — DONE, mutation-proven

All four legs enforced:

1. Stale request paths — `CLIIntentBusBoundaryTests.swift:5` (legacy CLI verbs +
   forbidden dependencies pinned out).
2. Audience drift — `CoreIntentCatalogTests.swift:538` (per-intent audiences, exact
   `pluginOnly` set, lane map).
3. Undeclared `tenon.*` — `PluginBuiltinsTests.swift:86`
   (`testRuntimeExportsOnlyTheClassifiedPublicSurface`).
4. `globalThis` scope closure — `PluginBuiltinsTests.swift:143`
   (`testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon`, landed by T-037 in
   `2b6a385`), **verified load-bearing, not assumed**: GREEN → deletion removed from
   `PluginRuntimeBootstrap.swift:8` → RED on both asserts with `"console"` in the actual
   list → restored byte-identical → GREEN.

Live confirmation nobody planned: at 00:39 T-006's in-flight `tenon.palette` member
turned legs 3+4 red exactly as designed — the fence works against a real change, and
their claim includes the same-change pin update the change protocol demands.

## Criterion "Swift 6 warnings-as-errors build and the full test suite pass" — flag ON and proven; the suite half is blocked only by the live window

- Verified: `Package.swift` had **no** warnings-as-errors configuration of any kind —
  the criterion was previously unenforceable as written.
- Falsified: "zero Swift warnings" as previously measured. Incremental builds recompile
  nothing and re-emit nothing. Two full-recompile sweeps found exactly two warnings,
  both in **committed code owned by finished, released tasks**, both fixed here one word
  each:
  - `Sources/TenonCore/WorkspaceCatalogStore.swift:557` — redundant `await` on a sync
    same-actor call (actor at `:513`, sync callee at `:569`; committed in `05d0d46`).
  - `Tests/TenonCoreTests/LauncherCommandsTests.swift:103` — redundant `try` on
    non-throwing `PluginLoader.discover` (committed in `df15971`).
- The flag: `swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]` on **all seven
  first-party targets** (TenonIntentCore, TenonCore, TenonApp, TenonCLI + the three test
  targets). `.treatAllWarnings(as:)` was probe-verified **unavailable** at
  `swift-tools-version: 6.1` (it needs 6.2), and the unsafeFlags variant was
  probe-verified to hard-fail a warning before it touched the shared tree. Vendored
  packages, dependency packages, and the GhosttyKit C shim are outside the flag; the two
  prebuilt ImGui **linker** warnings stayed warnings in the 00:44 build — measured, not
  assumed.
- Timing rule honored: the flag went on LAST, and at flip time the in-flight code had
  zero Swift warnings (sweep #2 compiled T-006's live `PluginRuntime.swift`,
  `PluginRuntimeBootstrap.swift`, `PaletteProviders.swift` clean).
- What remains for the checkbox: one green full-suite run on a settled tree. The
  complete measurement tonight is 730/2 with both reds owned by the live window (below);
  post-flag attempts could not finish while T-006 saves mid-refactor states.

## Criterion "an independent verifier approves the integrated result" — this report

### The interaction ladder over what shipped tonight

| Shipped item | Rung | Lawful? | Evidence |
|---|---|---|---|
| `pane.cwd-changed` | EVENT (law step 2) | **yes** | Fact on a host-owned channel, no reply; classification + the `pane.*`-not-`terminal.*` permission reasoning stated and implemented at `PluginHost.swift:1460-1485`; publication gated on first sight or an actual root move (`SurfacePool.swift:156-168` → `ProjectRoot.rerootsPanels:67`), so `cd` churn notifies nobody — exactly the law's inventory promise (`architecture-interaction-boundaries.md:337-346`) |
| `workspace.content.open.v1` | INTENT (step 6) | **yes** | Finite unicast crossing plugin/CLI/agent principals; catalog entry `CoreIntentCatalog.swift:43`; the provider validates then calls the SAME typed service (`WorkspaceIntentProvider.swift:332-364` → `store.openContent`) that built-in UI calls DIRECT (`ChangesPanelView.swift:500`, `WorkspaceStore.swift:143`) — the law's one-implementation diagram; its predecessor `showDiff` was deleted in the same slice (change-protocol rule 5) |
| `palette.launcher` manifest flag | CONTRIBUTION | **yes** | Plugin-owned presentation metadata, host-projected; `PluginManifest.swift:283`, decode fail-closed `?? false` (`:354-357`); projection `CommandIndex.launcherOnly` (`CommandIndex.swift:96`) |
| Plugin view instance model | CONTRIBUTION registration + owner-scoped EVENT facts + DIRECT host reconcile | **yes** | `register({instanced:true})` is registration; `onOpen`/`onClose` are the law's owner-scoped lifecycle facts; reconcile is same-owner host code; **no new `tenon` member** (the surface pin passed at HEAD) |
| `WorkspaceCatalogStore` (catalog persistence) | same-owner DIRECT | **yes** | Host-internal persistence, no public adapter, versioned DTO layer instead of `Codable` on domain types; nothing outside the host owner ever needs it |
| `EditorPaneStateStore` (per-slot editor state) | same-owner DIRECT | **yes** | App-shell state store, no public path, no `IntentValue` detour |

### The invariants tonight's work most plausibly bent

1. **Scope closure** — holds, mutation-proven (above).
2. *(not in scope of this pass beyond the pins that enforce it)*
3. **`TenonCore` imports no AppKit/SwiftUI** — holds: zero `import AppKit` /
   `import SwiftUI` / `canImport` guards across `Sources/TenonCore` and
   `Sources/TenonIntentCore` (which also has zero `import JavaScriptCore`), measured
   after all of tonight's new core files landed.
4. *(broken-plugin isolation — regression-covered by the suite's 730; no new evidence needed)*
5. /6. **One typed semantic implementation** — holds for the night's new public surface:
   `workspace.content.open.v1` adapts to the same `WorkspaceStore.openContent` the UI
   calls; the two new stores add **no** second public protocol (neither has an
   intent/CLI path at all).
10. **Bounded lifetimes** — holds for the night's new machinery:
   `WorkspaceCatalogStore` keeps at most one scheduled write task
   (`:554` guard), caps reads at 16 MB (`:514`), flushes on quit;
   `EditorPaneStateStore` is LRU-bounded at 64 (`EditorPaneState.swift:56`, eviction
   `:118`) and its file-watch token cancels in `deinit` (`:158-159`);
   `PaneActivity` takes an injected `now: Date` on every mutation — no sleeps, no
   wall-clock reads.

## Findings, ranked

1. **FIXED — a Swift warning in committed core code**
   (`Sources/TenonCore/WorkspaceCatalogStore.swift:557`, from `05d0d46`): redundant
   `await`; would have turned the warnings-as-errors flag into an instant build break.
   One word removed. The zero-warning claims that missed it were incremental-build
   measurements.
2. **FIXED — a Swift warning in committed test code**
   (`Tests/TenonCoreTests/LauncherCommandsTests.swift:103`, from `df15971`): redundant
   `try`; same consequence for the test targets. One word removed.
3. **OWNED BY T-006 (in flight, not blocking this approval)** — three simultaneous
   states of their mid-change window: (a) the two surface pins red against their
   uncommitted `tenon.palette` member (`__tenonPaletteQuery` in the actual list; HEAD
   has zero palette references in the bootstrap — attribution airtight); (b) their
   untracked `PaletteProviderTests.swift` **crashes the whole xctest process** via the
   `PinnedThreadExecutor.swift:100` shutdown precondition (kernel code from `163c8bf`
   doing its invariant-10 job of failing loud) — any concurrent agent running
   `swift test` right now loses its totals to that crash, and whether the test misuses
   shutdown ordering or has found a real executor race is T-006's to determine before
   landing; (c) a transient `PaletteOverlay.swift:342` type error mid-refactor. All
   three are in files T-006 claims on the board.
4. **PROCESS — warning claims need full recompiles.** Recorded so the next slice does
   not repeat tonight's method error: `swift build` exit 0 on a warm cache says nothing
   about warnings. `-Xswiftc -D<unused-define>` forces an honest full re-emit without
   touching a file.
5. **NOTE** — the two GhosttyKit ImGui linker warnings remain warnings by design; the
   flag's per-target scoping cannot and should not reach a prebuilt vendored archive.

## What this approval covers

The committed integrated result up to `e3c5435`, plus this slice's own three writes
(`Package.swift` flag, the two one-word warning fixes). It does **not** cover T-006's
uncommitted palette-provider delta — that lands under its own verification with its own
pin updates, per the change protocol.

## Addendum — last settle-window suite attempt (00:52, COMPLETE, under the flag)

**750 tests / 9 failing test cases (28 assertion failures) / 31.2 s — and every single
failure sits inside ONE untracked in-flight file**:
`Tests/TenonAppStateTests/PaneAttentionTests.swift`, the T-029 app half claimed by Orca
worker `task_f3b0bcbc0314` at 00:38 (with its untracked `PaneAttentionNotifier.swift` /
`PaneAttentionProjection.swift` and its `SurfacePool.swift` edits). The failure shape —
every assert is `nil is not equal to Optional(...)` — is a textbook TDD RED phase:
tests landed, machinery not yet wired. The other **741 tests pass**, including:

- both surface pins now GREEN against T-006's grown palette surface — **T-006 updated
  the pins in their same change, exactly as the change protocol requires**, so finding 3a
  resolved itself while this report was being written; their `PaletteProviderTests`
  crash (3b) also no longer reproduces in this run;
- the whole build — committed tree PLUS both live workers' in-flight sources — compiled
  **under warnings-as-errors, exit 0**. The flag is live and the shared tree already
  clears it.

Verdict unchanged: **APPROVED**, with the suite's only reds being one in-flight TDD-red
file, named and owned above.
