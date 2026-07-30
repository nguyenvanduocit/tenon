# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tenon is the human supervision layer for parallel CLI-agent work, built as a terminal-first
native macOS workspace. Agents keep their native harness behavior and execute in real PTYs;
Tenon preserves shared context, directs scarce human attention, and returns every condensed
claim to inspectable evidence. Its independently installable, hot-reloadable JavaScript
plugin boundary adapts changing agent tools without moving their execution semantics into
the host. Host-native terminal, workspace, surface, and settings behavior uses typed Swift
services; plugins extend that product through the canonical public boundary. Pre-alpha;
Phase 0 (plugin-host spike) is complete.
**VISION.md is the product north star; `docs/architecture-interaction-boundaries.md` is
normative for interaction mechanism selection.**

- `poc/` — Phase 0 spike: Swift package proving the plugin loop (host + manifest + hot reload + plugins driving UI).
- `docs/research-plugin-runtimes.md` — historical runtime/sandbox evidence written under
  the former name “Tessera.” Its old architecture recommendations are non-normative.
- `docs/naming.md` — naming decision record. If a new name is ever needed for anything public (packages, orgs, domains), run the sweep battery there before proposing.

## Commands

All commands run from `poc/`:

```bash
./scripts/setup-ghosttykit.sh   # once per clone: downloads the pinned GhosttyKit.xcframework (~130 MB)
swift run tenon         # build + launch the app (opens a window; needs a GUI session)
swift test              # headless test suite, ~1s — the evidence bar for the PoC
swift test --filter testFailedReloadRetainsActiveSessionAndContributions   # single test by name
swift build             # compile check only
```

Environment variables: `TENON_STUB_TERMINAL=1` (stub terminal pane, no PTY — plugin loop unchanged), `TENON_PLUGINS_DIR=/path` (point the host at a different plugin folder), `TENON_TRUST_PLUGIN_INVENTORY=1` (stand that folder in for the app bundle so its plugins carry bundled standing consent instead of prompting; matched exactly — `true` leaves it untrusted). Standing consent is host-owned: the bundled inventory has it, a directory named by `TENON_PLUGINS_DIR` earns it only through that flag.

Builds live in two trees inside the gitignored `poc/.build`: `arm64-apple-macosx/`
(SwiftPM) and `xcode/` — one derived data path shared by every configuration. The
dependency graph is checked out once, into `checkouts/` + `repositories/`, which every
`xcodebuild` invocation reads by carrying `-clonedSourcePackagesDirPath .build`; omit
that flag and Xcode silently clones a second 616 MB copy. `./scripts/prune-build-cache.sh`
collects any other build tree that appears (`DEEP=1` drops both real ones too, keeping
the dependencies), and `../dev.sh` / `../install.sh` run it before they build, so the
cache stops at a few gigabytes instead of growing without bound.

No lint/format configuration exists yet.

## Architecture

**TDD is the working method here — read `docs/tdd.md` before adding a feature.** The loop: failing core test first, minimal core change to green, only then the shell, then a launch smoke check. The fitness test for any design: "can this rule be asserted in `TenonCoreTests` without a window?" If not, the rule is in the wrong layer.

The package is Swift 6 (`swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`) and has
four architectural targets:

- **`TenonIntentCore`** — runtime-independent invocation kernel: bounded `IntentValue`,
  canonical contracts/schema, principals/policy, provider generations/leases, dispatcher,
  admission, lifecycle, and discovery. It imports neither AppKit nor JavaScriptCore.
- **`TenonCore`** — headless workspace/domain model and plugin host. `Workspace` mutations
  are typed pure/domain operations emitting facts; `PluginRuntime` owns one isolated
  JavaScriptCore context per plugin generation; `PluginHost` owns manifests, activation,
  contributions, events, settings/storage, and hot reload. It imports no AppKit/SwiftUI.
- **`TenonApp`** — composition root and native adapters: SwiftUI/AppKit shell,
  `SurfacePool`, `PluginWebSurfacePool`, Ghostty/WebKit, user-prompt/system/workspace/
  terminal intent providers, and CLI socket adapter. Built-in UI calls typed application
  services DIRECT; public intent providers adapt to the same services.
- **`TenonCLI`** — Foundation/POSIX client for the local control socket. Its domain surface
  is `intent list/describe/send`; only ping and single-instance activation/focus are direct
  control plane.

