# Reference Terminals — Engineering Lessons for Tenon (kero & muxy)

> **Historical research snapshot — non-normative.** Source observations and old Tenon
> API spellings are retained as evidence of what was inspected on 2026-07-24. Current
> implementation decisions MUST follow
> [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md);
> [`design-intent-bus.md`](design-intent-bus.md) owns the intent kernel after that law
> selects INTENT. Any recommendation below that conflicts with those documents is
> superseded.

**Date:** 2026-07-24
**Scope:** Engineering-level lessons for **Tenon** drawn from two reference macOS terminals vendored under `refrerences/`: **kero** (`egoist`, indexed commit `a250a52`) and **muxy** (`muxy-app`, indexed commit `a32a179`). Focus: ghostty embedding, workspace/split model, terminal surface lifecycle, and (for muxy) the plugin/permission system — framed as *reuse / adapt / avoid* for Tenon.

**Companion doc:** `research-plugin-runtimes.md` §1 is a deeper teardown of muxy's runtime & sandboxing at an earlier commit (`f520289`). This doc does **not** repeat it; it adds kero (not covered there), muxy's terminal/workspace engineering, a cross-validation against the two repos, and the open architectural decisions that fall out. Read §1 there for the runtime/sandbox detail; read this for the decision-oriented synthesis.

**Confidence labels:** `HIGH` (verified by reading source via repowise or raw read), `MEDIUM` (inferred from a pattern in verified code), `LOW` (guess; verify before depending on it).

**Citations:** files under kero are relative to `refrerences/kero/`, files under muxy relative to `refrerences/muxy/`, files under `poc/` are Tenon itself.

---

## 0. The one finding that frames everything

**Tenon's pure-core architecture is right — both larger codebases prove it by where their bugs live.** In kero and muxy alike, churn and defects concentrate almost entirely in the **AppKit/SwiftUI seam that neither codebase abstracts**, while the pure logic (where it exists) stays clean.

- muxy **has** a genuine functional core — `WorkspaceReducer.reduce(action, &state) -> SideEffects` (`Muxy/.../WorkspaceReducer.swift:31`), the twin of Tenon's `Workspace` + `[WorkspaceEvent]`. It scales to ~50 actions across a 6-level hierarchy **without being a hotspot**. But `GhosttyTerminalNSView.swift` — a concrete `NSView` with **no `TerminalSurface`-style seam** — is 1951 lines, 23 fixes in 6 months, health 4.5, **untested** (`get_risk`, HIGH). It is the bug magnet.
- kero has **no** separated core: `TerminalManager` is a god-object holding UI state + a static window registry + persistence + all menu-command routing → health 4.98, untested, highest `change_entropy` in the repo (`kero/TerminalManager.swift:34-149`, `get_risk`, HIGH).

**Conclusion:** `TerminalSurface` + `StubTerminalSurface` (the "assert it in `TenonCoreTests` without a window" seam) is exactly what both references lack and pay for. It is a real advantage — keep and harden it.

Two naming corrections worth recording, because both are easy to assume wrong:

- **kero has no plugin system.** Its `SyntaxHighlightPlugin.swift` is a compile-time internal of the STTextView library; `web/` is a marketing landing page. kero is a native monolith. At the time of this snapshot, Tenon described its independently reloadable plugin boundary as a differentiator. (HIGH — `SyntaxHighlightPlugin.swift:32`, `web/README.md`)
- **`MuxyHookBridge` is not the extension host.** It is a CLI (`muxy-hook`) that bridges **AI-agent lifecycle hooks** (e.g. Claude Code posting status back to the app over the same socket). The real extension host is `MuxyExtensionHost`. (HIGH — `MuxyHookBridge/main.swift`, `NotificationSocketServer.swift:853-877`)

---

## 1. kero — teardown (new; not in the companion doc)

kero is a terminal-centric IDE-lite for running AI coding agents: shell + file tree + git diff + panels, terminal at the center. It uses an editor (STTextView + TreeSitter) as pane content — it does not build one for its own sake.

