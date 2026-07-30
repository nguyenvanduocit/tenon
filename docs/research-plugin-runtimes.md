# Tessera — Plugin Runtime & Sandboxing Research

> **Note (2026-07-23):** the product this research was commissioned for has since been renamed **Tenon** (see `naming.md`). "Tessera" below refers to this project at the time of writing — distinct from `horang-labs/tessera` analyzed in §5.
>
> **Historical research snapshot — non-normative.** The architecture recommendations
> below preserve the assumptions of the 2026-07-23 investigation, including its
> “every feature is a plugin” premise. Current interaction design MUST follow
> [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).
> Host-native same-owner work is typed DIRECT; finite public plugin/CLI/agent work uses
> canonical intents; events, resources, contributions, and the closed scoped-facility
> allowlist retain their distinct semantics. This research cannot add or override a public
> API.

**Date:** 2026-07-23
**Scope:** Plugin host architecture, libghostty embedding, permission models, and name conflicts for *Tessera*, a macOS-native terminal workspace (Swift + libghostty) in which every feature is a TypeScript plugin, authored to be AI-writable and sandboxed by default.

**Confidence labels used throughout:** `HIGH` (verified by reading source / primary doc), `MEDIUM` (inferred from a credible secondary source or from a pattern in verified code), `LOW` (guess; must be verified before you depend on it).

---

## 1. Muxy Teardown

Muxy is the single closest precedent to Tessera: an MIT-licensed, SwiftUI + libghostty macOS terminal whose stated vision is *"Lightweight terminal that has a rich API for extensions"* (`README.md:12`). Everything in this section was read from a shallow clone of `muxy-app/muxy` at commit `f520289` ("Make Quick Terminal optional and shortcut-only (#938)").

All file citations in this section are relative to the repository root.

### 1.1 How Muxy embeds libghostty

**Headline finding (HIGH): Muxy does not build libghostty. It downloads a prebuilt `GhosttyKit.xcframework` from its own fork of Ghostty.** There is no Zig toolchain anywhere in the Muxy repo, no `build.zig`, and no Zig step in CI.

#### The fork

`scripts/setup.sh:6` pins the source:

```bash
FORK_REPO="muxy-app/ghostty"
```

`setup.sh` then (`scripts/setup.sh:41`) resolves the newest release tag from that fork with `gh release list --repo "$FORK_REPO"`, and downloads two assets:

| Asset | Purpose | Extracted to |
| --- | --- | --- |
| `GhosttyKit.xcframework.tar.gz` | The compiled static library + headers | `GhosttyKit.xcframework/` (repo root) |
| `GhosttyKit-resources.tar.gz` | Shell integration scripts + terminfo | `Muxy/Resources/ghostty/`, `Muxy/Resources/terminfo/` |

Verified against the fork's release feed (`https://api.github.com/repos/muxy-app/ghostty/releases`): seven releases exist, tagged by build date, newest `build-2026-04-29` (published 2026-04-29), described as *"Built from commit 36775cd on 2026-04-29"*. Assets are exactly `GhosttyKit.xcframework.tar.gz` and `GhosttyKit-resources.tar.gz`. **(HIGH)**

The header is not vendored in git — it is copied out of the downloaded xcframework at setup time (`scripts/setup.sh:62-63`):

```bash
echo "==> Syncing ghostty.h from xcframework"
cp "$XCFRAMEWORK_DIR/macos-arm64_x86_64/Headers/ghostty.h" "$PROJECT_ROOT/GhosttyKit/ghostty.h"
```

Confirmed: `GhosttyKit/` in a fresh clone contains only `module.modulemap` and a `GhosttyKit.c` whose entire content is a comment (`GhosttyKit/GhosttyKit.c:1`):

```c
// Placeholder — the actual implementation is in libghostty.a (prebuilt)
```

#### The C interop layer

Muxy's C interop is about as thin as it can be — a SwiftPM system-library-style target with a modulemap (`GhosttyKit/module.modulemap`):

```
module GhosttyKit {
    header "ghostty.h"
    export *
}
```

declared in `Package.swift:49-53` as a plain target with `publicHeadersPath: "."`. The `.c` placeholder exists only to give SwiftPM a compilable source file so the target is valid.

The actual static library is linked with **unsafe linker flags** (`Package.swift:83-86`):

```swift
linkerSettings: [
    .unsafeFlags([
        "GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a",
    ]),
```

Two things worth stealing / worth noting:

1. **The archive is named `ghostty-internal.a`, not `libghostty.a`.** `(MEDIUM)` This strongly suggests the fork emits Ghostty's *internal* (non-public-API) static library — i.e. the same artifact the upstream Ghostty.app target consumes — rather than a stable public `libghostty`. See §2 for why that matters.
2. **`.unsafeFlags` is contagious in SwiftPM.** A package using `.unsafeFlags` cannot be consumed as a versioned dependency by other packages. Muxy gets away with it because `Muxy` is an `executableTarget` at the root, not a published library. Tessera would inherit the same constraint.

Alongside it, `Package.swift:87-101` links the full native surface libghostty needs: `AppKit`, `Metal`, `MetalKit`, `QuartzCore`, `CoreText`, `CoreGraphics`, `IOKit`, `Carbon`, `CoreAudio`, `AVFoundation`, `Speech`, `UserNotifications`, plus `libc++` and `libsqlite3`. **(HIGH)** That list is effectively the dependency bill for embedding libghostty's renderer on macOS.

`.tool-versions` pins `xcode 16.4`, `swiftformat 0.62.1`, `swiftlint 0.57.1` — **no Zig entry**, confirming Zig never runs on a Muxy developer's machine. **(HIGH)**

#### CI never builds Ghostty either

`.github/workflows/checks.yml:49-64` resolves the newest fork tag, caches `GhosttyKit.xcframework`, `GhosttyKit/ghostty.h`, and `Muxy/Resources/ghostty` under a `ghosttykit-${GHOSTTY_TAG}` cache key, then runs the same `Setup GhosttyKit` step. `release.yml:76` and `release-beta.yml:68` do the same. **(HIGH)**

**Lesson for Tessera:** the "build libghostty from source in your app's CI" path is apparently painful enough that the closest comparable project chose instead to (a) fork Ghostty, (b) run a separate build pipeline in the fork that emits an xcframework, and (c) consume that as a binary artifact. Budget for owning a fork + a release pipeline, not for a `zig build` step in your app repo.

#### Which libghostty APIs Muxy actually uses

Extracted by grepping all `ghostty_*` symbols across the Swift sources. This is the **full app/surface/renderer embedding API**, not just terminal-emulation (VT). **(HIGH)**

**Lifecycle / app:**
`ghostty_init`, `ghostty_app_new`, `ghostty_app_tick`, `ghostty_app_update_config`, `ghostty_app_set_color_scheme`, `ghostty_app_t`

**Config:**
`ghostty_config_new`, `ghostty_config_load_file`, `ghostty_config_finalize`, `ghostty_config_clone`, `ghostty_config_get`, `ghostty_config_free`, `ghostty_config_t`, `ghostty_config_color_s`, `ghostty_config_palette_s`

**Surface (the terminal view itself):**
`ghostty_surface_new`, `ghostty_surface_free`, `ghostty_surface_config_new`, `ghostty_surface_update_config`, `ghostty_surface_set_size`, `ghostty_surface_size`, `ghostty_surface_set_content_scale`, `ghostty_surface_set_focus`, `ghostty_surface_set_occlusion`, `ghostty_surface_set_display_id`, `ghostty_surface_set_color_scheme`, `ghostty_surface_set_data_callback`, `ghostty_surface_userdata`, `ghostty_surface_foreground_pid`, `ghostty_surface_needs_confirm_quit`

**Input:**
`ghostty_surface_key`, `ghostty_surface_key_is_binding`, `ghostty_surface_key_translation_mods`, `ghostty_surface_send_input_raw`, `ghostty_surface_mouse_button`, `ghostty_surface_mouse_pos`, `ghostty_surface_mouse_scroll`, `ghostty_surface_preedit`, `ghostty_surface_ime_point`, `ghostty_surface_binding_action`, `ghostty_input_key_s`, `ghostty_input_mods_e`, `ghostty_input_action_e`, `ghostty_input_scroll_mods_t`

**Reading screen contents (this is what powers the extension `panes.readScreen` verb):**
`ghostty_surface_read_cells`, `ghostty_surface_free_cells`, `ghostty_surface_read_selection`, `ghostty_surface_has_selection`, `ghostty_surface_text`, `ghostty_surface_free_text`, `ghostty_cells_s`, `ghostty_text_s`, `ghostty_surface_quicklook_word`, `ghostty_surface_quicklook_font`

**Clipboard:**
`ghostty_surface_complete_clipboard_request`, `ghostty_clipboard_content_s`, `ghostty_clipboard_e`

**Host callbacks (the "actions" libghostty asks the embedder to perform):**
`ghostty_runtime_config_s`, `ghostty_action_s`, `ghostty_action_set_title_s`, `ghostty_action_pwd_s`, `ghostty_action_open_url_s`, `ghostty_action_desktop_notification_s`, `ghostty_action_mouse_over_link_s`, `ghostty_action_progress_report_s`, `ghostty_action_scrollbar_s`, `ghostty_action_start_search_s`, `ghostty_action_search_selected_s`, `ghostty_action_search_total_s`, `ghostty_action_secure_input_e`, `ghostty_target_s`, `ghostty_platform_u`, `ghostty_platform_macos_s`, `ghostty_env_var_s`, `ghostty_color_scheme_e`

Note `ghostty_action_scrollbar_s`, `ghostty_action_start_search_s`, `ghostty_action_search_selected_s`, `ghostty_action_search_total_s` — scrollbar and in-terminal search actions. **(MEDIUM)** These look like fork-specific additions or very recent upstream APIs; they are a plausible reason Muxy maintains a fork rather than consuming upstream artifacts.

### 1.2 The Muxy extension system, end to end

#### The big picture

`docs/extensions/overview.md:9-14` states the architecture precisely: `ExtensionStore` scans the extensions directory, loads enabled extensions, and gives each **two surfaces**:

- **Declared UI** — panels, tabs, popovers, topbar/status-bar items, sidebars render **in-process as WKWebViews**, talking to Muxy through an injected `window.muxy` bridge. No subprocess.
- **Background script** — if the manifest declares `muxy.background`, Muxy runs it in a **separate bundled host process (`MuxyExtensionHost`)** built around **JavaScriptCore**.

There is also a third, lesser surface: a `runScript` palette command that gets a short-lived **in-process JavaScriptCore** context (`docs/extensions/scripts.md:3`).