**Interaction classification is mandatory.** Read
`docs/architecture-interaction-boundaries.md` before changing any interaction:
CONTRIBUTION → EVENT → RESOURCE/STREAM/TASK → same-owner DIRECT → exact SCOPED FACILITY
allowlist → cross-principal finite INTENT. `docs/design-intent-bus.md` specifies the kernel
only after the law selects INTENT.

A plugin is a directory under `poc/plugins/` with a stable full `id`, `manifest.json`, and
`main.js`. Its manifest declares permissions, `intents.uses`, `intents.provides`, settings,
and presentation metadata before JavaScript evaluation. Hot reload stages a replacement
generation, activates it atomically, drains the retired generation, and tears down its
calls/resources/contributions. A failed staged generation leaves the last good generation
active.

The exact public `tenon` vocabulary is:

- immutable runtime metadata: `apiVersion`;
- INTENT/control: `intents.send`, `intents.handle`, `intents.list`;
- closed SCOPED FACILITY: `settings.get`, `storage.get/set`, `log`;
- pure DIRECT JavaScript: `path.join/normalize/basename/dirname/extname`;
- EVENT: `events.on`;
- RESOURCE: `timers.after/every/cancel`, `process.stream`, `fs.watch`;
- CONTRIBUTION: `statusBar.set`,
  `views.register/set/onSelect/onSubmit/onOpen/onClose`.

Finite filesystem/process/workspace/terminal/browser/UI/secrets/network/clipboard/OS work
has no handwritten plugin helper; it uses declared canonical intents.

## Invariants — tests enforce these; do not weaken them

1. **Plugins see only the `tenon` global.** Nothing beyond `tenon` and the ECMAScript builtins may be reachable from plugin scope: `require`, `setTimeout` and `fetch` were never there, and `console` must not be — a plugin logging through it would reach os_log unattributed, around `tenon.log`'s per-plugin attribution. A new capability means a new member on `tenon`, never a new global. `testRuntimeExportsOnlyTheClassifiedPublicSurface` pins the members of `tenon`; closing `globalThis` itself is T-037, and until it lands this invariant is a rule the suite does not yet enforce.
2. **Plugins never touch native host types.** Terminal/WebKit/AppKit/Foundation-I/O state crosses only as bounded values, targeted events, contributions, resource handles, or intent results.
3. **`TenonCore` imports no AppKit or SwiftUI.** UI concerns live in `TenonApp` only.
4. **A broken plugin never takes down the host** (`testBrokenPluginIsReportedAndDoesNotKillHost`). It is logged, marked failed, and reloads itself when fixed.
5. **One policy path.** Exact manifest use/provision, audience, capability, scope, consent, provider eligibility, and admission are separate fail-closed checks in the intent policy/dispatcher path. Naming an intent never grants authority.
6. **One typed semantic implementation.** Same-owner host UI calls typed services DIRECT; public adapters use intent providers that call those services. Two public protocols for one operation are forbidden.
7. **The scoped-facility allowlist is closed:** settings, plugin-private storage, and log. `tenon.path.*` is pure local code. Every other finite plugin→host operation defaults to INTENT.
8. **Core intent audiences are exact:** `{plugin, cli, agent}` or `{plugin}`. Palette and registered product keybindings project plugin-owned intent metadata. Such a keybinding is host-wide, discoverable, or rebindable outside one focused view. Focused-view keyboard controls without public command registration are same-owner DIRECT/local control. Built-in app UI has no generic app intent principal.
9. **Uniform plugin boundary.** Every plugin runtime, bundled or third-party, receives the
   same exact public surface and plugin principal rules. Every sent/handled intent is
   declared in the manifest. Host-native Swift stays typed DIRECT because it shares one
   semantic owner; it does not impersonate a plugin. Functions inside one plugin generation
   call each other directly; intents are its external contracts, not its internal module
   system.
10. **Every queue, payload, lifetime, and generation is bounded.** Runtime retirement settles calls once, cancels resources, removes contributions/subscriptions, and cannot callback into a destroyed context.

## Design tenets that shape product and API review

From VISION.md, the product tests that most often decide whether a change is right:

- **Scalable human judgment.** A supervision surface must reduce the time required to
  understand what changed, what needs attention, and what can safely wait without reducing
  correctness as concurrent work increases.