### 1.1 Ghostty embedding — libghostty-spm wraps the *same* xcframework (HIGH)
kero consumes ghostty through the SwiftPM package `Vendor/libghostty-spm`, which exposes 4 products: `GhosttyKit` (raw C API), `GhosttyTerminal` (a high-level Swift wrapper: view + controller + ~18 delegates + config builder + display link), `GhosttyTheme` (485 themes), `ShellCraftKit` (unused by kero). Crucially, `libghostty-spm/Package.swift:46-48` is a `.binaryTarget` pointing at a `GhosttyKit.xcframework.zip` on GitHub releases + checksum — **the same prebuilt xcframework Tenon ships**.

→ The real difference is **not** "SPM vs xcframework" but the **abstraction tier consumed**: kero uses the high-level `GhosttyTerminal` wrapper; Tenon consumes the raw C API and hand-writes `GhosttySurface`. The narrow raw seam remains useful; the wrapper is a feature map — see §4.

- Surface init: each `TerminalSession` builds a `TerminalController(...)` + a `KeroTerminalView` (subclass of the wrapper's `AppTerminalView`), setting `TerminalSurfaceOptions(backend: .exec, workingDirectory:, envVars:)` — `.exec` = real PTY (`TerminalSession.swift:60-82`, HIGH).
- Config uses a **builder pattern**: `TerminalConfiguration { builder in builder.withFontFamily(...).withCustom("keybind","clear")... }` (`TerminalSession.swift:251-314`, HIGH) — declarative, readable, AI-writable.
- Callbacks: the wrapper exposes ~18 `TerminalSurface*Delegate` protocols (title, focus, bell, close, pwd/OSC7, progress/OSC9;4, openURL, search, clipboard-confirm/OSC52, scrollbar, desktop-notification…); `TerminalSession` implements ~13 (`TerminalSession.swift:441-599`, HIGH). **Contrast:** Tenon currently bridges only `title → onTitleChange` (`GhosttySurface.swift`).

### 1.2 `TerminalManager` — the anti-pattern (HIGH)
`get_risk`: hotspot 99% (increasing), 11 dependents, **`test_gap: true`**, bus-factor 1, +629 lines/90d. It is a single `@MainActor ObservableObject` holding: UI state (projects, selection, panels, palette visibility) + a static `[TerminalManager]` registry + `pendingRestores`/`pendingHistories` + persistence (`saveAll`/`makeWindowSnapshot`/`restore`) + 3 Combine observation chains re-publishing `objectWillChange` up from Session→Project→Manager + routing for *every* menu command. This is precisely the shape Tenon's core is designed to prevent. Don't let `WorkspaceStore`/`PluginHost` grow the same way.

### 1.3 Surface parking (HIGH — the UX trick worth stealing)
`Pane`/`PaneColumn` are value-type structs with weight ratios; layout is niri-style (horizontal columns, vertical pane stacks) mutated in place via `@Published` (`Panes.swift:65-395`). The notable technique: a hidden session's `KeroTerminalView` is **parked** in an alpha-0 `TerminalParkingView` (still window-attached) so libghostty keeps ticking and the PTY/scrollback survive tab switches (`TerminalHostView.swift:69-137`, `ContentView.swift:82-91`, HIGH). Tenon achieves the same end differently — see §3.

### 1.4 Hardened operational details worth copying (HIGH)
- **Clipboard OSC52 = ask, never auto-allow read** (anti-exfiltration over SSH), with a confirmation sheet (`TerminalSession.swift:298-312, 525-561`).
- **Keybind "clear" then selectively re-add**, so the app keeps Cmd-T/D/K while ghostty keeps only local editing/scroll (`TerminalSession.swift:267-296`) — same problem Tenon solves via the action callback.
- **Launch shim**: PID shim, `umask 077`, temp dir 0700, `.vt` history replay; teardown SIGHUP → 120ms → SIGKILL (`TerminalSession.swift:127-164, 340-402`).
- **Self-hosted release**: one Bun/TS command → archive → Developer ID export → notarize → staple → DMG → sign + regenerate Sparkle appcast (EdDSA + delta) → upload to Cloudflare R2 (`scripts/release.ts`, `RELEASING.md`). No App Store.

---

## 2. muxy — terminal & workspace engineering (new dimension)

### 2.1 Ghostty embedding — identical shape to Tenon (HIGH)
`GhosttyService.shared` holds one process-wide `ghostty_app_t`; runtime callbacks are C function-pointer trampolines routed back to the singleton and resolved to the right `NSView` via `ghostty_surface_userdata()` (`GhosttyService.swift:37-59`, `GhosttyRuntimeEventAdapter.swift:293-297`). This is what Tenon already does. muxy additionally supports **live config reload** via `ghostty_app_update_config` + a `configVersion` bump + theme re-apply (`GhosttyService.swift:143-158`) — Tenon does not yet.

Surface creation manages C-string/env pointers manually (`strdup` into a tracked array, freed on teardown) and has an ordered teardown (`destroySurface` → `tearDown` nils all closures → `deinit` safety-net free) — `GhosttyTerminalNSView.swift:133-322`. This manual pointer management is a documented source of bugs (`createSurface` took 6 fixes).

### 2.2 Ghostty's action set does NOT include split/tab (HIGH)
muxy's adapter handles only pwd, set-title, notification, search, secure-input, command-exit, mouse-over-link, open-url, progress, scrollbar (`GhosttyRuntimeEventAdapter.swift:23-68`). **Split/tab/goto-split are owned by the app, not emitted by ghostty.** This is directly relevant to the keybinding-routing decision in §6.

### 2.3 Functional core + reparenting broker (HIGH)
- `AppState` is a `@MainActor @Observable` mutable shell; each action runs through `WorkspaceReducer.reduce` (pure, delegating to `ProjectLifecycle/Tab/Split/Focus/TopLevelTab` sub-reducers) producing a value `WorkspaceSideEffects { createdTabID, createdPaneID, paneIDsToRemove, projectIDsToRemove, deferredAreaCollapses }`; auto-save runs after every action (`AppState.swift:794-902`). No-op actions short-circuit to empty effects (`:816-833`) — semantically identical to Tenon's "empty `[WorkspaceEvent]` = nothing changed".
- **Reparenting broker** (the important one): `TerminalBridge` (an `NSViewRepresentable`) does **not** create/destroy the view on mount — it borrows/returns a `GhosttyTerminalNSView` through `ReparentingNSViewBroker`, and `dismantleNSView` only releases the claim. The surface + PTY survive SwiftUI re-mounts (`TerminalPane.swift:227-260`, HIGH). This is muxy's solution to "SwiftUI destroys the surface on layout change."
- `SplitNode` is a hybrid tree: `enum { .tabArea | .split(SplitBranch) }` where transforms return a *new* node (`splitting()`, `removing()`) — value-semantic in spirit though `SplitBranch` is a class. A separate `VisiblePaneNode` (pure indirect enum) is the render projection (`SplitNode.swift:15-291`).

### 2.4 Persistence (HIGH)
`WorkspaceRestorer.snapshotAll/restoreAll` snapshots the split tree recursively into a `SplitNodeSnapshot` (Codable indirect enum), stores each pane's `cwd` with a path-in-project validation, uses a tolerant `init(from:)` for migration, and auto-saves after every mutation (`WorkspaceSnapshot.swift`). Because Tenon's core is already pure value, this snapshot is nearly free to add.

### 2.5 Where the hotspots are (HIGH)
`MainWindow.swift` (32 fixes — highest in repo), `GhosttyTerminalNSView.swift` (1951 lines, 23 fixes), `MuxyApp.swift` (17), `TabStrip.swift` (11) — all in the AppKit/SwiftUI seam. The pure reducer / `SplitNode` / `TabArea` are not hotspots. Same lesson as kero, from the opposite direction.

---

## 3. Verified against Tenon: SurfacePool already solves the #1 risk

Both kero (parking) and muxy (reparenting broker) independently cure the same disease: *SwiftUI tearing down the surface on split/tab change kills the PTY.* Checked against Tenon (`SurfacePool.swift:20-67`, HIGH):

> `SurfacePool` caches exactly one `TerminalSurface` per pane UUID in a private dictionary, decoupled from the SwiftUI view lifecycle. Same UUID → same `GhosttySurface` → same PTY across split-tree rearrangements and tab switches. The surface is released only when `retainOnly(_:)` finds the UUID no longer in the workspace.

→ Tenon **already has the essence of the reparenting broker** at the surface-object layer.

**Residual to verify (one read of `ContentView.swift`):** does the `NSViewRepresentable` wrapping a pane reuse the cached surface's `NSView`, or call `makeNSView` fresh each mount? If it reuses → fully safe. If not → that is exactly where to port muxy's `ReparentingNSViewBroker`. The foundation is correct; only this last hop is unconfirmed.

---

## 4. muxy — plugin & permission engineering (the core lesson for a plugin-first app)

**Framing caveat:** muxy is *not* "every feature is a plugin". Its core
(terminal/git/browser/panes) is native Swift; extensions are out-of-process add-ons. The
snapshot compared that with Tenon's in-process plugin host. What transfers is the shape of
individual capabilities and — above all — the security layering. Current Tenon mechanism
selection follows semantic ownership, not a plugin-first slogan.

Runtime shape (detail in companion §1): each extension is a `MuxyExtensionHost` subprocess with its own `JSContext`, over a Unix socket (base64-JSON line framing); UI surfaces are `WKWebView`; a third in-process `JSContext` (`ExtensionScriptRunner`) runs one-shot `runScript` commands. The narrow waist still matches Tenon: one frozen `muxy` global + `__muxyDispatch(verb, args) -> {ok, value|error}` + a gate that returns errors, never throws (`ExtensionBridgeJS.swift:11-20`, HIGH).

**Important caveat:** muxy's out-of-process model is **not** an OS sandbox (no seatbelt/`sandbox-exec`; the app is not App-Sandboxed). `exec` runs as a child process with **full user privileges**. Process split buys crash/resource isolation, not a security boundary. Do not treat out-of-process as evidence of "safe".

### 4.1 API surface: Tenon ↔ muxy ↔ verdict (HIGH throughout — both sides read from source)

| Tenon API | muxy equivalent | What's worth learning | Verdict |
| --- | --- | --- | --- |
| `statusBar.set(text)` (free, last-wins) `PluginRuntime.swift:143-150` | `muxy.statusbar.set/show/hide`; item declared in manifest `statusBarItems[]{id,icon,side,command}`, JS mutates by **id** (`ExtensionBridgeJS.swift:242-253`) | muxy separates **declare-in-manifest** (id+side+command) from **mutate-by-id**; many items per plugin | **ADAPT**: allow multiple items + id + icon; skip side/command for now |
| Historical `commands.register(id,title,fn)` snapshot (`PluginRuntime.swift:153-170`) | manifest `commands[]{id,title,subtitle,action,defaultShortcut}` `manifest.schema.json:279-293`; shortcut auto-assigned when blank, registered unassigned on conflict | muxy commands are **declared in manifest** (declarative action) + **defaultShortcut** | **CURRENT RESOLUTION**: palette/keybinding rows project plugin-owned intent contracts with presentation metadata; there is no separate command protocol or dynamic command callback registry |
| Historical command-palette gap | `muxy.modal.open({onQuery,onSelect})` — streaming fuzzy palette: type → `onQuery(q,emit)` → `modal.feed(items)` → `modal.finish` (`ExtensionBridgeJS.swift:90-125,188-230`) | onQuery-streaming is a strong fuzzy-finder model | **CURRENT RESOLUTION**: the ordinary palette is a projection of finite plugin-owned intents; a future live query has RESOURCE/CONTRIBUTION semantics and MUST NOT widen the command plane |
| `events.on(event,fn)` (free; `terminal.*` gated read) `PluginRuntime.swift:176-190` | subscribe requires manifest `events[]` + permission for sensitive topics (`NotificationSocketServer.swift:160-169`); host diffs workspace snapshots and broadcasts `pane/tab/project.*` to all subscribers (`ExtensionEventEmitter.swift:139-219`) | (1) muxy makes plugins **declare event topics in manifest**; (2) sensitive topics need permission — same idea as Tenon's `terminal.read`; (3) drop-threshold backpressure | **REUSE** the gate-topic mechanism; **ADAPT**: consider requiring event-topic declaration in manifest (self-documenting, auditable) |
| `tenon.events.emit` (now shipped and manifest-declared) | `muxy.events.emit("extension.*")` is **same-extension only** — `canDeliverExtensionEvent` requires `observerExtensionID == incomingExtensionID` (`NotificationSocketServer.swift:661-666`) | muxy **forbids plugin→plugin messaging**; emit reaches only the plugin's own surfaces | **REUSED:** Tenon keeps plugin-owned event publication scoped and does not expose a generic cross-plugin bus |
| `settings.get(key)` (free, get-only) + manifest `settings[]` `PluginRuntime.swift:337-350`, `PluginManifest.swift:49-65` | manifest `settings[]{key,title,description,type,defaultValue}` `manifest.schema.json:397-408`; auto-rendered form; override stored in **UserDefaults** `muxy.ext.<id>.<key>`; `effective = override ?? default` | Nearly identical to Tenon. muxy adds a `description` field for the form | **REUSE** (Tenon already right); small **ADAPT**: add `description` for nicer auto-render |
| `storage.get/set` (free, per-plugin KV) `PluginRuntime.swift:352-374` | `muxy.storage.get/set/delete/keys` → per-extension file `extension-storage/<slug>-<sha8>.json`; quotas **key≤256, value≤1MB, store≤5MB** (`ExtensionStorageService.swift:6-93`); atomic write | muxy has **`delete`+`keys`** + explicit **quotas** + hash suffix vs name collisions | **ADAPT**: add `delete`/`keys` + quotas; Tenon validates JSON already but has no size cap |
| Historical `sidebar.set(...)` + `views.register/set` snapshot (`PluginRuntime.swift:376-446`) | manifest `sidebar{id,entry}` / `panels[]` / `popovers[]` / `tabTypes[]` = **WKWebView** loading an HTML asset (`manifest.schema.json:214-278`) | muxy UI = webview HTML/JS (heavy, needs a build); Tenon uses native declarative view contributions | **CURRENT RESOLUTION**: `tenon.views.*` is CONTRIBUTION; the unrendered sidebar surface is removed; browser content alone uses a host-owned WebKit resource |
| Historical `workspace.get()` snapshot (`PluginRuntime.swift:451-456`) | `panes.list/tabs.list/projects.list` — each **gated** `panes:read`/`tabs:read`/… (`MuxyAPI.swift:392+`) | muxy gates workspace reads | **CURRENT RESOLUTION**: public callers use policy-authorized `workspace.state.v1`; built-in Swift UI reads the same-owner typed workspace service DIRECT |
| Historical `workspace.newTab/split/closeSlot` snapshot (`PluginRuntime.swift:458-515`) | `tabs.new/close`, `panes.split/close/send` — gated `tabs:write`/`panes:write`, and dangerous operations also pass runtime consent | muxy splits write authority into fine-grained verbs | **CURRENT RESOLUTION**: public workspace mutations use the closed canonical `workspace.*.v1` intent inventory and explicit policy bindings |
| Historical `fs.readDir/readFile/writeFile` snapshot (`PluginRuntime.swift:195-258`) | `muxy.files.list/read/write` gated `files:read/write`; **`files.write` also needs consent** (`ExtensionGrantStore.swift:21`) | write = static permission + per-path runtime consent | **CURRENT RESOLUTION**: finite filesystem work uses canonical `filesystem.*.v1` intents; change observation is the bounded `tenon.fs.watch` resource |
| Historical `process.exec(cmd,args,cb)` snapshot (`PluginRuntime.swift:263-317`) | `muxy.exec/execAsync` gated `commands:exec` + **mandatory consent** matched by argv-prefix (`ExtensionGrantStore.swift:13,366-374`); `execAsync` returns a cancellable job | exec = static permission + consent-per-command + cancellable async | **CURRENT RESOLUTION**: collected execution is `process.exec.v1`; live output is the bounded `tenon.process.stream` resource |
| Historical `terminal.write` snapshot (`PluginRuntime.swift:319-332`) | `panes.send/sendKeys` gated `panes:write` + **consent** (`.panesSend`) | consent even for injecting terminal input | **CURRENT RESOLUTION**: finite public terminal write/run/read/wait operations are canonical intents; surface retention remains RESOURCE/DIRECT lifecycle |
| `log(text)` (free) `PluginRuntime.swift:517-522` | `console.log/warn/error` → stderr + per-extension `ExtensionLogStore` with a tail UI | muxy keeps a **per-extension log store + tail UI** | **ADAPT**: add a per-plugin log ring buffer surfaced in the UI (cheap, great for debugging) |

### 4.2 Two mechanisms where Tenon is already ahead (HIGH)

- **Hot-reload.** muxy does **not** auto-reload on file save: `reload()` = `stopAll() + startAll()`, triggered only manually (install / add-remove dev path) (`ExtensionStore.swift:152-165`). Its only FSEvents watcher is `HookConfigWatcher` (for AI-hook config), which does not watch extensions. Tenon's `PluginWatcher` (recursive FSEvents, 0.15s debounce, `/private` symlink handling, per-plugin-name reporting) is **strictly better**. Both drop state across reload by design — keep Tenon's.
- **Single runtime per plugin.** muxy needs *two* JS execution paths — a long-lived out-of-process background host (listens to events, serves remote methods) and an in-process `ExtensionScriptRunner` (one-shot `runScript` commands, not worth a subprocess) (`ExtensionScriptRunner.swift:8-60`). Tenon's one in-process runtime per plugin already serves both roles. Don't split it — this is a place Tenon is legitimately simpler.

### 4.3 Broken-plugin isolation (historical Tenon invariant numbering) (HIGH)

muxy relies on the **process boundary**: a runtime error kills the child, the host lives. `handleTermination` classifies exit, sets `status.lastError`, logs, and `scheduleCrashRestart` with backoff up to **5 attempts**, resetting the counter after a stability window (`ExtensionStore.swift:1008-1071`). Load errors (name/dir mismatch, duplicate name) are caught and marked `lastError` without killing the host (`:846-870`). A JS exception inside the host goes to `context.exceptionHandler` → stderr (`MuxyExtensionHost/main.swift:94-97`).

→ Tenon reaches the same guarantee **in-process**: a JS exception routes to `context.exceptionHandler` → log, never thrown out to the host (`PluginRuntime.swift:123-125`), and the watcher reloads on fix. Tenon lacks crash-restart-with-cap (it has no process to crash) but should **borrow `lastError`/status + a load-time attempt cap** for plugins that keep throwing at load. muxy's genuine edge here is real crash isolation; Tenon trades it for simplicity — an acceptable trade at pre-alpha.

### 4.4 Consent / grant / audit — the implementation blueprint (VISION §5) (HIGH)

This is the highest-value thing to lift from muxy, and it maps cleanly onto Tenon's single-home gate. Enough detail to design `requirePermission` evolution from:

- **Flow.** Every sensitive op → `ExtensionConsentService.gate(request)` (`ExtensionConsentService.swift:51-78`) → `grantStore.evaluate(extID, verb, payload)` → one of `.allow(ruleID)` / `.deny(ruleID)` / `.ask`. `.ask` prompts the user (async continuation), auto-denying on queue-flood (>5 prompts/ext) or a **60s timeout** (`:106-110, 172-188`).
- **Five user choices** (`:18-24`): `allowOnce, allowAndRemember, denyOnce, denyAndRemember, blockKind`. "…Remember" writes a persistent `ExtensionGrantRule`; `blockKind` blocks the whole verb class.
- **Grant store.** `~/Library/Application Support/.../extension-grants.json`, pretty JSON, sorted keys, ISO-8601, private perms (`ExtensionGrantStore.swift:277-278,347-354`). Rule = `{id, extensionID, verb, match, decision, createdAt}` (`:225-248`).
- **`match` has specificity** (`:42-178`): `any / argvExact / argvPrefix / shellExact / paneEquals / hostEquals / gitOperationEquals / fileOperationEquals / …`. Evaluation picks the highest-specificity rule; allow beats deny at equal specificity; older wins (`:285-305`). Default "remember" suggestion: exec → `argvPrefix([base])`, network → `hostEquals(host)` (`:361-395`).
- **Revoke.** `remove(ruleID)` / `removeAll(for: extID)` / `blockKind` (`:317-334`).
- **Audit.** `ExtensionAuditLog` — **JSONL append** to `extension-audit.log`, one line `{timestamp, extensionID, verb, payloadSummary, decision, ruleID, source}` (`ExtensionAuditLog.swift:6-14`), written on **every** decision (allow/deny/blocked, with reason), capped 1MB → trimmed to 256KB keeping whole lines, private perms (`:19-116`).

→ Historical port shape: Tenon's `requirePermission(_:api:)` was a boolean
`manifest.permissions.contains(...)` → nil/violation (`PluginRuntime.swift:533-545`).
Consent, remembered patterns, and audit can evolve inside the canonical intent policy path;
they do not create another public bridge. An `.ask` timeout resolves fail-closed.

### 4.5 Host-native code and plugin parity — historical question, now resolved (HIGH)

muxy has **no bundled plugins** — its terminal/git/browser/panes core is native Swift in the
app, not extensions. Third-party extensions and the starter-kit template use the same
manifest schema (`package.json` + `muxy` key) and the same API; the schema is a
"marketplace mirror" of the Swift loader's source-of-truth. The original snapshot compared
this with Tenon's then-current “every feature is a plugin” premise. That premise is
historical evidence, not the current selection rule.

That quoted Tenon invariant records the pre-boundary-law position. The current resolution is
semantic-owner based: host SwiftUI calls typed application services DIRECT; plugin, CLI,
palette/keybinding, and agent adapters cross the canonical public boundary. A bundled plugin
gets exactly the same plugin contract and principal rules as any other plugin, while
host-native code does not serialize through a plugin API merely to prove parity.

### 4.6 Plugin-API recommendations (P-series)

- **P1 (high).** Evolve `requirePermission(_:api:)` into a 3-way `allow/deny/ask` gate, starting with `process.exec` + `filesystem.write`. Port muxy's model: a `GrantStore` (rule `{pluginID, capability, match, decision}` in a dot-JSON `.grants.json` in the plugins root, consistent with existing storage), minimal `match` = `any/argvPrefix/pathPrefix`, async prompt + timeout-auto-deny, 5 choices + `blockKind`. Keep invariants #5 and #4. Ref: `ExtensionConsentService.swift`, `ExtensionGrantStore.swift`.
- **P2 (high).** Add an audit log: JSONL `.audit.log` in the plugins root, `{ts, plugin, capability, payloadSummary, decision}`, cap 1MB → trim 256KB. Extend the existing `permissionViolations` snapshot to log *allowed* sensitive calls too. Ref: `ExtensionAuditLog.swift:43-116`.
- **P3 (medium).** storage: add `delete(key)` + `keys()` + quotas (256 / 1MB / 5MB, atomic write), keeping per-plugin isolation. Ref: `ExtensionStorageService.swift:6-93`.
- **P4 (medium, reconciled).** Add `defaultShortcut` to plugin-owned intent presentation
  metadata and register it unassigned on conflict. The palette and keybinding index project
  those intent contracts; no `commands.register` API is introduced. Ref:
  `manifest.schema.json:288-292`.
- **P5 (low).** log: add a per-plugin log ring buffer surfaced in the UI. Ref: `ExtensionLogStore`.

---

## 5. Cross-validated findings (both repos did it ⇒ highest confidence)

| What both kero + muxy do | Meaning for Tenon |
| --- | --- |
| Ship the **same** prebuilt `GhosttyKit.xcframework` (kero wraps it via SPM `.binaryTarget`) | The real axis is abstraction tier, not packaging. Keep the raw C API; mine their wrappers as a feature map. |
| One `ghostty_app_t` singleton; callbacks resolved via `userdata` pointer | Tenon already matches. Confirmed correct. |
| Ghostty action set excludes split/tab/goto-split; the app owns split & tab | Note for §6: Tenon currently routes ghostty bindings into the workspace; muxy owns the keymap instead. |
| Surface is not torn down when hidden (kero parks; muxy reparents) | Tenon achieves this via `SurfacePool` (§3). |
| Layout persistence = recursive Codable snapshot + auto-save per mutation + cwd with path validation | Tenon lacks it; nearly free given the pure-value core. |

---

## 6. Action list for Tenon (priority order)

Terminal, workspace, and host-runtime actions below; the plugin-API actions are the P-series in §4.6.

| # | Action | Verdict | Status | Source |
| --- | --- | --- | --- | --- |
| 1 | Keep + harden the `TerminalSurface` seam; keep everything ghostty-specific behind it, `StubTerminalSurface` covering lifecycle | REUSE | Have it — protect it | both (god-object counter-example) |
| 2 | Verify the pane `NSViewRepresentable` reuses the cached surface's `NSView`; port the reparenting broker only if it doesn't | ADAPT | Foundation correct, one check left | muxy `TerminalPane.swift:227` |
| 3 | Expand the action callback from `title` only → pwd/OSC7, progress/OSC9;4, bell, clipboard-confirm/OSC52, shell-exit — into typed `TerminalSurface` facts + targeted `tenon` events, never by handing plugins the terminal object | ADAPT | Not started | kero ~18 delegates; muxy ~10 actions |
| 4 | Add layout persistence: `SplitNodeSnapshot` indirect-enum Codable + auto-save on mutation + cwd with path validation | ADAPT | Not started | muxy `WorkspaceSnapshot.swift` |
| 5 | `Object.freeze` each namespace of the `tenon` global (block plugin monkey-patching of the API) | ADAPT | Not started | muxy `ExtensionBridgeJS.swift:11` |
| 6 | Isolate the main thread: run each plugin `JSContext` on its own thread/dispatch queue + a watchdog timeout, so one hung plugin can't freeze the host | ADAPT | Not started | muxy in-process `JSExecutor` |
| 7 | Live ghostty config reload (`ghostty_app_update_config`) | ADAPT (later) | Not started | muxy `GhosttyService.swift:143` |
| 8 | Offline/sleep panes (free the surface when hidden under many panes, revive on demand) | ADAPT (later) | Not started | muxy `GhosttyTerminalNSView.swift:503` |
| 9 | One-command Bun/TS release pipeline (notarize → DMG → Sparkle appcast EdDSA → Cloudflare R2, self-hosted, no App Store) | REUSE (at distribution phase) | Not started | kero `scripts/release.ts` |

---

## 7. Historical questions and current resolutions

**(a) Keybinding routing direction — resolved.** The original comparison was: Tenon let
ghostty emit an action toward workspace, while muxy lets registered keys bubble to an app
dispatcher (`GhosttyTerminalNSView.swift:844-869`). Current Tenon keybindings project
authorized plugin-owned intent presentation metadata and dispatch the same canonical intent
as the palette row. Terminal-local input that is not claimed by that index remains terminal
input.

**(b) Plugin-security roadmap — mechanism resolved, policy evolution remains.** Muxy's
runtime consent, persistent grants, and JSONL audit remain useful evidence. They extend the
single intent policy path; they MUST NOT create handwritten capability bridges or alternate
public invocation routes. Section 4.4 records the source evidence and §4.6 P1–P2 the
candidate policy features.

**(c) In-process (Tenon) vs out-of-process (muxy).** muxy isolates crash/CPU/memory better but pays heavily (socket protocol, base64-JSON framing, 8-concurrent-command cap, token handshake, backpressure, `ParentDeathMonitor`). For a pre-alpha, out-of-process is premature. The recommended middle ground is #6 above (per-plugin thread + watchdog): most of the isolation benefit, none of the IPC cost, still in-process.

---

## 8. Explicit non-goals (do NOT copy from muxy)

- **npm + Vite + `package.json` manifest** (a build step). Tenon's zero-build `manifest.json` + `main.js` is better for "an LM writes a working plugin on the first try". muxy only needs a build because its UI is a webview asset.
- **WKWebView for UI.** Keep UI native SwiftUI (VISION: "native macOS"). Open a webview only when a plugin genuinely needs rich UI, and only after the permission/consent machinery exists.
- **Loosening global isolation.** muxy injects `console`/`setTimeout`/`fetch`; Tenon's exact
  frozen `tenon` vocabulary keeps the runtime deterministic and AI-writable.
- **God-objects and product complexity** (tab-stack-per-leaf, polymorphic tabs,
  project/worktree tiers). Keep pane identity and typed content explicit. Plugin-facing
  finite mutations use intents; declarative content uses contributions; surface lifecycle
  stays behind the typed host resource boundary.
- **Private direct workspace reads for plugins.** Public callers use
  `workspace.state.v1`, with audience and authority enforced by policy. Host-native UI uses
  the typed workspace service DIRECT.
- **Splitting the plugin runtime.** muxy needs a separate background host + a `runScript` executor; Tenon's one in-process runtime per plugin already covers both long-lived and one-shot roles. Keep it single.
- **Manual hot-reload.** muxy reloads extensions only on explicit action; Tenon's FSEvents `PluginWatcher` is better. Keep auto-reload.
- **A cross-plugin event bus.** Even muxy forbids plugin→plugin messaging (`emit` is same-extension only). If Tenon ever adds `emit`, keep it same-plugin-scoped.

---

*Method note: findings gathered via repowise (`get_overview`/`get_answer`/`get_context`/`get_symbol`/`get_risk`) against the indexed `kero`, `muxy`, and `tenon` repos, plus targeted raw reads. Every claim carries a `file:line` citation and a confidence label. The `SurfacePool` verification in §3 was read directly from Tenon source.*