So: **three execution surfaces, two JS engines (WKWebView's JS and JavaScriptCore), one shared API shape.**

#### Manifest format

Manifests are **`package.json` itself** — not a separate file. `docs/extensions/manifest.md:5`: identity (`name`, `version`) lives at the npm top level; every Muxy-specific field lives under a `muxy` key.

Fields under `muxy` (`docs/extensions/manifest.md:48-64`): `description`, `background`, `permissions`, `events`, `commands`, `tabTypes`, `fileOpeners`, `panels`, `popovers`, `sidebar`, `topbarItems`, `statusBarItems`, `settings`, `remoteMethods`, `marketplace`.

Example (`docs/extensions/manifest.md:13-32`):

```json
{
  "name": "hello",
  "version": "0.1.0",
  "type": "module",
  "scripts": { "dev": "vite", "build": "vite build && node scripts/copy-manifest.mjs" },
  "muxy": {
    "$schema": "https://raw.githubusercontent.com/muxy-app/muxy/main/docs/extensions/schema/manifest.schema.json",
    "description": "Subscribes to events and exposes a palette command",
    "background": "background.js",
    "permissions": ["panes:read", "tabs:read", "notifications:write"],
    "events": ["pane.created", "tab.focused", "notification.posted"],
    "commands": [{ "id": "ping", "title": "Hello: Ping", "subtitle": "Demo command" }]
  }
}
```

A **JSON Schema (draft-07, 419 lines)** ships at `docs/extensions/schema/manifest.schema.json`, `$id: https://muxy.app/schema/manifest.schema.json`. Its description is explicit about the duplication risk it creates:

> "Mirror of the Swift PackageManifest/ExtensionManifest loader in muxy-app/muxy — source of truth is MuxyExtension.load/validate; this schema is the marketplace mirror, **backed by an app contract test**."

**Worth stealing (HIGH):** publishing a JSON Schema whose drift from the Swift loader is caught by a contract test. Editors get autocomplete, the marketplace gets validation, and the two cannot silently diverge. Note it uses `additionalProperties: false` on the `muxy` object — typos are hard errors, not silent no-ops. That is a significant AI-writability win.

#### How npm + Vite extensions are loaded at startup

The build/ship/load contract (`docs/extensions/manifest.md:7-11`, `overview.md:27-37`):

1. Extensions are npm + Vite projects. `npm run build` emits `dist/`.
2. **The publish pipeline ships only `dist/`.** The app installs and reads from `dist/`.
3. Therefore **the `build` script must copy `package.json` into `dist/`** — Vite does not. The canonical script is `"build": "vite build && node scripts/copy-manifest.mjs"`.
4. Installed layout is `~/.config/muxy/extensions/<name>/` containing the built output with `package.json` at its root.

`copy-manifest.mjs` in the starter kit is 8 lines (`Muxy/Resources/starter-kits/vanilla/scripts/copy-manifest.mjs`):

```js
import { copyFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "..");
const dist = resolve(root, "dist");
await mkdir(dist, { recursive: true });
await copyFile(resolve(root, "package.json"), resolve(dist, "package.json"));
```

**This is a design smell Tessera should avoid (HIGH).** The docs admit it themselves (`docs/extensions/manifest.md:9`): because **Load Unpacked** in dev falls back to the root `package.json`, a missing copy step *works locally and fails only at publish time*. Muxy patches this with documentation, a starter kit, and a warning in three separate places. The root cause is that the manifest lives in a file the bundler does not treat as an asset. Tessera should either (a) have the build tool emit the manifest, or (b) read the manifest from the package root rather than the build output.

Loader behaviour (`docs/extensions/manifest.md:84`): `ExtensionStore` walks `~/.config/muxy/extensions/*/package.json` at app start; for each it decodes top-level `name`/`version` and the `muxy` object, validates `name` against the allowed character set **and against the directory name**, verifies `background` resolves inside the build output, and refuses duplicate names. Failures surface in Settings → Extensions → Load Errors and are **not retried** until manual reload or restart.

**Extensions are disabled by default after loading** and must be explicitly enabled in Settings (`docs/extensions/manifest.md:66`), persisted to `UserDefaults` under `muxy.ext.enabled.<extension-id>`. **(HIGH)** Good default; worth stealing.

**TypeScript status (HIGH): Muxy's extension system has no TypeScript story at all.** A repo-wide search found **zero `.d.ts` files** and no `@muxy/*` types package. Extensions can use TS only because Vite happens to compile it; there are no type definitions for the `window.muxy` API. Authors work against Markdown docs and a JSON Schema. **This is the single biggest opportunity for Tessera** — see §3 and §6.

#### WKWebView-hosted extension UI

Configuration is built per-surface in `Muxy/Views/Extensions/ExtensionWebView.swift:29-72`.

**Asset loading uses a custom URL scheme, not `file://`** (`ExtensionWebView.swift:30-33`):

```swift
config.setURLSchemeHandler(
    ExtensionAssetSchemeHandler(extensionID: muxyExtension.id, directory: muxyExtension.directory),
    forURLScheme: ExtensionAssetSchemeHandler.scheme
)
```

The scheme is `muxy-ext` (`ExtensionAssetSchemeHandler.swift`), and the handler enforces three things worth copying **(HIGH)**:

1. **Origin isolation per extension** — the request must satisfy `url.host == extensionID`. Each extension therefore gets its own web origin (`muxy-ext://<extension-id>/`), so cookies, `localStorage`, and same-origin policy separate extensions from each other for free.
2. **Path traversal defence** — the resolved path is standardized and symlink-resolved, then checked: `resolved.path == base.path || resolved.path.hasPrefix(base.path + "/")`. Symlinks out of the extension directory are rejected.
3. **Resource caps** — `maxAssetBytes = 64 MiB`, and responses are served `Cache-Control: no-store`.

**The bridge is a `WKScriptMessageHandlerWithReply` in the page content world** (`ExtensionWebView.swift:46-50`):

```swift
userContent.addScriptMessageHandler(
    bridge,
    contentWorld: .page,
    name: ExtensionWebBridge.messageHandlerName   // "muxy"
)
```

**Weakness worth noting (HIGH):** `contentWorld: .page` means the bridge lives in the same JS world as extension page code. Any script the page loads — including a compromised npm dependency bundled by Vite — can read, wrap, or monkey-patch `window.muxy` and the underlying `window.webkit.messageHandlers.muxy`. WebKit offers `WKContentWorld.defaultClient` / named worlds precisely to prevent this. **Tessera should install its bridge in an isolated content world and expose only a frozen, minimal proxy to the page world.**

The injected bridge script is generated in Swift and installed as a `WKUserScript` at `.atDocumentStart`, `forMainFrameOnly: true` (`ExtensionWebView.swift:122-134`). The page-side API is fully **promise-based** (`ExtensionWebBridge.swift:22-29`):

```js
const send = async (verb, args) => {
    const requestID = String(nextID++);
    const reply = await handler.postMessage({ verb, args: args ?? {}, requestID });
    if (reply && reply.ok) return reply.value;
    throw new Error(reply && reply.error ? String(reply.error) : 'extension api error');
};
```

Theming is injected as CSS custom properties on `document.documentElement` and pushed live on theme change (`ExtensionWebBridge.swift:58-75`) — `--muxy-background`, `--muxy-foreground`, `--muxy-surface`, `--muxy-border`, `--muxy-hover`, `--muxy-accent`, etc., plus a `muxy.onThemeChange` JS callback. **Worth stealing (HIGH):** it makes "looks native" the default rather than an achievement.

Teardown is explicit (`ExtensionWebView.swift:80-90`): drop event subscriptions, unregister from the surface registry, nil the delegates, `removeAllScriptMessageHandlers()`, `removeAllUserScripts()`.

#### Background scripts in a separate process

This is the most interesting part of Muxy's design.

**The host is a standalone executable target that links JavaScriptCore** (`Package.swift:24-34`):

```swift
.executableTarget(
    name: "MuxyExtensionHost",
    dependencies: ["MuxyShared"],
    path: "MuxyExtensionHost",
    linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("JavaScriptCore"),
    ]
)
```

**It is JavaScriptCore, not Node.** `MuxyExtensionHost/main.swift:40-42`:

```swift
guard let context = JSContext() else {
    fail("could not create JSContext")
}
```

**Spawn** (`Muxy/Services/Extensions/ExtensionStore.swift:903-916`):

```swift
let process = Process()
process.executableURL = hostURL
process.arguments = [backgroundScriptURL.path]
process.currentDirectoryURL = ext.directory

let token = Self.generateToken()
tokens[ext.id] = token

var environment = ProcessInfo.processInfo.environment
environment["MUXY_SOCKET_PATH"] = NotificationSocketServer.socketPath
environment["MUXY_EXTENSION_ID"] = ext.id
environment["MUXY_EXTENSION_TOKEN"] = token
process.environment = environment
```

So: one process per extension-with-a-background-script, given a **per-launch random capability token**, the socket path, and its extension ID. stdout/stderr are redirected to a per-extension log file (`ExtensionStore.swift:918-923`).

**Transport is a Unix domain socket with a line-oriented, pipe-delimited text protocol.** `MuxyExtensionHost/HostSocketClient.swift:53-77` opens `socket(AF_UNIX, SOCK_STREAM, 0)` and connects, retrying up to 15 times at 100 ms intervals.

**Handshake** (`main.swift:74`):

```swift
let reply = try client.sendAndWaitReply("identify|\(extensionID)|\(token)")
```

The app rejects unknown extensions; the client retries on the transient `error:unknown extension` reply (`HostSocketClient.swift:30-32`).

**Wire format.** Requests are `verb|<base64-json>`; replies are either a base64 JSON payload or a string beginning `error:` (`HostBridge.swift:173-192`). Inbound pushes are demultiplexed by line prefix (`HostSocketClient.swift:177-203`): `event|`, the extension-local-event head, `invoke|`, modal-result, modal-query — anything else is treated as the pending reply.

**Critical design consequence (HIGH): the background API is synchronous and blocking.** `HostBridge.dispatch` calls `client.sendAndWaitReply(...)`, which blocks on an `NSCondition` until the reply arrives (`HostSocketClient.swift:131-149`). The generated JS then returns the value directly rather than a promise (`ExtensionBridgeJS.swift:16-20`):

```js
const dispatch = (verb, args) => {
    const reply = __muxyDispatch(verb, args || {});
    if (reply && reply.ok) return reply.value;
    throw new Error((reply && reply.error) || 'extension api error');
};
```

So `muxy.git.status()` returns a value in `background.js` and a `Promise` in a webview page. **This is a genuine AI-writability hazard** and Muxy's own docs have to keep warning about it (`docs/extensions/storage.md:15`: *"On webview pages the methods return a `Promise` (use `await`); in `runScript` and background scripts they are synchronous"*). An LLM that has seen the webview examples will write `await muxy.storage.get(...)` in a background script — which happens to work by accident (`await` on a non-promise), but the reverse mistake (dropping `await` on a page) silently yields a `Promise` object. **Tessera should make every API async everywhere.**

**JavaScriptCore is a bare engine — Muxy has to polyfill the runtime itself.** `HostBridge.installTimers()` (`HostBridge.swift:49-66`) implements timers over GCD:

```swift
context.evaluateScript("""
globalThis.setTimeout = (fn, delay) => __muxySetTimer(fn, Number(delay) || 0, false);
globalThis.setInterval = (fn, delay) => __muxySetTimer(fn, Number(delay) || 0, true);
globalThis.clearTimeout = (id) => __muxyClearTimer(Number(id) || 0);
globalThis.clearInterval = (id) => __muxyClearTimer(Number(id) || 0);
""")
```

`console.log/warn/error` is likewise hand-built and routed to stderr (`ExtensionBridgeJS.swift:281-296`, `HostBridge.swift:26-29`). **There is no `fetch`, no module loader, no `require`/`import` at runtime** — hence the docs' instruction that background scripts must shell out via `muxy.exec(['curl', …])` for network access (`SKILL.md`). Vite must bundle everything to a single file.

**Lifetime is tied to the parent.** `MuxyExtensionHost/ParentDeathMonitor.swift` uses `DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit)` and exits on parent death, with a `getppid() > 1` re-parenting check both before and after installing the handler. On the app side, `stopProcess` kills the whole process group with `killpg(target, SIGTERM)` (`ExtensionStore.swift:986-989`), so `exec`'d grandchildren die too. **Worth stealing (HIGH)** — orphaned plugin processes are a classic failure mode.

Crash handling: a `terminationHandler` marks the extension stopped and surfaces the error in Settings; there is crash-restart logic with an attempt counter and a reset timer (`ExtensionStore.swift:925-940`, `970-975`).

#### One API generator, two surfaces

`MuxyShared/ExtensionBridgeJS.swift` (675 lines) generates the `muxy` global for the **JavaScriptCore** surfaces, parameterized by an enum:

```swift
public enum Surface {
    case inProcess    // runScript palette commands
    case background   // background.js
}
```

Blocks are composed conditionally (`ExtensionBridgeJS.swift:255-262`): `workspaceBlock` and `filesBlock` only for `.inProcess`; `eventsBlock`, `remoteBlock`, and a cut-down `backgroundTabsBlock` only for `.background`; `gitBlock`, `ghBlock`, `agentsBlock` for both.

Everything is then **frozen** (`ExtensionBridgeJS.swift:263-279`): `Object.freeze` on each namespace and on `muxy` itself. **(HIGH)** Cheap hardening against one part of a plugin tampering with the API another part uses.

`ExtensionWebBridge.swift` is a *separate, third* generator for the WKWebView surface. **Design note (MEDIUM):** two generators for one conceptual API is exactly how the sync/async split and the capability differences between surfaces crept in. Tessera should generate one API surface from one declarative description — and generate the TypeScript `.d.ts` from the same description.

#### The API surface (what a plugin can actually do)

| Namespace | Capabilities | Available on |
| --- | --- | --- |
| `events` | `subscribe` / `unsubscribe` / `emit` | background, webviews |
| `exec` / `execAsync` | shell subprocess, stdout/stderr/exitCode capture; `execAsync` returns `{ id, result, cancel() }` | background (`exec`), runScript, webviews |
| `git` | `status`, `diff`, `repoInfo`, `log`, `branches`, `currentBranch`, `aheadBehind`, `init`, `stage`, `unstage`, `discard`, `commit`, `push`, `pull`, `checkout`, `cherryPick`, `revert`, `branch.*`, `tag.create`, `pr.*` (info/number/diff/list/create/merge/close/checkout/checkoutWorktree), `worktree.*` | all |
| `files` | `list`, `read`, `stat`, `write`, `mkdir`, `rename`, `move`, `delete` — **sandboxed to the active worktree root**, paths returned relative | webviews, runScript |
| `http` | `fetch(url, {method, headers, body, timeoutMs})` — native-side, so **not CORS-blocked** | webviews only |
| `storage` | `get`/`set`/`delete`/`keys`, per-extension namespace, key ≤256 chars, value ≤1 MB, store ≤5 MB | all |
| `panes` | `list`, `send`, `sendKeys`, `readScreen`, `close`, `rename` | webviews, runScript |
| `tabs` | `list`, `switchTo`, `new`, `next`, `previous`, `open`, `setTitle`, `setIcon` | webviews, runScript (`open` only on background) |
| `browser` | ~40 verbs — full Playwright-like automation of the built-in browser: `open`, `navigate`, `eval`, `click`, `type`, `fill`, `press`, `select`, `hover`, `waitFor`, `snapshot`, `screenshot`, `storage.*`, `cookies.*` | all |
| `projects` / `worktrees` | list / switch / add / rename / setColor / setIcon / reorder / delete | webviews, runScript |
| `modal` | native searchable picker (`open`, streaming `items(emit)`, `onQuery`) + `openWebview` for custom HTML modals | all |
| `dialog` | `confirm`, `alert`, `prompt`, `pickFolder` — native sheets, **no permission required** | all |
| `panels` / `popover` / `topbar` / `statusbar` | open/toggle/close, live icon+text updates | all |
| `lifecycle` | `onBeforeClose` veto + `close()` | webviews |
| `remote` | `handle(action, handler)` — serve methods to the companion mobile app | background |
| `shortcuts` | runtime `register`/`unregister`/`list` | background |
| `agents` / `gh` | `agents.list()` (AI agent status per worktree), `gh.user()` | all |

**Events** (`docs/extensions/events.md:56-77`): `pane.created/closed/focused`, `tab.created/updated/closed/focused`, `panel.opened/closed`, `popover.opened/closed`, `project.switched`, `projects.changed`, `worktree.switched`, `worktree.headChanged`, `notification.posted`, `agent.status`, `file.changed`, plus auto-allowed `command.<id>` and same-extension `extension.<name>`.

Two things stand out:

- **`agent.status`** reports AI-coding-agent lifecycle (`working` > `waiting` > `idle`) per worktree, driven by each CLI's hooks, with a per-provider capability matrix documented (`events.md:85-95`: Claude Code, Droid, Grok, OpenCode, Codex full; Pi and Cursor lack `waiting`). **(HIGH)** Strong evidence that "the terminal knows what the agent is doing" is a real product surface.
- **`worktree.headChanged`** is implemented by watching `.git/HEAD`, explicitly *"no polling"* (`events.md:97`), and `file.changed` is debounced ~0.3 s and filters `.git/` noise. Good push-not-poll discipline.

**Palette commands** support four action kinds: `event`, `openTab`, `togglePanel`/`openPopover`, and `runScript` — each with a declared `requiredPermission` (`Tests/MuxyTests/Models/Extension/ExtensionManifestTests.swift:1167-1171`). Commands can declare a `defaultShortcut`.

#### Permission model

**Two enforcement layers** (`docs/extensions/permissions.md:3-6`):

1. **Manifest permissions** — declared in `muxy.permissions`. Calling a verb without its permission returns `error:permission denied (<perm>)`.
2. **Runtime consent** — dangerous verbs prompt the user *even when the manifest permission is granted*.

Permission strings are coarse verb groups: `panes:read/write`, `tabs:read/write`, `browser:read/write`, `projects:read/write/delete`, `worktrees:read/write`, `agents:read`, `git:read/write`, `gh:read`, `files:read/write`, `storage:read/write`, `notifications:write`, `panels:write`, `commands:run-script`, `commands:exec`, `remote:serve`, `shortcuts:register`.

The docs are refreshingly honest about the tradeoff (`permissions.md:89`):

> "Permissions are coarse (verb groups, not individual verbs) on purpose while the API is in flux. Expect the list to expand and possibly split (e.g. `panes:send` vs `panes:close`) once a dedicated extension API layer lands."

**Enforcement is centralized at the socket/bridge boundary**, not sprinkled through the codebase. The check sites are:

- `Muxy/Services/Socket/SocketCommandHandler.swift:20-23` — the background-process path
- `Muxy/Services/Extensions/ExtensionBridgeHandler.swift:264` — the WKWebView path
- `Muxy/Services/MuxyAPI/MuxyAPIDispatcher.swift:70` — the shared dispatcher
- `Muxy/Services/Socket/NotificationSocketServer.swift:165-166`

```swift
guard entry.permissions.contains(required) else {
    return "permission denied (\(required.rawValue))"
}
```

**Worth stealing (HIGH):** one `requiredPermissions(command:parts:)` function (`SocketCommandHandler.swift:896`) maps a verb + its arguments to the permissions it needs. Notably it is *argument-sensitive* — a `split` request that carries a startup command additionally requires `commands:exec` (verified by `Tests/.../SocketCommandHandlerTests.swift:53-65`).

**Runtime consent verbs** (`permissions.md:43-55`): `exec`, `panes.send`, `panes.sendKeys`, `panes.readScreen`, `tabs.runCommand`, `tabs.openForeign`, remote method invocation, all `git.*` writes, all `files.*` writes, `projects.delete`, `http.fetch`.

The consent prompt shows extension + verb + **the literal payload** (full argv, the keystroke, the pane id) and offers four outcomes: *Allow & remember*, *Allow*, *Cancel*, *Deny & remember*, plus a "Block all … from this extension" checkbox that writes a `blocked` rule superseding all others for that verb. **An unanswered prompt is denied after 60 seconds** (`permissions.md:66`). **(HIGH)** All four behaviours are worth copying.

The remembered-rule model is well designed (`Muxy/Services/Extensions/ExtensionGrantStore.swift`):

```swift
enum ExtensionGrantDecision: String { case allow, deny, blocked }

enum ExtensionGrantMatch: Codable, Equatable {
    case any
    case argvExact([String])
    case argvPrefix([String])
    case shellExact(String)
    case paneEquals(String)
    case foreignTabEquals(targetExtensionID: String, tabTypeID: String)
    case remoteActionEquals(String)
    case gitOperationEquals(String)
    case fileOperationEquals(String)
    case hostEquals(String)
    case projectNameEquals(String)
}
```

Default remember-patterns (`permissions.md:72-78`): `exec` remembers only the **base command** as an `argvPrefix` (allowing `git status` also allows other `git` subcommands — an explicitly documented widening); `http.fetch` remembers `hostEquals` (allowing `api.github.com` grants nothing for `example.com`); git and file writes remember **per operation** (allowing `push` does not allow `discard`). Deny rules beat allow rules; more specific patterns beat less specific ones.

Rules live in `~/Library/Application Support/Muxy/extension-grants.json`, explicitly *"Muxy-owned — extensions cannot self-grant"*.

**Every gated call is audited.** `Muxy/Services/Extensions/ExtensionAuditLog.swift`:

```swift
struct ExtensionAuditEntry: Codable {
    let timestamp: Date
    let extensionID: String
    let verb: String
    let payloadSummary: String
    let decision: String
    let ruleID: String?
    let source: String
}
```

JSONL to `~/Library/Application Support/Muxy/extension-audit.log`, rolling (1 MiB cap, trimmed to 256 KiB), surfaced via *Settings → Extensions → Permissions → Reveal Audit Log*. **(HIGH)** Worth stealing outright.

**Other enforcement details:**

- **Subscription allowlist** — an extension may subscribe only to events declared in its manifest `events` array, its own `command.<id>` events, or same-extension `extension.*` events. Some events additionally require a read permission (`projects.changed` → `projects:read`, `agent.status` → `agents:read`, `file.changed` → `files:read`) (`events.md:39-42`).
- **Extension-local events cannot cross extension boundaries** and are capped at 64 KiB JSON (`events.md:52`, `ExtensionLocalEvent.maxPayloadBytes`).
- **`http.fetch` SSRF defence** (`ExtensionHTTPClient.swift`): scheme restricted to http/https; forbidden headers `host`, `content-length`, `connection`; host **DNS-resolved and checked against private/loopback/link-local ranges** for both IPv4 and IPv6, including `localhost` and `*.localhost`; and an `HTTPRedirectGuard: URLSessionTaskDelegate` re-applies the check on every redirect. **(HIGH)** The redirect guard is the part most implementations forget.
- **`files.*` is path-sandboxed** to the active worktree root, with relative paths returned.
- **Marketplace installs are integrity-checked** (`ExtensionMarketplaceService.swift`): download URL must pass `isTrustedDownload(url)`, and the payload's SHA-256 must equal the registry's `sha256` field (line 328) before unpacking. Note extensions themselves are **not** code-signed — trust is anchored in the registry, not in the author.

**The most important negative finding (HIGH): there is no OS-level sandbox.**

`Muxy/Muxy.entitlements` and `MuxyExtensionHost/MuxyExtensionHost.entitlements` both **lack `com.apple.security.app-sandbox` entirely**. The extension host's entitlements are:

```xml
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

That is: JIT enabled, unsigned executable memory allowed, library validation disabled, and **no sandbox**. A background script runs as a normal user process with the user's full ambient authority. `muxy.exec` is permission-gated at the bridge, but nothing at the OS level stops JS-reachable code paths from touching the filesystem or network if a bridge check is ever missed or bypassed.

**For Tessera this is the decisive lesson.** Muxy's model — deny-by-default capability checks at a single Swift boundary, plus runtime consent, plus audit — is genuinely good *application-level* design and should be copied. But it is a **single layer**. For AI-generated plugin code, a bridge-layer bug is a full compromise. Tessera should keep Muxy's boundary design and add an OS-level sandbox underneath it as defence in depth.

#### AI-writability: what Muxy already does

Muxy has clearly thought about agents writing extensions:

- **A bundled `muxy-extension` Agent Skill** (`Muxy/Resources/skills/muxy-extension/SKILL.md`, 127 lines) is scaffolded into `.claude/skills/` and `.agents/skills/` of every new extension, installable elsewhere via `npx skills add github.com/muxy-app/muxy/tree/main/Muxy/Resources/skills/muxy-extension`.
- **An LLM-oriented docs index at `https://muxy.app/llms.txt`**, with `/plain` appended to any docs URL returning raw Markdown (e.g. `https://muxy.app/docs/extensions/manifest/plain`).
- **A self-updating skill**: the starter kit's `npm run update-skill` re-fetches `SKILL.md` from `main` into both harness directories.
- **The skill separates concerns deliberately** — it is the *guidance* layer (which surface to pick, theming, sizing scale), and defers mechanics to the docs. It carries a design system in prose: a fixed spacing scale (`2·4·6·8·10·12·16·20·24·32`), font sizes (`12` body, `14` titles), icon weights (600), radii (`4` chips / `6` buttons / `8` cards), and a hard rule of "no hex literals for chrome, use `var(--muxy-…)`".
- **A second skill, `muxy-cli`**, lets agents drive the workspace from a shell.

**What is missing, and what Tessera should do differently (HIGH):**

| Muxy | Tessera should |
| --- | --- |
| No `.d.ts`, no types package | Ship `@tessera/api` with full types generated from the same source as the runtime |
| Sync on background, async on pages | One async API everywhere |
| Manifest correctness depends on a hand-written copy step | Manifest emitted by the build tool, or read from package root |
| Three separate hand-written JS bridge generators | One declarative API description → runtime + `.d.ts` + JSON Schema + docs |
| Prose docs + JSON Schema as the contract | Types as the primary contract; schema and docs generated |

The schema's `additionalProperties: false` and the directory-name-must-equal-package-name rule are both good AI guardrails already — keep those.

#### Summary: the Muxy pattern in one paragraph

Manifest is `package.json` with a namespaced key, validated by a published JSON Schema kept honest by a contract test. UI is WKWebView on a per-extension custom URL scheme with theme variables injected. Background logic is JavaScriptCore in a **separate process per extension**, connected over a Unix socket with a token handshake and a line protocol, killed via process group when the app exits. Every capability is declared in the manifest, checked at exactly one Swift boundary by an argument-sensitive permission function, and dangerous verbs additionally prompt the user with the literal payload and a four-way remember/deny model persisted to an app-owned file, with every decision written to a rolling audit log. Extensions are disabled by default, integrity-checked by SHA-256 on install, and origin-isolated from each other. There is no OS sandbox anywhere.

---

## 2. libghostty Status as of Mid-2026

### 2.1 Bottom line

| Thing | Status (2026-07-23) |
| --- | --- |
| **libghostty-vt** (VT parsing, terminal state, render-state production) | **Publicly consumable** in Zig and C — but **no tagged release** and the API is explicitly declared unstable |
| **Full libghostty** (app / surface / Metal renderer embedding) | **Officially internal-only.** Upstream names the artifact `ghostty-internal` and its pkg-config `Description` reads *"not for external use"*. In practice, many shipping apps embed it anyway |
| Latest Ghostty app release | **1.3.1** (2026-03-13); `main` is `1.3.2-dev` |
| Required Zig | **0.16.0** (`minimum_zig_version` in `build.zig.zon`) |
| Most recent libghostty announcement | **Ghostty 1.3.0 release notes, 2026-03-09** — nothing newer found |

### 2.2 Is the full libghostty consumable by third parties?

**Officially no; practically yes, unsupported. (HIGH)**

The build system says it outright. `src/build/GhosttyLib.zig` emits `ghostty-internal.a` / `ghostty-internal.so` (and `ghostty-internal-static.lib` / `.dll` on Windows), with pkg-config files whose `Description` fields read *"Ghostty internal library (not for external use)"*.

**This independently confirms the Muxy finding in §1.1**: Muxy's `Package.swift:85` links `GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a`. Muxy is consuming Ghostty's internal library, exactly as the artifact name suggested.

`include/ghostty.h` (~36 KB — the full app/surface/renderer C API) opens with:

> "The documentation for the embedding API is only within the Zig source files that define the implementations. **This isn't meant to be a general purpose embedding API (yet)**"

and carries an explicit hazard note about APIs *"I'd like to get rid of eventually but are still needed for now. **Don't use these unless you know what you're doing.**"*

`ghostty.org/docs/about` states: *"As of the initial public release, `libghostty` is not yet a stable API and has not been released as a standalone, stable library."*

**Yet the full library is widely embedded. (HIGH)** The path is `zig build -Demit-xcframework` → `Frameworks/GhosttyKit.xcframework` → `import GhosttyKit` in Swift, giving you surface lifecycle, the Metal renderer, font shaping, the config system, and input handling. Third parties redistribute it:

- **`Lakr233/libghostty-spm`** — a SwiftPM binary target advertising the full feature set. It pins an upstream commit in a `Ghostty.ref` file and applies local patches from `Patches/ghostty/`.
- **`briannadoubt/GhosttyKit`** — another SwiftPM wrapper around the macOS XCFramework.

Upstream GitHub Discussions in mid-2026 carry active full-API embedder traffic, and maintainers engage with it despite its nominal internal status — e.g. *"libghostty embedded: `ghostty_surface_new` fails while display is asleep"* (2026-07-08), *"libghostty: IOSurfaceLayer display callback not cleared on renderer deinit"* (2026-07-08, a potential use-after-free), and answered requests to expose `max_scrollback` updates (2026-05-22) and scrollback deltas for persistent-document renderers (2026-06-21).

**Platform skew (MEDIUM→HIGH):** the full library is Mac-centric, especially rendering. There is **no upstream DX12/Windows renderer** — that work lives in the `deblasis/wintty` soft fork, whose README notes 17 PRs were merged upstream but that Windows-specific renderer changes stayed downstream because *"upstream doesn't have capacity to maintain Windows-specific changes right now."* Irrelevant for a macOS-only Tessera, but it tells you where maintainer attention is.

### 2.3 What libghostty-vt is

**Scope (HIGH):** a zero-dependency (no libc required with `-Dsimd=false`) C + Zig library covering escape-sequence parsing, terminal state, cursor/styles, scrollback, line wrapping, reflow-on-resize, and render-state production for *your own* renderer. Targets macOS, Linux, Windows, and WebAssembly.

**Headers (HIGH):** umbrella header `include/ghostty/vt.h`, including 24+ subheaders under `include/ghostty/vt/`: `terminal.h` (~57 KB), `selection.h` (~43 KB), `kitty_graphics.h` (~30 KB), `render.h` (~30 KB), `color.h` (~15 KB), plus `osc.h`, `sgr.h`, `key.h`, `mouse.h`, `paste.h`, `screen.h`, `style.h`, `unicode.h`, `point.h`, `grid_ref.h`, `allocator.h`, `wasm.h` and others.

The Zig module `ghostty-vt` landed in PR #8840 (merged 2025-09-22), which also added `example/zig-vt` and the `-Dsimd` flag.

**Release status (HIGH): there is none.** `ghostty-org/ghostty` has exactly 13 tags — `v1.0.0` … `v1.3.1` plus `tip` — all for Ghostty-the-app. There is **no separate libghostty repo** in the org. `include/ghostty/vt.h` says *"This is an incomplete, work-in-progress API. It is not yet stable and is definitely going to change."* The live Doxygen site adds: *"Breaking changes are expected in future versions. Use with caution in production code."*

> ⚠️ **A claim circulating that is unverified and likely false:** that "libghostty-vt 1.0.0 was released on 2026-05-30". Its only source is a LobeHub skills-marketplace page that returns HTTP 403; no primary source corroborates it and it contradicts the current header and live docs. **Do not rely on it. (LOW)**

**Third-party bindings (HIGH)** — none official: Rust `libghostty-vt-sys` (0.2.1, 2026-07-18, ~10.8k downloads, repo `Uzaaft/libghostty-rs`); Go `mitchellh/go-libghostty`; npm `ghostty-web` (Coder — WASM VT parser with an xterm.js-compatible API, ~400 KB bundle) and `coder/libghostty-vt-node`; Swift `Lakr233/libghostty-spm` and `briannadoubt/GhosttyKit` (both the **full** library, not vt); plus .NET, Dart, Python, Elixir and others catalogued in `Uzaaft/awesome-libghostty` (~182 projects).

### 2.4 Build requirements

**Zig 0.16.0 (HIGH)** — from `build.zig.zon` on `main`: `.version = "1.3.2-dev"`, `.minimum_zig_version = "0.16.0"`. `HACKING.md` additionally requires **Xcode 26 + the macOS 26 SDK** for main-branch development on macOS (you need not *run* macOS 26).

**The flag is `-Demit-lib-vt`, not `-Demit-lib` (HIGH).** From `src/build/Config.zig` the emit options are `-Demit-lib-vt`, `-Demit-xcframework`, `-Demit-macos-app`, `-Demit-exe`, `-Demit-test-exe`, `-Demit-bench`, `-Demit-helpgen`, `-Demit-docs`, `-Demit-terminfo`, `-Demit-termcap`, `-Demit-themes`, `-Demit-webdata`, `-Demit-unicode-table-gen`.

A working real-world invocation (from `go-libghostty`):

```sh
zig build -Demit-lib-vt -Dtarget=x86_64-linux-gnu --prefix /tmp/ghostty-linux-amd64
```

**Artifacts from `-Demit-lib-vt`** (`src/build/GhosttyLibVt.zig`): static `libghostty-vt.a` with vendored SIMD archives combined into one fat archive *"so consumers only need to link one file"*; a shared `ghostty-vt`; headers into `include/ghostty/`; pkg-config `libghostty-vt.pc` and `libghostty-vt-static.pc`. On Darwin, `-Demit-lib-vt` + `-Demit-xcframework` also produces a **vt xcframework**.

**Artifacts from the full library** (`src/build/GhosttyLib.zig`): `ghostty-internal.a` / `.so` / `.dll`, header `ghostty.h`, and `ghostty-internal{,-static}.pc`. On macOS, `-Demit-xcframework` wraps this into **`Frameworks/GhosttyKit.xcframework`** — universal, linked "Do Not Embed", `import GhosttyKit` in Swift, plus Carbon + Metal linker flags and a resource bundle for terminfo and shell integration. **This is precisely the artifact Muxy's fork publishes** (§1.1).

Reference integrations: **`ghostty-org/ghostling`** — a single-C-file minimum-viable terminal on libghostty-vt, CMake + Ninja (note: debug builds are documented as *"VERY SLOW"*) — and `example/` in the main repo.

### 2.5 API stability posture

**There are no guarantees. (HIGH)** From the Ghostty 1.3.0 release notes (2026-03-09):

> "During the 1.3 development cycle, libghostty was successfully extracted and is now available as a standalone Zig module."
> "The Zig module is full featured and shares almost all of its code with Ghostty."
> "Simultaneously, there is a work-in-progress C API."
> "Dozens of projects both free and commercial are already using libghostty."
> "The Ghostty development team has decided to separate the Ghostty GUI and libghostty release cycles, so libghostty will have its own versioning and release schedule independent of the Ghostty desktop application."

The stated near-term focus is *"stabilizing and tagging a libghostty release"* with **no committed timeline**. The original goal in *Libghostty Is Coming* (2025-09-22) was a tagged stable libghostty-vt "within 6 months" — i.e. ~March 2026. **That has slipped by roughly four months and remains unmet as of 2026-07-23. (MEDIUM-HIGH — this is negative evidence: no tag, no repo, no release note, no blog post.)**

Practical posture:

- **libghostty-vt** — functionality is battle-hardened (fuzzed, Valgrind-tested, shipping inside Ghostty for years); **signatures churn**. Pin a commit, not a tag (there are none).
- **Full libghostty** — no guarantees at all, plus you are consuming something upstream labels "not for external use." The going rate for stability is the `libghostty-spm` / Muxy pattern: pin an immutable upstream commit, carry your patches in-tree, own the build.

`ghostty.org/docs` still has **no libghostty section** in its navigation; library docs live only at the Doxygen site `libghostty.tip.ghostty.org`, built from `tip`.

### 2.6 Non-Ghostty apps embedding libghostty

**Full-library (GhosttyKit / surface + renderer):**

- **Muxy** — MIT, SwiftUI macOS workspace; the subject of §1.
- **OrbStack** — commercial; called out by Hashimoto in *Libghostty Is Coming* as already shipping on the internal C API.
- **Kytos** — native macOS terminal on Ghostty, with a 2026-03-14 writeup of the XCFramework/XcodeGen/linker-flags integration.
- A long tail of macOS/iOS terminals and AI-agent workspaces catalogued in `awesome-libghostty`. **(MEDIUM on individual liveness — not verified project by project.)**

**libghostty-vt only (own renderer):**

- **`coder/ghostty-web`** — Ghostty VT compiled to WASM with a drop-in xterm.js-compatible API.
- **Ghostel.el** — Emacs terminal on libghostty-vt; hit HN 2026-07-12 at 268 points.
- **`rockorager/libghostty-vaxis`** and `monstar` — notable because rockorager is a Ghostty maintainer.
- `montanaflynn/headless-terminal` ("Puppeteer for TUIs"), `mwunsch/termscope`, `aarol/term2html`, plus JupyterLab, Obsidian, Godot, JavaFX and Electron embeds.

**Still evaluating, not adopted:** xterm.js issue #5686, *"Explore adopting libghostty"* (opened 2026-02-09, still open, self-described as *"mostly just a knowledge dump"*). Its blockers are exactly the ones above: how far along the C API is, parser-handler compatibility, Windows support, and Ghostty's strategic direction.

### 2.7 Most recent libghostty news from Mitchell Hashimoto

**The most recent substantive libghostty announcement remains the Ghostty 1.3.0 release notes, 2026-03-09. (MEDIUM-HIGH** — based on a full scan of his blog index, the ghostty.org release-notes index, org repos and searches; X/Mastodon/Discord could not be fetched.**)**

His 2026 posts, newest first: *Everyone Should Know SIMD* (2026-07-22 — uses a Ghostty codepoint loop as a case study, no libghostty content), *Pledging Another $400,000 to the Zig Software Foundation* (2026-06-21), ***Ghostty Is Leaving GitHub*** (2026-04-28), *Simdutf Can Now Be Used Without libc++ or libc++abi* (2026-04-15 — indirectly relevant, it feeds libghostty-vt's zero-dependency goal), *The Building Block Economy* (2026-04-07), *My AI Adoption Journey* (2026-02-05), *Don't Trip[wire] Yourself* (2026-01-21), *Finding and Fixing Ghostty's Largest Memory Leak* (2026-01-10). The foundational announcement remains *Libghostty Is Coming* (2025-09-22).

**Two adjacent facts that matter to Tessera:**

1. **Ghostty is leaving GitHub (2026-04-28).** Destination undisclosed — *"We have a plan but I'm also very much still in discussions with multiple providers."* A read-only mirror will stay at the current URL. **This is already affecting consumers**: `mitchellh/go-libghostty` on GitHub is now explicitly a `[Mirror]`, with source of truth at `tangled.org/mitchellh.com/go-libghostty`. If you vendor or submodule libghostty, expect the canonical URL to move. **(HIGH)**
2. **Hashimoto's stated conviction** (HN, ~March 2026): *"I suspect by the middle of 2027, the number of people using Ghostty via libghostty will dwarf the number of users that actually use the Ghostty GUI."* The macOS app is at roughly 1M downloads/week.

**Release cadence (MEDIUM):** a maintainer stated in Discussion #10351 that Ghostty moved to a 6-month major/minor cycle on a March/September cadence, implying **1.4.0 around September 2026**, with scriptability, true tmux control mode, and graphical preferences among the themes.

### 2.8 What this means for Tessera

**(HIGH)** Tessera needs the **full** libghostty — surface, Metal renderer, input, and `ghostty_surface_read_cells` (the API that makes "a plugin can read terminal output" possible at all, per §1.1). libghostty-vt alone would mean writing your own GPU renderer, font shaping, and input stack.

That means accepting, today:

- an API upstream calls `ghostty-internal` and documents as "not for external use";
- **no tagged release to pin** — you pin a commit;
- **Zig 0.16.0 + Xcode 26** in whatever pipeline builds the artifact;
- a canonical-URL move as Ghostty leaves GitHub;
- `.unsafeFlags` in `Package.swift`, which blocks Tessera from ever being consumed as a versioned SwiftPM library dependency.

Muxy's answer — fork Ghostty, run a build pipeline in the fork that emits `GhosttyKit.xcframework.tar.gz`, consume it as a binary artifact, and never run Zig in the app repo or app CI — is, on this evidence, the *correct* engineering answer rather than a shortcut. `Lakr233/libghostty-spm` independently arrived at the same pattern (pin a commit, carry patches).

**Recommendation (HIGH): copy the Muxy/libghostty-spm pattern from day one.** Maintain `tessera-app/ghostty` as a soft fork with a pinned upstream commit and in-tree patches; publish a dated `GhosttyKit.xcframework` release; have the app repo download and cache it keyed on the tag. Do not put `zig build` in Tessera's own CI. Budget explicit maintenance for rebasing the fork, and treat "libghostty tags a stable release" as a future simplification rather than something to plan around.

---

## 3. Plugin Host Options for a Swift/macOS App Running TypeScript Plugins

### 3.0 The single most important finding in this section

**Raycast built the exact architecture Tessera is contemplating, shipped it, and then walked away from it. (HIGH)**

In v1, Raycast ran a custom React reconciler that streamed a render tree over IPC into native AppKit views. In **Raycast 2.0 (public beta 2026-05-14)** they rewrote the app so the UI is **React + TypeScript rendered inside a system WebView** (WKWebView on macOS, WebView2 on Windows), backed by a long-lived Node process and a Rust core, inside a thin native shell.

Their stated reason for not going SwiftUI:

> "We didn't make a lot of use of SwiftUI either. It matured in parallel with Raycast and never quite cleared our bar for performance and control."

They published the cost honestly — memory went from **200–300 MB (v1)** to **350–450 MB (v2)**.

This is not "don't build native" — Raycast's philosophy is still *"A native app that uses web for its UI."* But the reconciler→native-AppKit bridge is a known-expensive path, built by a well-funded team, then abandoned for cross-platform reach and iteration speed. Tessera should build it only if "renders as real AppKit/SwiftUI" is a differentiator it would defend in a demo — not for performance by default.

### 3.1 Raycast teardown

#### Execution model (v1 — the well-documented one)

| Layer | Detail | Conf |
| --- | --- | --- |
| Process model | Raycast main process (Swift/AppKit) + **one single long-lived child Node.js process** hosting all extensions | HIGH |
| Per-extension isolation | Each extension runs in its **own Node worker thread = its own V8 isolate**, with its own event loop | HIGH |
| Memory control | Worker threads get **configurable heap limits**; greedy extensions are terminated automatically | HIGH |
| IPC | **JSON-RPC** over standard file-descriptor streams, read on the Swift side with **`DispatchIO`** | HIGH |
| Node runtime | v1: downloaded on first extension install, binary-verified against tampering. **v2: bundled with the app** | HIGH |

Notably, Raycast's *original* pre-ship design was *"one Raycast main process, one XPC support process (the extension host) and many JavaScriptCore engines."* **They moved off it to Node. (MEDIUM** — quoted in their API post; the detailed reasoning was never published.**)** Given Tessera is considering JSC, that reversal is worth weighing.

#### The JS→native protocol (the part most worth stealing)

1. Author writes React with Raycast components (`<List>`, `<Detail>`, `<Form>`, `<ActionPanel>`); standard hooks drive re-renders.
2. A **custom React reconciler** converts the tree to a **JSON render tree**.
3. Raycast **diffs against the previous tree using the JSON Patch standard** — it sends patches, not full trees.
4. Patches are **gzip-compressed when compression overhead pays for itself**.
5. Patches cross the boundary as JSON-RPC.
6. Swift converts patches to **bitset types** consumed by a **view-model layer**, which shields native components from render-tree churn.
7. The view model drives **plain imperative AppKit** — no HTML/CSS.

Their framing: *"v = f(s) across process boundaries."*

**The security property to copy verbatim (HIGH):** extensions can send only **registered message types** (`render`, `setClipboard`, …). Arbitrary code execution *into* Raycast is structurally impossible, not merely prevented by checks. Temporary session IDs track parallel command instances.

Ordering: Node workers are single-threaded so messages cannot interleave at the source; Swift uses **serial queues and buffered streams** to preserve ordering.

**No latency numbers are published** — they call the chain *"surprisingly fast."* **(could not verify)**

#### Build and bundling

- **`ray` CLI is a Go binary** (Darwin + Linux; the Linux build exists to run CI on GitHub Actions) that **embeds esbuild in library form** to transpile TS. **(HIGH)**
- Commands: `npx ray build` (production; `-e dist` to validate), `ray develop`, `ray lint`, `ray migrate`, `ray publish`.
- **Versioning: deliberately no SemVer for extensions.** Single-version publishing; app/API/CLI version numbers are synchronized; an extension auto-installs only when its API version ≤ the installed Raycast version; deprecated APIs are handled by **automatic code migrations ("mods")**. **(HIGH)** This is an underrated decision and directly applicable to Tessera.

Manifest is `package.json`. Extension keys: `name`, `title`, `description`, `icon`, `author`, `platforms`, `categories`, `commands`, `tools`, `ai`, `owner`, `access`, `contributors`, `keywords`, `preferences`, `external`. Command keys: `name`, `title`, `subtitle`, `description`, `icon`, `mode`, `interval`, `keywords`, `arguments`, `preferences`, `disabledByDefault`. `mode` is one of **`view`** / **`no-view`** / **`menu-bar`**. Preference types: `textfield`, `password`, `checkbox`, `dropdown`, `appPicker`, `file`, `directory`.

#### Permission / trust model — the weak part, and they admit it

- Extensions get **V8-isolate isolation from each other** but are **not sandboxed for file I/O or networking**. The extension host **inherits the parent Raycast process's environment and sandbox** — nothing more. Raycast notes this *"may change."* **(HIGH)**
- Extensions reach Raycast only through RPC exposing a **defined API set**. **(HIGH)**
- Restricted OS resources fall back to **standard macOS TCC prompts**. **(HIGH)**
- Secrets: `password` preferences and per-extension encrypted LocalStorage, scoped to the owning extension. **Keychain access is explicitly rejected** for store extensions. **(HIGH)**
- **Trust is enforced socially and at review time, not at runtime**: every store extension is open source; staff + community review; CI validates manifest, assets and authorship and runs type checking. Binary dependencies are allowed only from trusted sources **with hash integrity verification**. No external analytics. **(HIGH)**

**So Raycast's model is essentially Muxy's minus the runtime consent prompts and the capability manifest, plus a mandatory human review gate.** Tessera can do better than both.

#### Dev loop

`npm run dev` (wraps `ray develop`); the extension pins to the top of root search; **commands auto-reload on save**; **error overlays with full stack traces render natively**. Mechanically the CLI watches files and signals the app via **app URL schemes + pid files** — no dev server — and captures errors by streaming the OS log. **(HIGH)** An independent teardown pegs the reload loop at **~200 ms**. **(MEDIUM)**

#### AI extensions — the most AI-writable plugin surface found in this entire research pass

Three primitives — **Tools, Instructions, Evals**: **(HIGH)**

- **Tools** are plain functions taking a single structured object and returning a value. **Semantics for the model come from JSDoc comments** on the function and its parameters. A tool may export an optional **confirmation** function — the user approves before execution.
- **Instructions** are extension-wide system guidance under the `ai` key.
- **Evals** are integration tests for the AI path (`input`, `mocks`, `expected`), with matchers `includes`, `matches`, `meetsCriteria`, `callsTool`. Both can move to a root `ai.yaml`.
- **MCP:** local stdio MCP servers install and expose their tools via `@`-mention identically to native AI extensions. **(MEDIUM)**

**"Tool = exported function + JSDoc + optional confirmation callback" requires no new syntax, no schema DSL, and no build-time codegen.** For Tessera's "AI writes plugins correctly first try" goal, this is the shape to copy — and the **confirmation callback is a permission primitive expressed as ordinary code**.

#### Published memory numbers (HIGH)

| Metric | Value |
| --- | --- |
| v1 typical | 200–300 MB |
| v2 typical | 350–450 MB |
| WebView (WebContent), window hidden | ~120–200 MB |
| **Node.js backend** | **~150–200 MB** |
| Native Swift app | ~40 MB |
| WebKit GPU process | ~18 MB |
| WebKit Networking process | ~12 MB |

**~150–200 MB is the realistic budget for a bundled-Node extension host.** Note Muxy's positioning as *"Lightweight and Memory efficient"* (`README.md:7`) and its CLAUDE.md rule *"Low memory and CPU usage is one of the key factors"* — a JSC host is a fraction of this, which is very likely why Muxy chose it.

### 3.2 Host option comparison

| | **JSC `JSContext`** | **WKWebView** | **QuickJS(-ng)** | **Sidecar Node/Bun/Deno** | **WASM (wasmtime)** |
| --- | --- | --- | --- | --- | --- |
| **TS → running code** | You ship the build step (esbuild/swc → single bundle). No module loader. | Same bundling, or ES modules via blob URLs. Browser module loader available. | You ship the build step. quickjs-ng has ES module support. | **Native.** `bun run x.ts` / `tsx`. Full npm. Zero build step possible. | Heaviest: ComponentizeJS or Javy wraps your JS **and an engine** into a `.wasm`. |
| **Hot reload** | Trivial — discard the `JSContext`, re-eval. Sub-ms. | Easy — reload frame / re-inject. | Easy — free `JSRuntime`, recreate (**<300 µs full lifecycle**). | Easy — restart child or use watch mode. ~10–120 ms respawn. | Worst — recompile JS→WASM→component per save, including a Wizer pre-init pass. |
| **Sandbox / permissions** | **Weak.** Same process, same address space. Isolation = "can only call what you inject" — one bridging bug is RCE in your process. | **Good, free.** Separate WebContent process, WebKit sandbox profile, structured-clone-only boundary, `WKContentWorld` isolation. | **Good.** No ambient authority — the guest gets nothing unless registered. Per-runtime memory limits. | **Best at process granularity.** Deno's scoped `--allow-*` is deny-by-default and per-resource. | **Best by construction.** Capability-based; a component has only what its WIT world imports. |
| **Memory / startup** | Smallest incremental — JSC is in the OS. Per-context cost low. | ~150 MB+ for WebContent+GPU+Networking. | **367 KiB** x86 hello-world; runtime lifecycle **<300 µs**. Lowest of any option. | Node **~150–200 MB** (Raycast-measured). Bun compiled binary ~59 MB on disk. | ~**8 MB** per ComponentizeJS component. |
| **Swift IPC ergonomics** | **Best.** `JSExport`, Swift closures as JS functions, synchronous, no serialization. | Async only; `WKScriptMessageHandler` + `callAsyncJavaScript`. Structured clone. | Very good. C API → thin Swift shim, synchronous. You maintain the bridge. | Async only. stdio + JSON-RPC (Raycast's choice) or unix socket (Muxy's choice). | Rigid — WIT-generated bindings; async needs host plumbing. |
| **AI-writability** | **Poor** | **Medium** | **Medium** | **Excellent** | **Poor** |

#### JavaScriptCore `JSContext` — what Muxy chose

**JIT and entitlements (MEDIUM–HIGH).** On macOS, in-process JSC *can* JIT, but under Hardened Runtime you must ship **`com.apple.security.cs.allow-jit`** (permits `MAP_JIT` RWX pages). On Apple Silicon this entitlement is required for anything using JavaScriptCore, including WKWebView. **This exactly explains Muxy's `MuxyExtensionHost.entitlements`** (§1.2), which carries `allow-jit`, `allow-unsigned-executable-memory`, and `disable-library-validation`.

> ⚠️ There are **open reports of `allow-jit` regressions on ARM64 in macOS 26 Tahoe** causing crashes for JIT engines in sandboxed contexts (Apple DevForums thread 821584). **Verify on the target OS before committing. (MEDIUM)**

**What's missing is the real cost.** Bare `JSContext` gives you ECMAScript and nothing else: **no `setTimeout`/`setInterval`, no `fetch`, no `console`, no module loader/`require`, no `URL`, no `TextEncoder`, no event-loop integration.** You implement each on `JSExport` + GCD. **This is not theoretical — §1.2 shows Muxy hand-writing exactly these**: timers over `DispatchSource`, `console` over a `@convention(block)` shim, and docs instructing authors to shell out to `curl` because there is no `fetch`.

**Swift wrapper availability (HIGH):** `SusanDoggie/SwiftJS` was **archived read-only on 2026-04-03**, last release May 2021. Do not depend on it.

**AI-writability is poor.** An LLM will reflexively emit `fetch()`, `setTimeout()`, `require('fs')`, `import`, `process.env`, `Buffer`. In a bare `JSContext` these are `undefined` at runtime with **no compile-time error** — silent `undefined is not a function`. The model has near-zero training data on "JavaScript with no host APIs."

#### WKWebView as sandbox — what Muxy uses for UI

Best security-per-effort on Apple platforms: you inherit WebKit's multi-process architecture and sandbox profile **for free**, which is the hardest thing on this list to build yourself.

**`WKContentWorld` (macOS 11+) gives a separate JS world so plugin page code cannot shadow or intercept your injected bridge symbols.** Note the caveat that WebViews **do not** isolate injected scripts from page scripts by default — it is opt-in. **This is precisely the gap identified in Muxy at `ExtensionWebView.swift:48`, which passes `contentWorld: .page`. (HIGH)** Tessera should use an isolated world.

Cost: ~120–200 MB WebContent + ~18 MB GPU + ~12 MB Networking. Everything is async and structured-clone serialized.

**AI-writability: medium-good.** It is a real browser — `fetch`, timers, `console`, ES modules all behave as the model expects. The friction is only your custom `webkit.messageHandlers.*` bridge shape, solvable with good `.d.ts` and examples.

#### QuickJS / quickjs-ng — and the Figma precedent

**Numbers (HIGH):** 367 KiB of x86 for hello-world; **complete runtime lifecycle in <300 µs**; ~100% of the ES2025 test suite; the 2026-06-04 release is 42% faster than its predecessor on bench-v8. Use **quickjs-ng** (the maintained fork) for embedding.

**The Figma precedent is the strongest argument here. (HIGH)** Figma originally sandboxed plugins with the **Realms shim** — excellent DX, native speed, working devtools, because plugin code ran in the *host's* JS VM. That was exactly the flaw: **multiple independent sandbox escapes, all from confusing an object inside the sandbox with one outside it.** They replaced it with **QuickJS cross-compiled to WebAssembly**, making object confusion structurally impossible because the representations live in incompatible memory spaces. They shipped the swap **in 11 days** because they had kept the architecture swappable. Admitted cost: *"somewhat slower for certain plugins, but intrinsically more secure."*

**The generalizable lesson: any sandbox that shares a JS heap with the host is a sandbox you will eventually escape.** That directly indicts running untrusted plugin code in an in-process `JSContext` — i.e. Muxy's `runScript` surface.

> ⚠️ **Swift bindings are the gap. (HIGH that none was found; MEDIUM that none exists.)** Bindings exist for Rust, C++, Go, Python and WASM; **no maintained Swift binding was found.** QuickJS is a handful of dependency-free C files, so a SwiftPM C target is tractable — but budget for writing and maintaining it.

#### Sidecar Node / Bun / Deno — what Raycast and VS Code ship

- **TS is the whole point:** `bun run plugin.ts` or `tsx` runs TypeScript directly, full npm, no custom build step required.
- **Proven IPC recipe:** JSON-RPC over stdio, `DispatchIO` on the Swift side, serial queue for ordering, **a closed set of registered message types**.
- **Isolation without N processes:** Raycast's one process + one worker thread (V8 isolate) per plugin, with heap caps and auto-termination.
- ⚠️ **Critical macOS constraint (HIGH):** a child spawned via `posix_spawn`/`NSTask` **always inherits the parent's sandbox**. **You cannot launch a child under a *tighter* sandbox profile than the parent** — `sandbox_init` is deprecated and the profile format was never documented. **So "spawn the plugin host in a tighter macOS sandbox" is not a supported strategy; enforcement must come from the runtime or from XPC.**
- **This is why Deno is interesting**: scoped, deny-by-default `--allow-read=./data`, `--allow-net=api.example.com`, `--allow-env=API_KEY`. It is the only option here providing per-plugin, per-resource enforcement you do not have to build. See §4.
- **Bun single-file executables (HIGH):** `bun build --compile` works with `--bytecode`, `--minify`, `--sourcemap`. **Each binary embeds its own Bun runtime — ~59 MB on arm64.** Rough edges in 2026: `--bytecode` without `--compile` is CJS-only (issue #29286); embedding large asset directories is cumbersome; Worker + embedded directories don't compose (issue #19725).
- **`deno_core` as an embeddable Rust lib (HIGH):** `JsRuntime` gives a V8 isolate + event loop; register Rust functions via `deno_core::extension!`; you drive `run_event_loop()` yourself. For a Swift app this means adding a Rust layer — a real cost, but it buys V8 + a permission system without shipping the Deno CLI.
- **Startup numbers to distrust (LOW):** the widely repeated Bun 8–15 ms / Deno 40–60 ms / Node 60–120 ms figures come from comparison blogs, not reproducible benchmarks. Measure yourself.

**AI-writability: excellent, and it is not close.** An LLM writing a Node/Bun TS plugin sits in the densest region of its training distribution: `import`/`export`, `fetch`, `async/await`, npm, `process.env`, `node:fs`. It gets imports right, gets types right (and real `tsc` catches what it doesn't), and npm means it reaches for a library rather than hand-rolling. **For Tessera's stated first-try-correctness goal, this dimension should dominate the decision.**

#### WASM — unbeatable security, worst DX for TypeScript

- **JS cannot be AOT-compiled to raw WASM.** ComponentizeJS therefore **embeds a whole JS engine (SpiderMonkey via StarlingMonkey) in every component — ~8 MB each. (HIGH)**
- Startup is well mitigated: **Wizer pre-initializes the engine and snapshots it**, so runtime startup executes pre-compiled bytecode.
- **Javy** (QuickJS-based) is smaller but **lacks component-model support**.
- Every host capability is declared in WIT — exactly the capability sandbox you want, and exactly the codegen step that makes iteration slow.

**AI-writability: poor.** WIT is a niche IDL thinly represented in training data, `wit-bindgen` glue is unforgiving, and "write TypeScript" vs "satisfy a WIT world and rebuild a component" is where models produce confidently wrong code.

#### Other 2026 runtimes checked

- **Static Hermes (`shermes`)** — AOT-compiles a strongly-typed subset of JS/TS to native object files. Conceptually ideal for a native host, but it **remains a Meta research effort on the `static_h` branch** and as of April 2026 was reported not cleanly installable via standard package managers. **Do not build on it. (MEDIUM)**
- **Deno Sandbox (2026)** — Linux microVMs for untrusted code, boot <1 s. **Cloud-hosted on Deno Deploy, not embeddable in a local macOS app.** Not applicable. **(MEDIUM)**

### 3.3 Other precedents worth naming

**VS Code — `extensionHostProcess`.** A separate full Node.js process with its own V8, over IPC. It is deliberately **not a security sandbox**: it isolates extensions from *VS Code* (*"the user can open, type or save files at any time... irrespective of what extensions are doing"*) but **does not isolate extensions from each other**. Because JS is single-threaded, one extension can monopolize the host thread and stall every other extension. Their security answer is **Workspace Trust**, a user-facing gate, not a runtime sandbox. **(HIGH)** See §4 for the consequences.

**Zed — WASM + WIT components.** Extensions compile to Component Model binaries targeting `wasm32-wasi`, run in Wasmtime, and talk to the host through a **versioned WIT-defined API** with `wit_bindgen` generating glue. Elegant design win: **host→extension calls are async Rust on the host side even though they look synchronous inside the extension**, so blocking IO in an extension cannot block the host. **The catch for Tessera: Zed extensions are written in Rust, not TypeScript. (HIGH)**

**Obsidian — the anti-pattern, honestly documented.** No sandbox: community plugins inherit Obsidian's full privileges — unrestricted filesystem access and arbitrary command execution. Obsidian's own docs state they **cannot reliably restrict plugins to permission levels** for technical reasons. Mitigations are entirely social: **Restricted Mode on by default**, an **automated per-version security/quality/malware scan surfaced as a "safety scorecard"**, and community reporting. **(HIGH)**

**Chrome MV3 service workers — the lifecycle cautionary tale.** Background pages became event-driven service workers **terminated after 30 s of inactivity**, with a hard kill past 5 minutes on a single request. Consequence: **all global state is lost on termination**, forcing everything through `chrome.storage` and forcing every extension to be resilient to arbitrary death. **(HIGH)** **Lesson for Tessera: if you unload idle plugins to save memory, make state persistence a first-class, ergonomic API from day one** — don't bolt it on. Muxy's `muxy.storage` (per-extension, JSON, 1 MB/value, 5 MB/extension) is the right shape.

---

## 4. Permission & Sandbox Models Worth Stealing

> ⚠️ **A live example of the hazard Tessera is being built around.** During this research a source (`pkgpulse.com/guides/deno-3-new-features-npm-compatibility-2026`) confidently described a "Deno 3" with `--ignore-read` / `--ignore-env` flags and `deno approve-scripts`. **No Deno 3 exists.** The GitHub releases API returns `v2.9.3` as latest, and Deno's blog index runs 2.5 → 2.6 → 2.8 → 2.9. **The article is fabricated SEO content. (HIGH)** This is precisely the failure mode that makes AI-written plugins dangerous: plausible, confident, wrong text about a permission model. Design Tessera so that a plugin written against a hallucinated API **fails loudly at load time**, not silently at runtime.

### 4.1 Deno's permission model

**The flag set as of Deno 2.9 (HIGH):**

| Capability | Allow | Deny | Short |
| --- | --- | --- | --- |
| FS read | `--allow-read` | `--deny-read` | `-R` |
| FS write | `--allow-write` | `--deny-write` | `-W` |
| Network | `--allow-net` | `--deny-net` | `-N` |
| Env vars | `--allow-env` | `--deny-env` | `-E` |
| System info | `--allow-sys` | `--deny-sys` | `-S` |
| Subprocess | `--allow-run` | `--deny-run` | — |
| FFI | `--allow-ffi` | `--deny-ffi` | — |
| Remote import | `--allow-import` | `--deny-import` | — |
| Everything | `-A` / `--allow-all` | — | — |

**Deny always beats allow**; the canonical pattern is broad-grant-plus-carve-out (`--allow-read --deny-read=/etc`). Granular syntax: `--allow-net=github.com,jsr.io`, `--allow-net="*.example.com"`, `--allow-net=example.com:80`, `--allow-env="AWS_*"` (2.1+), `--allow-run="curl,whoami"`, `--allow-ffi=./libfoo.so`.

Note that `deno.land`, `jsr.io`, `esm.sh`, `cdn.jsdelivr.net`, `raw.githubusercontent.com` and others are **trusted by default without `--allow-import`** — a pre-granted capability Tessera should *not* copy.

**`Deno.permissions` API (HIGH):** `query()` / `request()` / `revoke()` plus sync variants; `PermissionState = "granted" | "denied" | "prompt"`. `PermissionStatus` is an `EventTarget` with a readonly `state`, a readonly **`partial`** flag (true when the grant is scoped rather than blanket), and an `onchange` event.

**The `onchange` + `partial` pair is the most reusable API design here: a plugin can observe its own capability set shrinking at runtime and degrade gracefully rather than crash.** Neither Muxy nor Raycast offers this.

**Deno 2.5 permission sets in `deno.json` (HIGH)** — named, declarative, reviewable capability bundles:

```json
{
  "permissions": {
    "default": { "read": ["./deno.json"], "env": true, "run": { "allow": ["git"] } },
    "process-data": { "read": ["./data"], "write": ["./data"] }
  },
  "tasks": { "dev": "deno run -P=process-data main.ts" }
}
```

**This is the manifest shape Tessera should copy** — not a wall of flags.

**The documented escape hatches (HIGH — all from Deno's own docs):**

1. **`--allow-run` invalidates the sandbox.** > *"it essentially invalidates the Deno security sandbox."* Child processes do **not** inherit the parent's restrictions.
2. **`LD_*` / `DYLD_*` escalation.** Spawning with linker env vars requires *unscoped* `--allow-run`, because those variables > *"instruct the dynamic linker to load arbitrary shared libraries into the child process."* Otherwise `--allow-run=echo` would be a full escape.
3. **`--allow-ffi` is a total escape** — native code > *"can issue system calls directly, regardless of which `--allow-*` flags you passed."*
4. **The static module graph loads without permission checks.** > *"All modules that are imported in the initial static module graph (local files, npm packages, jsr packages, and remote URLs) are loaded by the runtime without consulting the permission system."* **This is the npm-compat hole** — pulling a dependency tree is unmediated; only runtime behaviour is gated.
5. **No intra-privilege isolation.** > *"code executing in a Deno runtime can use `eval`, `new Function`, or even dynamic import or web workers to execute arbitrary code with the same privilege level."* **Deno permissions are a process boundary, not a plugin-vs-host boundary.** If Tessera ran plugin TS in the same isolate as host code, Deno's model would give it nothing.
6. Permission is checked against a **symlink's location, not its target**.

Deno's own conclusion: > *"When executing untrusted code, it is important to have more than one layer of defense."*

**Auditing primitives worth stealing outright (HIGH):** `DENO_TRACE_PERMISSIONS=1` (stack traces for every permission request) and `DENO_AUDIT_PERMISSIONS=<file>` (JSONL log of every access: timestamp, permission name, value), also emittable as OpenTelemetry via `DENO_AUDIT_PERMISSIONS=otel`.

**For AI-generated plugins this is arguably more valuable than the enforcement itself**: run a generated plugin in audit mode, diff observed capability use against the declared manifest, and flag over-declaration or covert access.

**Supply chain (HIGH):** lifecycle scripts are **off by default**, opt-in per package via `deno install --allow-scripts=npm:sqlite3` — versus npm, where > *"any code in that package (even deeply nested dependencies) runs with full access to your system by default."*

### 4.2 Figma's plugin sandbox evolution — the most transferable case study

#### The 2019 design and why it was chosen

Figma evaluated three approaches:

- **Plain iframe with async message passing — rejected.** > *"Message-passing has overhead on the order of 0.1ms per round-trip, which would only allow for ~1000 messages per second."* On Microsoft's design-systems file, > *"it took 14 seconds just to serialize the document and send it to the plugin, before the plugin could even run."*
- **Duktape compiled to WASM — technically sound, not chosen then.** Synchronous main-thread API, secure by construction, but no JIT, no working devtools, ES5-only.
- **Realms shim — chosen.** `with (scopeProxy) { eval(userCode) }`, a Proxy intercepting all identifier resolution, a same-origin iframe supplying fresh intrinsics. Won on synchronous scene access, JIT performance, and working devtools.

They articulated the correct invariant themselves: > *"The sandbox should never have direct access to an object created outside the sandbox as it could get access to global scope."* Passing `console.log` in directly lets a plugin walk the prototype chain back out. Their mitigation was a ~500-line **membrane** — opaque handles and explicit accessors, with every host API wrapped by a function *created inside the realm*.

#### It failed (HIGH)

> *"several independent vulnerabilities were recently discovered with the Realms shim that could have allowed code inside the sandbox to escape."*

The escape class: > *"the Realms shim confusing an object from outside the sandbox with an object from inside the sandbox or vice versa"* — root-caused to the shim > *"us[ing] the same JavaScript VM for all code both inside and outside the sandbox."*

Response: halted new plugin approvals, disabled plugin updates, rolled patches progressively, audited all published plugin code (no evidence of exploitation). Resolution: > *"We now use QuickJS, a JavaScript VM written in C and cross-compiled to WebAssembly."* Object confusion became structurally impossible because representations differ between the worlds. Admitted trade-off: **"somewhat slower for certain plugins, but intrinsically more secure"** — no benchmark published. They shipped the swap in **11 days** because they had kept the layer replaceable.

**This is effectively a controlled experiment, and the result is unambiguous: an expert team built a same-VM membrane sandbox, documented the right invariant, and it broke in ~6 months. A separate VM held.**

#### The two-world model today (HIGH)

| | Sandbox (main thread, QuickJS-in-WASM) | iframe UI |
| --- | --- | --- |
| Scene graph | ✅ full, **synchronous** | ❌ none |
| DOM | ❌ | ✅ |
| `fetch` / XHR | ❌ | ✅ (manifest-gated) |
| `setTimeout` | ❌ | ✅ |
| Language | ES2020+, minimal `console` | full browser |

Bridge: `figma.ui.postMessage()` ↔ `parent.postMessage()`. **Neither side alone holds the lethal combination of data access + egress.** This is a structural prompt-injection defence that predates the term, and it is the single most important pattern for Tessera to copy.

#### Manifest capability declarations (HIGH)

- **`documentAccess: "dynamic-page"`** — required for all new plugins; forces `await` on page loads instead of assuming the whole document is resident. A performance-motivated narrowing that doubles as scope reduction.
- **`networkAccess.allowedDomains`** (required): `["none"]` = no external network; `["*"]` = anything; `["*.example.com"]` wildcard subdomains; scheme prefixes; **path-level** granularity (`["api.example.com/rest/get"]`); `["http://localhost:3000"]` for dev.
- **`networkAccess.reasoning`** — **required** whenever `allowedDomains` includes `"*"` or a local server. A human-readable justification surfaced to reviewers and users. **Excellent, nearly free, and directly applicable to AI-generated plugins.**
- **`devAllowedDomains`** — dev-only allowlist so shipping builds don't carry localhost grants.
- **`permissions`** — `currentuser`, `activeusers`, `fileusers`, `payments`, `teamlibrary` (data-scope, distinct from capability).
- **`capabilities`** — `textreview`, `codegen`, `inspect`, `vscode` (which host surfaces may be hooked).

#### The cost, from a plugin author (MEDIUM — single credible practitioner)

Tom MacWright: > *"When QuickJS encounters an issue in Figma, you get truly impenetrable errors. I've spent a lot of time just guessing what's going wrong with my plugins."* And: > *"the performance of Figma plugins is also not great."*

**Design implication for Tessera: if you run plugins in a separate VM, budget real engineering for the debugging story** — source maps across the boundary, structured error marshalling, a devtools bridge. This is the tax that made Figma plugin authors unhappy, and **AI-generated plugins produce more runtime errors, not fewer.** Your feedback loop is a model reading a stack trace; if the trace is impenetrable, iterative generation does not converge.

### 4.3 Raycast's permission model — reviewer-gated trust

Covered in §3.1. The key finding, in Raycast's own words:

> "Extensions are **not further sandboxed** as far as policies for file I/O, networking, or other features of the Node runtime are concerned."

There is **no capability declaration in `package.json`**. The only real boundary is inherited macOS TCC, prompted at the **Raycast app** level — so one extension's TCC grant is every extension's. There are long-standing open requests for per-extension permissions (raycast/extensions issues #200, #213). **(MEDIUM — seen in search results, not fetched.)**

**Verdict: the Raycast model is reviewer-gated trust.** It scales to a curated store of human-written extensions. **It does not survive contact with AI-generated plugins**, where volume is per-user and per-session and no reviewer exists. Steal the IPC design; discard the trust model.

### 4.4 VS Code — the cautionary tale

**Microsoft's official position (HIGH):**

> **"The extension host has the same permissions as VS Code itself. This means that any action that VS Code can perform, an extension can also perform."**

Sandboxing appears in their stack **only as a scanning technique**, not a boundary: > *"Dynamic detection by verifying the extension's runtime behavior by running it in a sandboxed environment (clean room VM)."*

What they do instead: Marketplace **signing** of all published extensions; **verified publisher** (domain-ownership proof + six months in good standing); a **publisher trust prompt** added in VS Code 1.97; and **Workspace Trust**, which gates whether *project folder* code runs automatically — orthogonal to extension permissions.

**Academic evidence — UntrustIDE, NDSS 2024 (HIGH; paper read directly).** Lin, Koishybayev, Dunlap, Enck, Kapravelos (NC State), DOI `10.14722/ndss.2024.24073`:

- Corpus of 43,436 extensions (Jan 2023); 25,402 contained JavaScript.
- > "We identified and verified code execution vulnerabilities in **21 extensions** that amount to over **6 million installations**."
- > "We discovered **13,655** VS Code extensions where each one has more than **100 npm transitive dependencies**. Furthermore, **9,710** extensions depend on vulnerable npm packages with a **critical-level** advisory."
- > "Unlike web browser extensions, VS Code extensions are not sandboxed."
- Threat model includes **workspace settings and files as a taint source** — a `settings.json` committed into a repo is a code-injection vector. Sinks: `eval()`, shell, writing `.bashrc`.
- Motivating example: Snyk's 2021 LaTeX Workshop finding — the extension opened a localhost web server, so **any website open in the developer's browser could reach it**.

**Supply-chain incidents:**

- **Wiz Research (reported 2025-03-30, published 2025-10-15) — HIGH:** > *"over 550 validated secrets, distributed across more than 500 extensions from hundreds of distinct publishers"*, including > *"over one hundred valid leaked VSCode Marketplace PATs"* (install base >85,000) and >30 leaked OVSX tokens (install base >100,000). **Those PATs allow publishing malicious updates to already-installed extensions** — the trust anchor was compromisable via a token leaked inside the extension bundle itself.
- **GlassWorm** — self-propagating malware first documented on Open VSX in Oct 2025. **(MEDIUM, secondary.)**
- Malicious-extension detections reportedly quadrupled during 2025; a vibe-coded extension with built-in ransomware was found Nov 2025. **(MEDIUM/LOW — trade press, numbers unverified.)**

**Verdict for Tessera (HIGH): VS Code proves that signing + publisher verification + marketplace scanning *without a runtime boundary* fails, because the attacker's target becomes the publisher's token rather than the code review. Tessera's plugins are AI-generated per user — there is no publisher identity to verify at all. Signing is not an available strategy; a runtime boundary is mandatory.**

### 4.5 Other capability models

**WASI Preview 2 / Component Model (HIGH on mechanism):** **unforgeable resource handles** — > *"there's no way for an instance to acquire access to a handle other than to have another instance explicitly pass one to it."* Textbook object-capability security: no ambient authority, no global namespace to reach for. A component never handed a socket handle cannot open a socket regardless of its code. *(Emerging concern under WASIp3's async model: concurrent borrows of the same handle create TOCTOU risk — **LOW**, single secondary source.)*

**Zed (HIGH):** Rust → `wasm32-wasip2`, Wasmtime, both sides generated from the same `.wit`. The host API is a narrow, explicitly enumerated surface:

```
resource worktree {
  id: func() -> u64;
  root-path: func() -> string;
  read-text-file: func(path: string) -> result<string, string>;
  which: func(binary-name: string) -> option<string>;
  shell-env: func() -> env-vars;
}
```

Zed states the limits outright: > *"There's no support for modifying the UI to create new panels, or making arbitrary HTTP requests, or touching the file system how you want. It's limited."* The API is **versioned**; `extension.toml` records the compiled-against version and the host checks it at instantiation, supporting several versions simultaneously.

**The design move: don't grant capabilities — grant a hand-written API. The capability set *is* the API surface.** Note the instructive exception: `shell-env()` and `which()` leak host environment info. **Even a tight surface leaks if you are not deliberate.**

**Chrome MV3 (HIGH)** — four manifest keys, and the split is the lesson:

| Key | Granted | Notes |
| --- | --- | --- |
| `permissions` | install time | API-name strings; many render an install warning |
| `optional_permissions` | **runtime**, via `chrome.permissions.request()` | |
| `host_permissions` | install time | URL match patterns |
| `optional_host_permissions` | runtime | same, deferred |

Warnings are string-mapped per permission (`"clipboardRead"` → *"Read data you copy and paste."*). Changing `host_permissions` **re-triggers warnings on update** — an anti-scope-creep mechanism. And **`activeTab`** grants > *"temporary access to the active tab through a user gesture"* — a capability scoped to **gesture + object + invocation**, the most elegant idea in the whole model.

**macOS App Sandbox / TCC / Hardened Runtime (MEDIUM — Apple's pages are JS-rendered and could not be quoted; substance from secondary sources):**

- App Sandbox is opt-in per app via `com.apple.security.app-sandbox`; entitlements re-grant narrow capabilities. Security-scoped bookmarks persist user-granted file access.
- **TCC is orthogonal to the sandbox** — user *consent* for privacy-sensitive resources, prompted at first use, revocable in System Settings, applying to sandboxed and unsandboxed apps alike.
- Hardened Runtime by default blocks JIT, ignores `DYLD_*`, and refuses unsigned libraries. Escape entitlements form a **strictly widening cascade**: `allow-jit` (narrowest — `MAP_JIT` pages only) → `allow-unsigned-executable-memory` → `disable-executable-page-protection` (widest). **Set exactly one.** `disable-library-validation` and `allow-dyld-environment-variables` are separate and are the classic dylib-injection vectors.

> **This directly indicts Muxy's configuration (§1.2).** `MuxyExtensionHost.entitlements` sets `allow-jit` **and** `allow-unsigned-executable-memory` **and** `disable-library-validation` — two levels of the widening cascade plus the injection vector — with **no `app-sandbox` at all**. Tessera should set at most one cascade entitlement, and ideally none.

**Critical constraint for Tessera (HIGH):** running AI-generated TS on any JIT engine (V8, JSC, SpiderMonkey) requires `allow-jit` at minimum, widening Tessera's own hardened-runtime posture. **A non-JIT interpreter (QuickJS) or a WASM engine avoids that entitlement entirely.** This is a concrete, macOS-specific argument for the Figma/Zed approach, independent of the sandbox-escape argument.

*(Note: `sandbox-exec` / Seatbelt is deprecated for third-party developer use, though Anthropic's Claude Code uses it anyway — see §4.7. Treat it as usable-but-unsupported.)*

**npm supply chain 2025–2026 (HIGH on outline, MEDIUM on counts):**

- **2025-09-08:** maintainer phishing compromised `debug`, `chalk` and ~18 others — billions of weekly downloads.
- **2025-09-15 — Shai-Hulud**, the first *self-propagating* npm worm. A postinstall script harvested credentials, exfiltrated to attacker-created public GitHub repos, and **republished itself into every package reachable with any npm token found in the environment.** Confirmed victims include `@ctrl/tinycolor` (2.2M weekly).
- **Nov 2025 — Shai-Hulud 2.0:** ~25,000 malicious repositories across ~350 GitHub users.
- **Early 2026 — "Mini Shai-Hulud"** hit TanStack npm packages. **(MEDIUM.)**

**Implication (HIGH): if a Tessera plugin can `npm install` at runtime, or if generated plugins import from npm, the sandbox must cover *install time*, not just execution.** Deno's `--allow-scripts` default-off is the right default; **no runtime package installation at all** is better.

### 4.6 The actual threat model: prompt injection

**Simon Willison, "The lethal trifecta for AI agents" (2025-06-16) — HIGH.** The three capabilities are **(1) access to private data, (2) exposure to untrusted content, (3) the ability to externally communicate.** Any two are safe; all three in one context is exploitable with no traditional vulnerability. Why filtering cannot fix it: > *"LLMs are unable to reliably distinguish the importance of instructions based on where they came [from]."* A 95%-effective guardrail is a failure in a security context.

**This is exactly Tessera's problem.** A terminal plugin that can read terminal output holds capability (2) *by definition* — `curl` bodies, `git log` messages, CI output, MOTDs, package-manager warnings, and even filenames are all attacker-influenceable. Add scrollback access (1) and `fetch` (3) and a single plugin holds the full trifecta.

**Muxy's `panes.readScreen` + `http.fetch` is exactly this combination** (§1.2). Muxy gates both behind runtime consent, which is a real mitigation — but it is a *prompt*, and the user approving "read this pane" is not thinking about the `api.example.com` grant they approved last week.

**Anthropic, "Mitigating the risk of prompt injections in browser use" (2025-11-24) — HIGH.** Three layers: RL training against injections, classifiers scanning untrusted content, and red teaming. Best measured result: **~1% attack success rate** for Claude Opus 4.5 against an internal adaptive Best-of-N attacker. Their own caveat:

> "A 1% attack success rate—while a significant improvement—still represents meaningful risk. No browser agent is immune to prompt injection, and we share these findings to demonstrate progress, not to claim the problem is solved."

**Do not rely on a classifier. Rely on structure.**

### 4.7 Anthropic's Claude Code sandbox — the most directly applicable engineering

**Two independent layers, and the docs are emphatic you need both (HIGH):**

> "Effective sandboxing requires both filesystem and network isolation. Without network isolation, a compromised agent could exfiltrate sensitive files like SSH keys. Without filesystem isolation... a compromised agent could backdoor system resources to gain network access."

**Filesystem layer.** macOS: `sandbox-exec` with dynamically generated **Seatbelt** profiles. Linux/WSL2: **bubblewrap** + a **seccomp BPF** filter blocking Unix socket creation at the syscall level. Windows: a dedicated user + **WFP** egress filters + NTFS ACLs. Enforced at the OS level, so **all child processes inherit it** — precisely the property Deno's `--allow-run` lacks.

**The asymmetric precedence rule is genuinely good design:**

- **Read** is *deny-then-allow*: readable by default; deny broad regions, then re-allow narrower paths.
- **Write** is *allow-only*: everything denied unless granted; deny beats allow.
- But an **exact** deny holds inside a wider allow, > *"so a broad allow can't silently re-expose a secret."*

**Network layer.** No domains pre-allowed. An **out-of-sandbox HTTP proxy** (plus SOCKS5 for non-HTTP TCP) enforces a domain allowlist; first use of a new domain prompts, and approval lasts the session.

**Credential masking — steal this (HIGH).** A credential can be set to `mode: "deny"` (unset/block) or **`mode: "mask"`**: the sandboxed process sees a per-session **sentinel** value, and the proxy substitutes the real credential on the wire only for listed inject-hosts. > *"The command and anything it logs never hold the real credential, but its requests still authenticate."* It fails **closed** if misconfigured. Critically, **`mask` entries are honored only from user/managed/CLI settings — never from a repo's project-local config**, because a checked-out project must not be able to authorize sending your real token somewhere.

**Anti-self-modification (HIGH).** The sandbox auto-denies writes to its own settings at every scope and to the managed settings directory — and **resolves symlinks** on those deny rules so a symlinked settings file cannot be edited through the link. (This was shipped as a patch in v2.1.210, meaning someone found the hole. **Build it in from day one.**)

**The documented limitations are the honest part, and the part to internalize:**

- The default proxy does **not** terminate TLS, so allow decisions rest on the client-supplied hostname: > *"code running inside the sandbox can potentially use domain fronting or similar techniques to reach hosts outside the allowlist."* Allowing broad domains like `github.com` *"can create paths for data exfiltration."*
- Allowing a Unix socket such as `/var/run/docker.sock` *"effectively grants access to the host system."*
- Broad write grants to `$PATH` dirs or `.bashrc`/`.zshrc` = privilege escalation on next run.
- macOS `allowAppleEvents` *"removes code-execution isolation."*
- Go-based CLIs (`gh`, `gcloud`, `terraform`) fail TLS verification under Seatbelt; `docker` and `watchman` are outright incompatible. **Real-world sandboxes leak exceptions.**
- Overall framing: > *"Sandboxing reduces risk but is not a complete isolation boundary."*

**OpenAI Codex (MEDIUM, secondary):** Seatbelt on macOS, Landlock + seccomp on Linux. Three modes: `read-only`, `workspace-write` (default), `danger-full-access`. **Network is off by default and is a separate toggle from filesystem write.** Codex sandboxes *its tool calls*, not itself. A known bug has macOS Seatbelt silently ignoring `network_access = true` — a reminder that **fail-open/fail-silent misconfiguration is a real class here**.

**Isolation tiers (MEDIUM/LOW — 2026 writing on this is SEO-contaminated; treat all specific numbers as unverified):** consistent ordering across sources is microVM (Firecracker/Kata) > gVisor > container/runc > in-process VM. **For a local macOS terminal app microVMs are the wrong shape** — startup latency and the absence of Firecracker on macOS make it a non-starter. Tessera's realistic tiers are **QuickJS/WASM in-process** or **separate OS process + Seatbelt**.

### 4.8 Comparison table

| Model | Granularity | Enforcement point | Runtime revocable? | Escape hatches | Consent UX |
| --- | --- | --- | --- | --- | --- |
| **Deno** | Per-capability + per-resource (path, host:port, env wildcard, command, lib) | Runtime, inside the JS engine op layer, per-process | ✅ `revoke()`; `onchange` + `partial` observable | `--allow-run` ("essentially invalidates the sandbox"), `--allow-ffi`, `LD_*`/`DYLD_*`, static module graph unchecked, `eval` at same privilege | CLI flags; TTY prompt at narrowest scope; named sets in `deno.json`; `--no-prompt` |
| **Figma** | Two-world **structural** split + `networkAccess.allowedDomains` (scheme/host/wildcard/**path**) + `permissions[]` + `documentAccess` | Sandbox: **separate VM** (QuickJS-in-WASM). Network: manifest allowlist at host | ❌ manifest-static | 2019 Realms version had object-confusion escapes (fixed by changing VM); iframe frame-rendering carve-out | Install-time review + published **`reasoning`** string; justification **required** for `"*"` |
| **Muxy** | Coarse verb groups (`git:write`, `panes:read`) + argument-sensitive checks | Single Swift bridge boundary (socket + WKWebView handlers) | Rules editable in Settings; per-verb "blocked" supersedes | **No OS sandbox at all**; `exec` is gated but ambient-authority; `contentWorld: .page` | Runtime consent showing literal payload; 4-way allow/deny × remember; 60 s timeout = deny; full audit log |
| **Raycast** | **None** | V8 isolate per extension = *fault* isolation only; registered-message JSON-RPC | ❌ | Full Node privileges: fs, net, subprocess | macOS TCC at the **app** level, not per extension; trust = mandatory open source + human review |
| **VS Code** | **None** | None — *"same permissions as VS Code itself"* | ❌ | Everything | Publisher trust dialog (1.97+), verified publisher, Marketplace signature, Workspace Trust |
| **Chrome MV3** | Per-API string + per-URL match pattern; install-time vs runtime split | Browser process, per-extension | ✅ `permissions.remove()`; revocable in UI | Broad `host_permissions` ≈ everything on the web | Mapped human-readable warnings; runtime `request()` behind a gesture; **`activeTab` = gesture + tab + invocation**; re-warn on expansion |
| **Zed / WASI p2** | The **API surface itself** is the capability set; unforgeable handles | Wasmtime, Component Model type system | N/A — revoke = drop the handle | No arbitrary fs/net/UI by design; `shell-env()`/`which()` leak host info | None needed — the surface is pre-narrowed; versioned API in `extension.toml` |
| **macOS Sandbox + TCC** | Entitlement categories + per-resource TCC consent | **Kernel** (Seatbelt) + TCC daemon | ✅ TCC revocable in System Settings; entitlements static per binary | `disable-library-validation`, `allow-dyld-environment-variables`, `disable-executable-page-protection` | TCC first-use prompt, per app, per resource — **best consumer consent UX in this table** |
| **Claude Code** | Path-level (asymmetric read/write) + domain allowlist + per-credential deny/mask | **OS kernel** — Seatbelt / bubblewrap+seccomp / WFP — **inherited by all children** | Session-scoped domain grants; policy files write-denied to the sandbox (symlink-resolving) | `dangerouslyDisableSandbox`, Unix sockets, `allowAppleEvents`, weaker-nested modes, **no TLS inspection → domain fronting** | Prompt on first new domain, session-scoped; managed settings for orgs |

### 4.9 A concrete permission model for Tessera

**Layer 0 — Structural (the load-bearing layer).** Split every plugin into two components with disjoint capabilities, Figma-style:

| | **Core component** (QuickJS/WASM, no JIT) | **View component** (WKWebView, isolated content world) |
| --- | --- | --- |
| Terminal state, scrollback, pane contents | ✅ | ❌ |
| Workspace/git/file APIs | ✅ (capability-gated) | ❌ |
| DOM, rendering | ❌ | ✅ |
| Network (`fetch`) | ❌ | ✅ (manifest-allowlisted) |

They communicate only over a **registered-message-only** channel (Raycast's fixed message set, not a generic RPC bridge). **No single component holds the lethal trifecta.** The half that reads attacker-influenceable terminal output has no egress; the half with egress cannot read scrollback.

**Layer 1 — Declarative manifest** in Deno-2.5 shape with Figma semantics:

```jsonc
{
  "capabilities": {
    "default": {
      "terminal": { "read": "invocation" },        // see Layer 2
      "files":    { "read": ["./src"] },
      "net":      { "allowedDomains": ["api.github.com/repos"] },
      "reasoning": "Reads the failing test output in the pane the user invoked me on and looks up the matching GitHub issue."
    }
  }
}
```

Rules: default is `["none"]` for network; **path-level** domain granularity; a **mandatory `reasoning` string** for any broad grant. That reasoning field is nearly free and is the single best affordance for AI-generated plugins — the model must state *why* it needs a capability, you show that sentence to the user, and you can **diff it across regenerations**. Schema uses `additionalProperties: false` (as Muxy already does) so a hallucinated capability name is a **load-time error, not a silent no-op**.

**Layer 2 — `activeTab` for terminal output.** Steal Chrome's best idea. Default terminal access is **gesture + pane + invocation**: a plugin gets the output of the pane the user explicitly invoked it on, for that invocation only. Standing scrollback access is a separate, loudly-justified capability. **This removes leg (1) of the trifecta for most plugins with no prompt at all.**

**Layer 3 — Host-boundary enforcement**, Muxy-style: one argument-sensitive `requiredCapabilities(verb, args)` function at a single Swift boundary, deny-by-default, with runtime consent for the dangerous set. Copy Muxy's consent UX wholesale — literal payload displayed, four-way allow/deny × remember, per-operation remember granularity (allowing `push` must not allow `discard`), **60-second timeout = deny**, rules in an app-owned file plugins cannot self-grant, and a rolling JSONL audit log.

**Layer 4 — OS sandbox underneath.** This is what Muxy lacks. Any sidecar process gets a Seatbelt profile; the app sets **at most one** hardened-runtime cascade entitlement (ideally none — achievable if the core is QuickJS/WASM rather than JIT). Network egress goes through an out-of-process proxy enforcing the manifest allowlist. Accept and document the known weakness: without TLS termination, hostname allowlists are defeatable by domain fronting, so a broad `github.com` grant is an exfiltration channel.

**Layer 5 — Credential masking.** Sentinel values in the plugin's environment; the egress proxy substitutes real credentials only for declared hosts; fail closed. Masking authorized only from user-level config, **never** from anything a plugin or checked-out project can write.

**Layer 6 — Audit-mode instrumentation.** Deno's `DENO_AUDIT_PERMISSIONS` equivalent: JSONL of every capability access. Run each generated plugin in audit mode, **diff observed use against the declared manifest**, and surface over-declaration and undeclared access. With AI-generated plugins you get a corpus large enough for this to be genuinely predictive in a way it never was for a human-authored marketplace.

**Layer 7 — Anti-self-modification.** Deny writes to Tessera's settings at every scope, **resolve symlinks** on those deny rules, and never honor capability-widening keys from plugin-writable locations.

**What Tessera should explicitly *not* build:** the Raycast/VS Code trust model. Review, signing, and publisher verification all assume a durable publisher identity and a reviewer. Neither exists when each user's plugins are generated on demand — and Wiz's finding (>100 live Marketplace PATs leaked *inside the extensions themselves*, able to push malicious updates to verified publishers' install bases) shows the anchor breaks even when the identity does exist.

---

## 5. Name Check: "Tessera"

### 5.1 Headline finding

> **There is already an actively-developed, open-source, macOS terminal workspace app called Tessera.**

**`horang-labs/tessera`** — *"Tessera — a workspace for organizing AI coding sessions across projects, collections, tabs, panes, and Git worktrees."* 277 stars, 28 forks, created **2026-04-29**, **last push 2026-07-22 (yesterday)**, AGPL-3.0, TypeScript/Electron, topics `developer-tools`, `coding-agent`, `tessera`. It ships Developer ID-signed and notarized macOS DMGs and publishes to npm as `@horang-labs/tessera` (0.2.1, 2026-07-13). It already has forks carrying the name: `younghai/tessera---terminal`, `skyiron/tesseraAI`. **(HIGH)**

This is not an adjacent collision. Same product category, same platform, same license posture, same name, shipped this month.

### 5.2 Namespace sweep

**GitHub — TAKEN (severely)**

| Repo | Stars | Status |
| --- | --- | --- |
| `horang-labs/tessera` | 277 | **Active**, pushed 2026-07-22, AGPL-3.0 — *the direct competitor* |
| `tessera-metrics/tessera` | 1,176 | Dormant since 2021-05-06 |
| `ucam-eo/tessera` | 652 | Active (satellite-imagery foundation model) |
| `zengxiao-he/tessera` | 588 | Active (LLM distillation engine) |
| `tessera-ui/tessera` | 256 | Active Rust GUI framework |
| `Consensys/tessera` | 196 | **ARCHIVED** |

**On Consensys/tessera specifically:** archived and read-only. Banner: *"This repository was archived by the owner on Jun 1, 2026."* README carried: *"⚠️ Project Deprecation ⚠️ ... Tessera is no longer supported."* Last release `tessera-24.4.2` (2024-06-12). **So the Ethereum Tessera is genuinely dead — but that is the one conflict that no longer matters, and every other one is alive. (HIGH)**

**GitHub org `tessera`: TAKEN** — the API returns type `Organization`, created 2014-03-04.

**npm**

| Package | Verdict |
| --- | --- |
| `tessera` | **TAKEN** — a tilelive-based tile server, v0.15.5, last publish 2024-07-21 |
| `create-tessera` | **TAKEN** — "Scaffold a new Tessera course", v0.4.2, published **2026-07-10** |
| `tessera-cli` | **AVAILABLE** (registry returns 404) |
| `@tessera/*` scope | Likely available, **UNCLEAR** — registry scope search returns 0, but npmjs.com/org/tessera returned 403 so org reservation could not be confirmed |

Adjacent scopes already claimed: `@tessera-ui/*`, `@tessera-llm/*`, `@tessera-network/*`, `@tessera-protocol/*`, `@usetessera/mcp` (2026-07-03), `@ciphera-net/tessera` (2026-07-21).

**crates.io — TAKEN, and the Rust UI framework hunch was correct**

- `tessera` — TAKEN (3D-Tiles geometric-error tool, v0.1.0, 2025-10-03; low activity but held).
- **`tessera-ui` — TAKEN and healthy.** *"A cross-platform declarative & functional UI library for rust."* v2.5.0, **42 releases**, 13,127 downloads, MIT OR Apache-2.0. Companion crates `tessera-ui-macros` and `cargo-tessera` exist. **(HIGH)**

**Homebrew — AVAILABLE ✅** The only clean namespace. Both `formulae.brew.sh/api/formula/tessera.json` and the cask equivalent return 404; local `brew search tessera` returns only `tesseract`.

**PyPI — TAKEN (abandoned)** `tessera` v0.10.0, last upload 2017-02-03. Dead, but PyPI does not reclaim names.

**Mac App Store — TAKEN (non-exclusive, no terminals)** At least six shipping apps: Tessera: Design Studio, Tessera 4, Tessera News – RSS Reader, Tessera: Block Puzzle Games, Tessera Memories, Tessera ARCI. None are terminals, but the name will not be distinctive in Spotlight or App Store search.

**Trademark — MEDIUM concern, partially UNVERIFIED.** USPTO TSDR, Justia, and uspto.report all returned **HTTP 403**; the following is from search snippets and **needs human or attorney confirmation**:

- **Tessera Technologies** (semiconductor/imaging IP) held TESSERA marks in **Class 9 and Class 42**. Corporate chain: Tessera Holding → **Xperi** (2017) → IP business spun out as **Adeia** (2022). Xperi materials still list Tessera as a trademark of Xperi Holding. **Current 2026 live/dead status could not be verified.**
- **Reg. No. 5418777 "TESSERA"** — registered 2018-03-06, reported status "Registered", covering *downloadable and non-downloadable computer software for skills assessment in education*. **This is a live Class 9 software mark.**
- Reg. No. 5179517 "TESSERA" — **CANCELLED** (Section 8), 2023-10-27.
- Tessera Therapeutics (biotech) — different class, low relevance.

Practical read: a free open-source dev tool is unlikely to draw an infringement action from Adeia/Xperi (different goods), but **at least one live Class 9 software registration exists**, which would complicate commercialization, an App Store trademark dispute, or any attempt to register the mark yourself.

**Domains — nearly all TAKEN** (whois run 2026-07-23)

| Domain | Verdict |
| --- | --- |
| `tessera.com` | TAKEN — created 1993-03-01 |
| `tessera.dev` | **TAKEN — parked & FOR SALE** (307-redirects to `afternic.com/forsale/tessera.dev`) |
| `tessera.app` | **TAKEN — live product.** An AI product-development platform in beta: *"Your AI builder doesn't know what you know. Yet."* **Adjacent to Tessera's space** |
| `tessera.io` | TAKEN — NameCheap, expires 2026-10-08, parked, no A record |
| `tessera.sh` | **TAKEN but in `redemptionPeriod`** — expired 2026-05-31, updated 2026-07-12. NXDOMAIN today; **may drop within ~30–45 days.** Worth watching, not currently available |
| `tessera.org` | TAKEN — expires 2034 |
| `tesseraterm.com` | **AVAILABLE ✅** |

**Other developer tools named Tessera:** the Tessera R "Divide and Recombine" environment (DARPA-funded, Purdue/PNNL, now dormant); Tessera UI (a *separate* JS component library at `@tessera-ui/*`); Tessera AI Project Generator (`tessera-ai.net`); Tessera Design Toolkit (`tessera-engineering.com`); Tessera by Brompton Technology (LED processing, ships a macOS installer). **No Databricks product by that name exists** — that lead was checked and found groundless. Adjacent naming hazard: **Tess — "Terminal for the new era"** at `tessapp.dev`.

### 5.3 Verdict

| Namespace | Verdict |
| --- | --- |
| GitHub repo `tessera` | TAKEN — incl. a direct competitor in the exact category |
| GitHub org `tessera` | TAKEN |
| npm `tessera` | TAKEN |
| npm `create-tessera` | TAKEN (active, 2026-07-10) |
| npm `tessera-cli` | AVAILABLE |
| npm `@tessera/*` | Likely available; org reservation UNCLEAR |
| crates.io `tessera` / `tessera-ui` | TAKEN / TAKEN (active) |
| Homebrew | **AVAILABLE** |
| PyPI `tessera` | TAKEN |
| Mac App Store | TAKEN (6+ apps) |
| USPTO Class 9 software | ≥1 LIVE mark; partially UNVERIFIED |
| tessera.dev / .app / .io / .com / .org | TAKEN |
| tessera.sh | TAKEN (redemption — may drop soon) |
| tesseraterm.com | AVAILABLE |

**Overall risk: HIGH.**

The disqualifying fact is not registry congestion — it is that `horang-labs/tessera` is an open-source macOS terminal/agent workspace with 277 stars, shipped this month, pushed yesterday. Launching a second one called Tessera means permanent SEO collision, GitHub-search collision, user confusion, and a strong chance of being read as a fork or clone. Every good distribution surface (`npm i tessera`, `cargo add tessera`, `brew install tessera` competing with six App Store apps, `tessera.dev`) is spoken for, so you would ship as `tesseraterm` or `tessera-cli` — a name you would be apologizing for in your own README.

**Alternative names** (directional only — **none have been namespace-checked**; run the same sweep before committing):

1. **Tesela** — Spanish for the same mosaic tile. Keeps the metaphor and phonetics, sheds the collisions.
2. **Smalti** — the colored glass tiles used in mosaics. Short, memorable, almost certainly unclaimed in dev namespaces.
3. **Opustile** — from *opus tessellatum*; "tile" reads naturally for a paned terminal.
4. **Vitrum** — Latin for glass; short, clean CLI verb (`vitrum split`).
5. **Cassone** — pleasant to type, no dev-tool baggage.

If the mosaic metaphor is the attachment, **Tesela** and **Smalti** preserve it at the lowest cost.

---

## 6. Historical recommendations for Tessera

This section records the 2026-07-23 recommendation set under its original premises. It is
not an implementation backlog. The current interaction boundary law classifies every new
surface before any runtime recommendation here is considered.

### 6.1 Plugin host architecture

**Primary recommendation: a two-world split — QuickJS (or WASM) core + WKWebView view — with a sidecar Bun/Node process reserved for the developer loop only. (Confidence: MEDIUM-HIGH on the structure, MEDIUM on QuickJS specifically, given the Swift-binding gap.)**

| World | Engine | Holds | Never holds |
| --- | --- | --- | --- |
| **Core** | QuickJS-ng in-process (no JIT), one runtime per plugin | Terminal state, scrollback, workspace/git/file APIs | DOM, network |
| **View** | WKWebView, **isolated `WKContentWorld`**, per-plugin `tessera-ext://<id>/` origin | DOM, rendering, manifest-allowlisted `fetch` | Terminal state, scrollback |

Rationale, in order of weight:

1. **Figma's controlled experiment.** A same-VM membrane sandbox built by an expert team, with the correct invariant documented, broke via object confusion in ~6 months. A separate VM held. For AI-generated code there is no publisher to hold accountable, so same-VM isolation is indefensible. **(HIGH)**
2. **The trifecta becomes structurally unreachable.** The component that reads attacker-influenceable terminal output has no egress; the component with egress cannot read scrollback. This is a *structural* defence, not a classifier — and Anthropic's own best number is ~1% attack success with an explicit refusal to declare the problem solved. **(HIGH)**
3. **It keeps Tessera's hardened-runtime posture tight.** A non-JIT interpreter means **no `allow-jit` entitlement at all** — versus Muxy, which ships `allow-jit` + `allow-unsigned-executable-memory` + `disable-library-validation` and no App Sandbox. **(HIGH)**
4. **Memory.** QuickJS is 367 KiB with a <300 µs runtime lifecycle, versus ~150–200 MB for a Node host (Raycast-measured). For a terminal that should feel lighter than an Electron competitor, this matters.

**Fallback, and the honest risk: there is no maintained Swift binding for QuickJS/quickjs-ng. (HIGH that none was found.)** QuickJS is a handful of dependency-free C files, so a SwiftPM C target is tractable — Muxy's `GhosttyKit` modulemap pattern (§1.1) is the template — but this is real, ongoing work on Tessera's critical path.

**If that binding proves too costly, fall back to a sidecar Bun/Node host structured exactly like Raycast v1:** one long-lived child process, **one worker thread (V8 isolate) per plugin** with heap caps and auto-termination, **JSON-RPC over stdio** read with `DispatchIO` on a serial queue, and a **closed set of registered message types**. This is the best-proven architecture in the space and by far the most AI-writable. Its costs are explicit: ~150–200 MB, the `allow-jit` entitlement, and — critically — **you cannot spawn a child into a tighter macOS sandbox than the parent** (`sandbox_init` is deprecated and undocumented), so enforcement must come from the runtime (Deno's scoped `--allow-*`) or from an out-of-process egress proxy.

**What to steal from Muxy regardless of engine choice:**

- The **separate-process** background host with a **per-launch capability token** handshake over a Unix socket (`identify|<id>|<token>`), a **`ParentDeathMonitor`**, and **`killpg` on the whole process group** at shutdown.
- The **per-extension custom URL scheme** with origin isolation (`url.host == extensionID`), symlink-resolving path-traversal defence, and asset size caps.
- **Live theme injection as CSS custom properties**, so "looks native" is the default.
- **Extensions disabled by default** after load.
- **SHA-256 integrity pinning** on install from a trusted registry.

**What to fix relative to Muxy:**

| Muxy | Tessera |
| --- | --- |
| `contentWorld: .page` — page JS can monkey-patch the bridge | **Isolated `WKContentWorld`**; expose only a frozen proxy to the page world |
| Sync API on background, async on pages | **One async API everywhere** |
| Three hand-written JS bridge generators | **One declarative API description** → runtime + `.d.ts` + JSON Schema + docs |
| No `.d.ts`, no types package | **Ship `@tessera/api`** with generated types |
| Manifest correctness depends on a hand-written `copy-manifest.mjs` | **Manifest emitted by the build tool**, or read from the package root |
| No OS sandbox at all | **Seatbelt profile + egress proxy** under the host boundary |
| `allow-jit` + `allow-unsigned-executable-memory` + `disable-library-validation` | **At most one cascade entitlement; ideally none** |

### 6.2 AI-writability: the design decisions that matter most

Tessera's differentiating goal is "an AI writes a working plugin first try." The research points at five concrete levers, roughly in order of impact:

1. **Types are the contract, and everything else is generated from them. (HIGH)** Muxy's entire extension system has **zero `.d.ts`** — authors work from Markdown and a JSON Schema. This is the single biggest opportunity. Generate the runtime bridge, the `.d.ts`, the manifest JSON Schema, and the docs from one declarative API description so they cannot drift.
2. **Copy Raycast's AI-tool shape. (HIGH)** *Tool = exported function + a single structured object parameter + **JSDoc** for model-facing semantics + an optional **confirmation** callback.* No new syntax, no schema DSL, no build-time codegen — and the confirmation callback is a permission primitive expressed as ordinary code. This was the most AI-writable plugin surface found anywhere in this research.
3. **Fail loudly at load time, never silently at runtime. (HIGH)** Keep Muxy's `additionalProperties: false` on the manifest, its directory-name-must-equal-package-name rule, and its contract test binding schema to loader. Extend the principle: a hallucinated capability name, a hallucinated API method, or an undeclared event must be a **load-time error with a suggestion**, not `undefined is not a function`. Remember the fabricated "Deno 3" article in §4 — models will confidently write against APIs that do not exist.
4. **One async API on every surface.** Muxy's sync-on-background / async-on-pages split is a documented, recurring footgun; an LLM that learned from the page examples writes `await` in a background script and vice versa.
5. **Adopt Raycast's versioning: no SemVer for plugins, synchronized app/API versions, and automatic code migrations ("mods"). (MEDIUM-HIGH)** Combined with generated types, this means a model writing against last month's docs gets migrated rather than broken.

Also worth adopting: a bundled **Agent Skill** (Muxy's `muxy-extension` SKILL.md pattern, self-updating via an npm script), an **`llms.txt` docs index with `/plain` raw-Markdown URLs**, and Raycast-style **evals** — integration tests for the generated-plugin path with `includes` / `matches` / `meetsCriteria` / `callsTool` matchers.

**And budget for the debugging tax.** Figma's cross-VM boundary produces *"truly impenetrable errors."* AI-generated code fails more often, and your iteration loop is a model reading a stack trace. **Source maps across the VM boundary and structured error marshalling are not polish — they are what makes iterative generation converge.**

### 6.3 Permission model

Adopt the seven-layer model specified in §4.9. In one sentence: **a structural two-world split so no component holds the lethal trifecta; a Deno-2.5-shaped declarative manifest with Figma's path-level domain allowlists and a mandatory `reasoning` string; Chrome's `activeTab` pattern for terminal-output access; Muxy's argument-sensitive single-boundary enforcement plus its consent UX and audit log; an OS-level Seatbelt sandbox and egress proxy underneath; Claude Code's credential masking and anti-self-modification rules; and Deno-style audit-mode instrumentation to diff observed capability use against the declared manifest.**

The one-line justification for the OS layer: Deno's own docs say *"When executing untrusted code, it is important to have more than one layer of defense,"* Anthropic's say filesystem and network isolation are both required and independent, and Muxy — the closest precedent — has exactly one layer.

### 6.4 libghostty strategy

**Copy the Muxy / `libghostty-spm` pattern from day one. (HIGH)** Maintain `<name>/ghostty` as a soft fork pinned to an upstream commit with in-tree patches; publish a dated `GhosttyKit.xcframework` release from the fork's own pipeline; have the app repo download and cache it keyed on the tag. **Do not put `zig build` in Tessera's CI.**

Accept up front: an API upstream calls `ghostty-internal` and documents as *"not for external use"*; **no tag to pin** (you pin a commit); **Zig 0.16.0 + Xcode 26** in the fork's pipeline; a canonical-URL move as Ghostty leaves GitHub; and `.unsafeFlags` in `Package.swift`, which permanently blocks Tessera from being consumed as a versioned SwiftPM library dependency.

### 6.5 Open risks

| # | Risk | Severity | Note |
| --- | --- | --- | --- |
| 1 | **The name "Tessera" collides with a direct competitor** shipping the same product on the same platform | **HIGH** | `horang-labs/tessera`, 277★, pushed 2026-07-22. Decide the name before anything else is branded |
| 2 | **No maintained Swift binding for QuickJS** | **HIGH** | On the critical path of the primary recommendation. Prototype this first; it is the go/no-go for the whole architecture |
| 3 | **libghostty is an unstable, self-declared-internal API with no tagged release** | HIGH | Mitigated but not removed by the fork strategy. Budget ongoing rebase work |
| 4 | **`allow-jit` regressions reported on ARM64 under macOS 26 Tahoe** | MEDIUM | Verify on target OS. Argues further for a non-JIT core |
| 5 | **Hostname allowlists are defeatable by domain fronting** without TLS termination | MEDIUM | Documented in Claude Code's own limitations. A broad `github.com` grant is an exfiltration channel |
| 6 | **Debugging across a VM boundary is genuinely bad** | MEDIUM | Figma's authors report "truly impenetrable errors." Directly threatens the AI-writability goal |
| 7 | **npm supply chain** (Shai-Hulud and successors) | MEDIUM | If plugins import from npm, the sandbox must cover *install* time. Prefer no runtime package installation |
| 8 | **Trademark: ≥1 live USPTO Class 9 software mark for TESSERA** | MEDIUM | **Unverified — USPTO/Justia returned 403.** Needs attorney confirmation if the name survives risk #1 |
| 9 | Whether Raycast v2 extensions still render natively or via WebView | LOW | Unresolved; would inform the reconciler decision if that path is taken |
| 10 | Ghostty's canonical repo URL is moving | LOW | Plan vendoring so a host change is a one-line edit |

### 6.6 Suggested sequencing

1. **Resolve the name.** It gates branding, domains, the GitHub org, and the npm scope.
2. **Prototype the QuickJS↔Swift binding.** This is risk #2 and determines the whole architecture. Timebox it; if it fails, fall back to the Raycast-v1-shaped Bun sidecar.
3. **Stand up the Ghostty fork + xcframework pipeline** in parallel — it is independent of the plugin decision and has a long lead time.
4. **Design the one declarative API description** and generate the bridge, `.d.ts`, schema, and docs from it *before* writing plugin APIs by hand. Muxy's three divergent generators are the failure mode to avoid.
5. **Build the audit-mode instrumentation early**, before the capability list stabilizes — it is what tells you whether the manifest model is right.

---

## Sources

### Muxy (read from source, commit `f520289`)

- https://github.com/muxy-app/muxy — `Package.swift`, `scripts/setup.sh`, `.github/workflows/checks.yml`, `GhosttyKit/module.modulemap`, `MuxyExtensionHost/{main,HostBridge,HostSocketClient,ParentDeathMonitor}.swift`, `MuxyExtensionHost/MuxyExtensionHost.entitlements`, `Muxy/Muxy.entitlements`, `MuxyShared/ExtensionBridgeJS.swift`, `MuxyShared/MuxyProtocol.swift`, `Muxy/Services/Extensions/*.swift`, `Muxy/Views/Extensions/ExtensionWebView.swift`, `docs/extensions/*.md`, `docs/extensions/schema/manifest.schema.json`, `Muxy/Resources/skills/muxy-extension/SKILL.md`, `Muxy/Resources/starter-kits/vanilla/`
- https://github.com/muxy-app/ghostty · https://api.github.com/repos/muxy-app/ghostty/releases
- https://muxy.app/ · https://muxy.app/llms.txt
- https://github.com/muxy-app/extensions

### libghostty

- https://github.com/ghostty-org/ghostty
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/build.zig.zon
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/include/ghostty.h
- https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h
- https://api.github.com/repos/ghostty-org/ghostty/contents/include/ghostty/vt
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/build/Config.zig
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/build/GhosttyLib.zig
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/build/GhosttyLibVt.zig
- https://raw.githubusercontent.com/ghostty-org/ghostty/main/HACKING.md
- https://api.github.com/repos/ghostty-org/ghostty/tags
- https://github.com/ghostty-org/ghostty/pull/8840
- https://github.com/ghostty-org/ghostty/discussions/10351
- https://ghostty.org/docs/install/release-notes/1-3-0 · https://ghostty.org/docs/about
- https://libghostty.tip.ghostty.org/
- https://mitchellh.com/writing/libghostty-is-coming
- https://mitchellh.com/writing/ghostty-leaving-github
- https://mitchellh.com/writing/everyone-should-know-simd · https://mitchellh.com/writing
- https://news.ycombinator.com/item?id=47207472 · https://news.ycombinator.com/item?id=45347117
- https://github.com/Uzaaft/awesome-libghostty · https://github.com/ghostty-org/ghostling
- https://github.com/Lakr233/libghostty-spm · https://github.com/mitchellh/go-libghostty
- https://crates.io/crates/libghostty-vt-sys · https://github.com/coder/ghostty-web
- https://github.com/xtermjs/xterm.js/issues/5686 · https://github.com/deblasis/wintty
- ⚠️ Flagged as unverified/likely false: https://lobehub.com/skills/plurigrid-asi-libghostty-vt

### Raycast

- https://www.raycast.com/blog/how-raycast-api-extensions-work
- https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast
- https://developers.raycast.com/information/security
- https://developers.raycast.com/information/manifest
- https://developers.raycast.com/information/developer-tools/cli
- https://developers.raycast.com/ai/learn-core-concepts-of-ai-extensions
- https://manual.raycast.com/ai/model-context-protocol
- https://github.com/yetone/native-feel-skill

### Engines & runtimes

- https://bellard.org/quickjs/ · https://github.com/quickjs-ng/quickjs
- https://developer.apple.com/documentation/javascriptcore/jscontext
- https://developer.apple.com/documentation/webkit/wkusercontentcontroller
- https://developer.apple.com/forums/thread/821584 (allow-jit on macOS 26)
- https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- https://forums.developer.apple.com/forums/thread/747880 (child sandbox inheritance)
- https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/
- https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-dangerous-entitlements.html
- https://bun.com/docs/bundler/executables · https://github.com/oven-sh/bun/issues/29286
- https://docs.rs/deno_core/latest/deno_core/ · https://deno.com/blog/roll-your-own-javascript-runtime
- https://github.com/bytecodealliance/ComponentizeJS
- https://component-model.bytecodealliance.org/language-support/building-a-simple-component/javascript.html
- https://github.com/facebook/hermes/tree/static_h
- https://github.com/SusanDoggie/SwiftJS (archived 2026-04-03)
- https://medium.com/@_alastair/to-jsc-or-not-to-jsc-running-javascript-on-ios-in-2020-6b68de99e326
- https://lucid.co/techblog/2019/01/03/javascriptcore-10-months-later/

### Permission & sandbox models

- https://docs.deno.com/runtime/reference/permissions/ · https://docs.deno.com/runtime/fundamentals/security/
- https://docs.deno.com/api/deno/permissions/ · https://deno.com/blog/v2.5
- https://deno.com/blog/deno-protects-npm-exploits · https://deno.com/blog/clawpatrol
- https://github.com/denoland/deno/releases/tag/v2.9.3
- https://www.figma.com/blog/how-we-built-the-figma-plugin-system/
- https://www.figma.com/blog/an-update-on-plugin-security/ · https://madebyevan.com/figma/an-update-on-plugin-security/
- https://developers.figma.com/docs/plugins/how-plugins-run · https://developers.figma.com/docs/plugins/manifest/
- https://macwright.com/2024/03/29/figma-plugins
- https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security
- https://www.ndss-symposium.org/wp-content/uploads/2024-73-paper.pdf (UntrustIDE, NDSS 2024) · https://github.com/s3c2/UntrustIDE
- https://www.wiz.io/blog/supply-chain-risk-in-vscode-extension-marketplaces
- https://www.darkreading.com/application-security/fresh-glassworm-vs-code-extensions-supply-chain
- https://thehackernews.com/2025/11/vibe-coded-malicious-vs-code-extension.html
- https://vscode-docs.readthedocs.io/en/stable/extensions/our-approach/
- https://github.com/WebAssembly/WASI · https://zed.dev/blog/zed-decoded-extensions
- https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions
- https://developer.chrome.com/docs/extensions/reference/permissions-list
- https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle
- https://github.com/obsidianmd/obsidian-help/blob/master/en/Extending%20Obsidian/Plugin%20security.md
- https://developer.apple.com/documentation/security/app-sandbox · https://developer.apple.com/documentation/security/hardened-runtime
- https://support.apple.com/guide/security/protecting-app-access-to-user-data-secc71ee5a1c/web
- https://unit42.paloaltonetworks.com/npm-supply-chain-attack/ · https://www.wiz.io/blog/shai-hulud-npm-supply-chain-attack
- https://www.stepsecurity.io/blog/mini-shai-hulud-is-back-a-self-spreading-supply-chain-attack-hits-the-npm-ecosystem
- ⚠️ Rejected as fabricated: `pkgpulse.com/guides/deno-3-new-features-npm-compatibility-2026`

### AI code & agent sandboxing

- https://code.claude.com/docs/en/sandboxing · https://github.com/anthropic-experimental/sandbox-runtime
- https://www.anthropic.com/research/prompt-injection-defenses
- https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- https://github.com/openai/codex/issues/10390

### Name check

- https://github.com/horang-labs/tessera · https://api.github.com/repos/horang-labs/tessera
- https://github.com/Consensys/tessera · https://api.github.com/repos/Consensys/tessera
- https://github.com/tessera-ui/tessera · https://crates.io/crates/tessera-ui · https://tessera-ui.github.io/
- https://github.com/tessera-metrics/tessera · https://github.com/ucam-eo/tessera · https://github.com/zengxiao-he/tessera
- https://api.github.com/users/tessera
- https://registry.npmjs.org/tessera · https://registry.npmjs.org/tessera-cli · https://registry.npmjs.org/create-tessera
- https://crates.io/crates/tessera
- https://formulae.brew.sh/api/formula/tessera.json · https://formulae.brew.sh/api/cask/tessera.json
- https://pypi.org/project/tessera/
- https://apps.apple.com/us/app/tessera-design-studio/id6756501042 · https://apps.apple.com/us/app/tessera-4/id6755889432 · https://apps.apple.com/us/app/tessera-news-rss-reader/id6761110696
- https://trademarks.justia.com/869/09/tessera-86909494.html (403) · https://www.trademarkelite.com/trademark/trademark-detail/88642455/TESSERA
- https://investor.xperi.com/news/news-details/2017/Tessera-Holding-Corporation-Announces-Name-Change-to-Xperi-Corporation/default.aspx
- https://tessera.app · https://tessera.dev · https://tessapp.dev/
- https://tessera-ai.net/ · https://tessera-engineering.com/integrations.html

---

## Explicitly Could Not Verify

- npm weekly download count for `tessera`; whether the npm `@tessera` org is reserved without published packages (npmjs.com returned 403).
- Current 2026 live/dead status of the Xperi/Adeia TESSERA Class 9 and 42 registrations — USPTO TSDR, Justia and uspto.report all returned 403. **All trademark findings are from search snippets and need attorney confirmation.**
- Whether **Raycast v2 extensions still render to native AppKit** or now render into the WebView; and Raycast's stated reason for abandoning their original "XPC host + many JavaScriptCore engines" design.
- Any latency number for Raycast's IPC/render path (they say "surprisingly fast", publish nothing).
- Figma's QuickJS-vs-Realms performance delta (acknowledged as "somewhat slower", no benchmarks published).
- Per-context memory footprint for QuickJS (Bellard publishes binary size and lifecycle time, not per-runtime RSS).
- **A maintained Swift binding for QuickJS/quickjs-ng — none found.** (HIGH that none was found; MEDIUM that none exists.)
- Reproducible Node/Bun/Deno startup benchmarks — only comparison blogs.
- That **no tagged libghostty release exists** — this is negative evidence (no tag, no repo, no release note, no blog post) rather than a positive statement.
- Whether anything newer about libghostty was posted to X/Mastodon/Discord, none of which could be fetched.