- **Evidence-linked compression.** Context capsules and attention signals are navigation
  aids. Every material claim carries source, freshness, and a direct return path to the
  transcript, diff, command result, test receipt, or other represented evidence.
- **Harness-adaptable public boundaries.** Agent execution remains in its CLI/PTy owner.
  Public plugin contracts let adapters and supervision experiments evolve without private
  host paths or duplicated domain semantics.

Two enabling constraints keep those product surfaces changeable:

- **AI-writable APIs.** A language model can read the docs and write a working plugin on the
  first try. One async API shape is used on every surface; load-time errors offer
  suggestions instead of silent `undefined`.
- **Replaceable plugins.** A plugin can be disabled, reloaded, or replaced without
  corrupting host state. The terminal workspace remains useful with no optional plugins
  installed.

## Verification

The GUI cannot be screenshotted from a headless shell, so `swift build` + `swift test` are the evidence bar. `ShippedPluginsTests` copies the real `plugins/` directory into a temp dir and exercises the actual shipped `clock` and `hello-palette` JS — including a genuine on-disk edit that must propagate through FSEvents into host state. When you change plugin-host behavior, extend those tests rather than relying on manual app runs.

## Workflow — one branch, many agents on `main`

All work happens directly on `main`. There are no worktrees and no feature branches: every agent — interactive or autonomous — edits, tests, and commits on the same `main` checkout. This is deliberate. The isolation a branch would give is bought instead with the live coordination signals below, so agents stay out of each other's way while sharing one tree.

Because several agents run in parallel on that one working tree:

- **Foreign dirty changes are normal.** `git status` will show edits you did not make — another agent is mid-task. Leave them untouched: never stash, revert, discard, or commit someone else's work, and don't be thrown by them. Stage and commit only the files you yourself touched.
- **Claim your work through the board before you touch a file.** `.kanban/` is the shared session channel where agents tell each other what they're doing. Before starting: read `.kanban/board.md` and open every task in `Doing` to see who is working where. Then move your task into `Doing` (WIP limit = 2) and, in its task file, list the files you are about to change under an `## Owner / files (agent lock)` heading with your session id. That heading is how other agents see, at file granularity, what is already spoken for.
- **Overlap → coordinate, don't collide.** If a file you need is already claimed in another `Doing` task, take different work, wait for the claim to clear, or split the change so your edits and theirs don't overwrite each other. Two agents editing the same lines on one branch is exactly the collision this protocol exists to prevent — check first, then write.
- **Release when done.** When your task leaves `Doing`, the claim is gone: clear its `Owner / files` list (or archive the task) so those files are free again, and update `.kanban/board.md` per the session-end step below.
- **Moving a task is a delete plus an insert.** A task line lives in exactly one column. Adding your line to `Doing` without removing the one you left behind puts the same task in two columns, and the stale copy reads as free work — another agent will pick up what you are already doing. Grep the board for your task id after you move it; the answer must be `1`.
- **Keep the shared test target compiling, even mid-red.** TDD here means a test that *fails*, not a test that fails to *build*. `poc/Tests/` is one target shared by every concurrent agent, so a test naming a type that does not exist yet takes `swift test` down for everyone and destroys their evidence, not just yours. Land the type and its empty or throwing members in the same edit as the test that names them, then let the assertions be the red.

Rule of thumb: the working tree is always live and shared, so read `.kanban/` before you write, keep it current while you work, and clear it when you finish.

<!-- kanban:start -->
## Task Board

!`bash .kanban/status.sh 2>/dev/null`

Board: `.kanban/board.md` (index) | Tasks: `.kanban/tasks/T-NNN-slug.md` | Archive: `.kanban/archive/`

**Session start:** Read `.kanban/board.md`. For Doing tasks, open their task files.
**Session end:** Update `.kanban/board.md` — move completed task lines to Done, note blockers, update timestamp.

**Board line format** (one per task):
```
- [T-NNN](tasks/T-NNN-slug.md) Title — priority/effort
```

**Task file format** (`.kanban/tasks/T-NNN-slug.md`):
```
# T-NNN: Title
> One-line description
- **priority**: critical|high|medium|low
- **effort**: XS|S|M|L

## Criteria
- [ ] Acceptance criterion
```

**Rules:** WIP limit = 2 in Doing. Pick highest-priority from Todo. Never skip criteria checkboxes. Slug is kebab-case from title, ≤40 chars.
<!-- kanban:end -->
