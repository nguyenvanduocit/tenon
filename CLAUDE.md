# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tenon is the human supervision layer for parallel CLI-agent work, built as a terminal-first
native macOS workspace. Agents keep their native harness behavior and execute in real PTYs;
Tenon preserves shared context, directs scarce human attention, and returns every condensed
claim to inspectable evidence. Its independently installable, hot-reloadable JavaScript
plugin boundary adapts changing agent tools without moving their execution semantics into
the host. Host-native terminal, workspace, surface, and settings behavior uses typed Swift
services; plugins extend that product through the canonical public boundary.
**VISION.md is the product north star; `docs/architecture-interaction-boundaries.md` is
normative for interaction mechanism selection.**

- `Sources/`, `Tests/`, `plugins/` — the macOS application: host + manifest + hot reload + plugins driving UI. `docs/development.md` covers its layout, setup, and build.
- `docs/research-plugin-runtimes.md` — historical runtime/sandbox evidence written under
  the former name “Tessera.” Its old architecture recommendations are non-normative.
- `docs/naming.md` — naming decision record. If a new name is ever needed for anything public (packages, orgs, domains), run the sweep battery there before proposing.
- `docs/reports/2026-08-11-cli-capability-survey.html` — 379 rows measuring `tenon-cli`
  against orca (223 commands) and herdr (80 socket methods, 24 push events), each "Tenon
  lacks this" cell already attacked by an agent paid to refute it. **Read it before you
  propose a CLI capability, and before you reject one.** It separates three things the raw
  count hides: what Tenon deliberately refuses (orchestration, browser, remote — `VISION.md:8-9`
  states the refusal), what a service already in the app can reach with one `cli`-audience
  catalog entry, and what is blocked behind PTY ownership living in the AppKit process. It is
  **dated evidence, not a status board**: it is never edited to stay current, and when it and
  the tree disagree the tree wins. Anything actionable in it becomes a `.kanban` task and a
  decision-log entry in the owning PRD — the report is where a claim came from, never where
  its status lives.

## Commands

All commands run from the repository root:

```bash
./tenon                 # every verb a person types, with one line each
./tenon dev             # build + launch the app (opens a window; needs a GUI session)
swift test              # headless test suite, ~1s — the evidence bar for every change
swift test --filter testFailedReloadRetainsActiveSessionAndContributions   # single test by name
swift build             # compile check only
```

`./tenon dev` fetches the pinned GhosttyKit.xcframework (~130 MB) on its first run.
`swift run tenon` goes around the verbs, so a clone that has never run one needs
`./scripts/internal/setup-ghostty.sh` before `swift run`, `swift build`, or `xcodebuild`
can find the framework.

Environment variables: `TENON_STUB_TERMINAL=1` (stub terminal pane, no PTY — plugin loop unchanged), `TENON_PLUGINS_DIR=/path` (point the host at a different plugin folder), `TENON_TRUST_PLUGIN_INVENTORY=1` (stand that folder in for the app bundle so its plugins carry bundled standing consent instead of prompting; matched exactly — `true` leaves it untrusted). Standing consent is host-owned: the bundled inventory has it, a directory named by `TENON_PLUGINS_DIR` earns it only through that flag.

Builds live in two trees inside the gitignored `.build`: `arm64-apple-macosx/`
(SwiftPM) and `xcode/` — one derived data path shared by every configuration. The
dependency graph is checked out once, into `checkouts/` + `repositories/`, which every
`xcodebuild` invocation reads by carrying `-clonedSourcePackagesDirPath .build`; omit
that flag and Xcode silently clones a second 616 MB copy. `./scripts/internal/prune-build-cache.sh`
collects any other build tree that appears (`DEEP=1` drops both real ones too, keeping
the dependencies), and `./tenon dev` / `./tenon install` run it before they build, so the
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

A plugin is a directory under `plugins/` with a stable full `id` and a `manifest.json`. The
manifest's `runtime` names the implementation: `javascript` (the default) evaluates a
`main.js` in an isolated JavaScriptCore context, and `bundled-swift` resolves an exact
compiled program that only the sealed app inventory may select. Every plugin Tenon ships is
`bundled-swift`; `main.js` is how third-party plugins are written, and they hot-reload on
save. The manifest declares permissions, `intents.uses`, `intents.provides`, settings,
automation schedules (wall-clock cadence fired back as the owner-scoped `automation.fired` event),
and presentation metadata before any implementation runs. Hot reload stages a replacement
generation, activates it atomically, drains the retired generation, and tears down its
calls/resources/contributions. A failed staged generation leaves the last good generation
active.

The exact public `tenon` vocabulary is:

- immutable runtime metadata: `apiVersion`;
- INTENT/control: `intents.send`, `intents.handle`, `intents.list`;
- closed SCOPED FACILITY: `settings.get`, `storage.get/set`, `log`;
- pure DIRECT JavaScript: `path.join/normalize/basename/dirname/extname`;
- intent-composing DIRECT JavaScript: `agents.run` — the supervised run-to-result loop
  over the caller's own declared `terminal.open/wait/scrollback.read` intents;
- EVENT: `events.on`, `events.emit` (plugin-published facts on channels the manifest
  declares; the host owns qualification, so a plugin can only publish under its own id);
- RESOURCE: `timers.after/every/cancel`, `process.stream`, `fs.watch`;
- CONTRIBUTION: `statusBar.set`,
  `views.register/set/onSelect/onSubmit/onOpen/onClose`,
  `palette.registerProvider/setResults/onQuery` (dynamic palette providers:
  registration and revision-scoped result snapshots are CONTRIBUTIONS, `onQuery`
  subscribes to owner-scoped palette query EVENTs).

Finite filesystem/process/workspace/terminal/browser/UI/secrets/network/clipboard/OS work
has no handwritten plugin helper; it uses declared canonical intents.

## Domain tags — the product ontology the code cannot derive

**`docs/domains.md` is the only place a domain may be declared**, and
`DomainTagFitnessTests` enforces every rule below. Read it before adding a source file or
editing a tagged one.

Every file under `Sources/` carries one tag above its imports. A file over 400 lines
(65 of 200 today, longest 2545) tags every `// MARK:` section too, on the MARK line:

```swift
// @domain: plugin-host, plugin-events
// MARK: - Loading and hot reload  @domain: plugin-host
```

Know what that second rule does *not* reach: it can only check a file that has MARK
sections, and 49 of those 65 long files have none — 41,879 lines, including the five
longest in the tree. There, one file tag stands for the whole file and locates nothing
inside it. A long file with no MARK is not a file that passed the rule; it is a file the
rule cannot see.

Why this layer exists at all: a call graph says who calls whom and a compiler keeps it
honest, but nothing in the source says which *product* concern a file serves — that is a
human judgement. And Swift hides even the technical half: files in one module see each other
without imports, so `rg '^import ' Sources/TenonCore` names only external modules and 155
files expose exactly one inter-module edge.

Why it is a test and not a convention: unchecked metadata rots. Measured here, 31 of ~35
populated `## Owner / files` blocks were stale against 2 tasks actually in `Doing` — ~89%,
with the obligation stated plainly in this file the whole time. `// MARK:` is the unit for
block tags precisely because it is *enumerable*; "a block" cannot be checked.

Use the fewest domains that are true. **More than two on one file is a split candidate**,
not a well-labelled file: those tag boundaries are the decomposition the file has not had.
`PluginHost.swift` carries five and is the standing example.

**When you are about to locate the code for a change, run step 1 before you grep a symbol
name.** That is the moment the layer pays, and the moment it is usually skipped: measured
across every session in this repo since the tags landed, 1 of 1766 Claude searches and 11 of
1228 Codex searches used a tag to find code, while 84% of every command that touched a tag
was maintaining the tag layer rather than querying it.

```
1. rg -l '@domain:.*plugin-host'                          → starting set
2. for each symbol that set touches: rg '\bSymbolName\b'   → the edges Swift hides
```

Expect what it actually delivers, so you neither skip it nor trust it. Scored against what
76 sessions really edited, step 1 hands you a median **13% of the tree** containing **54% of
the files you will end up changing** — better than any free heuristic (same directory reaches
61% but drags in 80 files; a filename-prefix grep reaches 28%). It is also why **step 2 is not
optional: 46% of what you need is outside the starting set.** No check detects a domain a file
*should* carry but does not — exactly the failure tagging exists to reduce — so a tag narrows
where to start and never certifies completeness. Stopping at step 1 trades a silent omission
for a confident one.

Adding a domain means adding it to `docs/domains.md` with an Excludes line in the same change
as the file that uses it; a declared domain matching no file fails the suite. Every source file
is tagged today and `untaggedFileBudget` is **0** — a new file without its tag turns the suite
red for every concurrent agent, and the fix is one line above the imports.

Two of the seven assertions are ratchets, both at their current count and both meant to reach
zero: `isolatedTagBudget` (**8**) holds files whose domain appears in nothing they reference
and nothing referencing them, and `unsectionedLongFileBudget` (**49**) holds long files with
no MARK to tag. Neither can prove a tag is *right* — one of the three false tags T-106 found
by hand is all the isolation check catches, because a file can share code with a domain it
has no business claiming. Reading the file against `docs/domains.md` is still the only thing
that settles it.

## Invariants — tests enforce these; do not weaken them

1. **Plugins see only the `tenon` global.** Nothing beyond `tenon`, the ECMAScript builtins, and the `__tenon*` host-call hooks may be reachable from plugin scope: `require`, `setTimeout` and `fetch` were never there, and the bootstrap deletes `console` — a plugin logging through it would reach os_log unattributed, around `tenon.log`'s per-plugin attribution. The `__tenon*` hooks are the host's call channel into the generation, non-configurable and non-writable; invoking one can only disturb the calling plugin's own generation (decision recorded in T-037). A new capability means a new member on `tenon`, never a new global. `testRuntimeExportsOnlyTheClassifiedPublicSurface` pins the members of `tenon`, and `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` pins `Object.getOwnPropertyNames(globalThis)` to exactly that closed set, so a new global — from a future JSC or from our own bootstrap — fails the suite.
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

## Nothing is grandfathered — old code keeps its place by earning it

Code, schemas, and structures hold their place because they still serve VISION.md and the
owning PRD, not because they were written first. When a foundation stops carrying the
direction the product is going, the foundation is what changes: a new layer stacked on a wrong
one is debt paying interest to itself, and every later change pays it again. This repository
has already done the harder version of that — the v0.2 capability helpers, command registry,
sidebar surface, and imperative workspace namespace were deleted outright, with no
compatibility shim and a migration guide written to carry plugin authors across
(`docs/plugin-migration-v0.2.md`).

- **Root cause, not the way around it.** A workaround buys today's diff at the price of every
  future diff in that area. When the honest fix is the bigger edit, take the bigger edit and
  record why in the owning PRD's decision log.
- **Understand it, then remove it.** `git blame`, `git log -S`, the commit that introduced it,
  and the test still covering it explain why a thing exists. Explain it and the deletion is
  clean. Unable to explain it → say what you don't understand and leave it standing; that is
  the one case where old code wins, and it wins only until someone reads it properly.
- **Replacement finishes.** No shim, no deprecated alias, no dead branch kept "just in case",
  no second code path shadowing the real one. What the tree owes is to read as if the new
  design had always been there. Documents follow their own rule in `docs/prds/README.md` — a
  superseded doc becomes a pointer or clearly labelled history, because how we got here is
  worth keeping in a way a dead code path never is.
- **Structural smells get named and split.** More than two `@domain:` tags on a file is the
  decomposition that file has not had, and `PluginHost.swift` carries five as the standing
  example. The same goes for a function that needs "and" to describe it, two public paths
  doing one semantic job (invariant 6), and indirection that saves five lines of writing and
  costs ten minutes of reading.
- **A rewrite is claimed like any other work.** Several agents share this tree, so a broad
  restructuring goes into `.kanban/` with its files listed before the first edit, and its
  rationale into the owning PRD. An unclaimed heroic refactor overwrites work in flight, which
  adds debt rather than clearing it.

What makes this safe rather than reckless is already in place: a suite that runs in about a
second, tests that assert behavior instead of shape, and a PRD that states what must stay
true through the change. Rewriting something old is then an ordinary Tuesday, not a gamble.

## Verification

`swift build` + `swift test` are the evidence bar. `ShippedPluginsTests` reads the real `plugins/` inventory: it pins the ten shipped identities, stages every compiled runtime and asserts each one binds exactly the providers its manifest declares, and reads every plugin's own Swift sources for versioned intent IDs the manifest never declared. The JavaScript boundary is exercised by `PluginHostTests` and the other host suites, which write throwaway JS plugins into a temp inventory and drive real generations through it — that is where third-party plugin behaviour is proved now that no shipped plugin is JavaScript. Know the one gap: those suites call reload directly, so `PluginWatcher.swift` — the FSEvents path that decides *when* a reload happens — has no test naming it, and an edit that never reaches the host would look identical to a passing suite. When you change plugin-host behavior, extend those tests rather than relying on manual app runs.

A **window** cannot be screenshotted from a headless shell — this process has no Screen Recording grant and `screencapture` fails with "could not create image from window". An offscreen **view** can, and that is a different bar worth clearing, because a passing test says a view tree has the right *shape* and nothing about its geometry. `PaneViewSnapshotWriter` renders any pane's content to a PNG with `NSHostingView` + `cacheDisplay`, no window and no permission:

```bash
TENON_PLUGINS_DIR=plugins TENON_TRUST_PLUGIN_INVENTORY=1 \
TENON_VIEW_SNAPSHOT='dev.tenon.kanban/board:/tmp/board.png' \
TENON_VIEW_SNAPSHOT_WORKSPACE="$PWD" swift run tenon     # any plugin view
TENON_DIFF_SNAPSHOT=/tmp/diff.png swift run tenon        # the diff view
TENON_CHANGES_SNAPSHOT=/tmp/changes.png swift run tenon  # the changes panel
TENON_TIMELINE_SNAPSHOT=/tmp/timeline.png swift run tenon # Agent Lens' Timeline account
TENON_SIDEBAR_SNAPSHOT=/tmp/sidebar.png swift run tenon  # the workspace sidebar and its footer
TENON_TITLEBAR_SNAPSHOT=/tmp/titlebar.png swift run tenon # the title bar, identity zone included
```

The title-bar form takes `TENON_TITLEBAR_SNAPSHOT_SIDEBAR=collapsed|expanded` (collapsed by
default, since that is the state where the identity zone carries a workspace name),
`TENON_TITLEBAR_SNAPSHOT_WORKSPACE=<name>` — a name longer than the zone's ~90 pt is the case
worth photographing — and `TENON_TITLEBAR_SNAPSHOT_SIZE=WxH`.

The Timeline form takes `TENON_TIMELINE_SNAPSHOT_STATE=idle|running|ready|failed|insufficient`,
`TENON_TIMELINE_SNAPSHOT_SIZE=WxH` for the narrow-pane reflow, and
`TENON_TIMELINE_SNAPSHOT_EVIDENCE=1` to open every milestone's anchors. Its reading goes
through the real decoder and validator, so what it photographs is what survived them — the
first fixture written for it was refused for claiming `settled` over a still-running command.

The sidebar form takes `TENON_SIDEBAR_SNAPSHOT_SIZE=WxH` and is worth taking at both of the
sidebar's own bounds — `110x420` (`SidebarResize.minWidth`, the narrowest it stays open at)
and the 232 pt default — because a footer that fits one can still clip at the other. It
mounts the real `WorkspaceSidebarView` over a real `WorkspaceStore`, with no pane chrome
around it, since the sidebar is not a pane.

The plugin form boots the real host over the real inventory and mounts the same `PluginSlotView` a pane mounts, so the picture is what the pane shows. `docs/design-plugin-views.md` has the worked example. Reach for it when a change moves layout: T-055 shipped a board that passed 24 tests and rendered as scattered cards floating at different heights, and the adversarial review panel that read the diff found none of it.

There is one behaviour the suite provably cannot reach, and it has its own probe:

```bash
swift scripts/internal/drag-region-probe.swift   # the title bar's drag region, on-screen, exit 0 = rule holds
```

The window server takes a press in the title-bar band from a **drag region** AppKit uploads
ahead of time, and `NSWindow.sendEvent` injects below that server — so a test can drive a whole
press-drag-release successfully while a hardware drag still moves the window. That gap cost
T-101 three shipped fixes. `TabStripReorderTests` closes it by reading the region back for the
real bar — a chip's centre must be outside it, the empty chrome inside — and the probe isolates
the AppKit rule underneath. When a change touches what owns the pointer up there, run both.

## PRD first — the spec is read before the code is touched

Every change that alters what an operator can observe belongs to exactly one PRD under
`docs/prds/`, and that PRD is read before the first edit. Start from the catalog in
`docs/prds/README.md`: its table maps all seventeen capability boundaries to an owning PRD ID
and lists the tasks each one absorbed. Find the row covering the surface you are about to
change, then open both of its files — `<slug>.prd.md` for the requirements, delivery matrix,
and decision log, and `<slug>.feature` for the acceptance examples that say what working
means. Requirements carry stable IDs (`<SLUG>-FR-###`, `<SLUG>-NFR-###`); name the ones your
change implements in the task file and the commit message, so the code stays traceable to the
promise it keeps.

- **A boundary with no PRD gets its PRD before it gets code.** Ten of the seventeen have their
  pair on disk today; the other seven have a catalog row and nothing behind it. Landing in one
  of those means writing `<slug>.prd.md` and `<slug>.feature` from `templates/` first, and
  passing the quality gate in `templates/README.md`. The requirements come before the diff,
  not as a write-up after it.
- **The PRD is updated by the same change that ships against it.** Move its delivery-matrix
  row to `shipped`, map the requirement to its source and smallest relevant test seam, and
  append a dated verification receipt. Exact test counts live in receipts; requirements stay
  true as the suite grows.
- **Current source and current tests win a disagreement.** A PRD that no longer matches the
  tree gets corrected — mark the stale claim superseded in its decision log — and the code
  keeps the behavior its tests prove. A PRD records audited intent; it is not an oracle that
  overrides the working tree.
- **Behavior no requirement covers earns a requirement.** Give it an ID and a scenario in the
  same change, tagged `@prd-TENON_PRD_NNN` and `@req-<requirement-id>`, so the next reader
  finds the promise where the promises live.
- **The exemption is narrow**: typo fixes, build-cache and tooling hygiene, internal renames,
  and tests that pin existing behavior without changing it. Anything an operator could notice
  sits inside the gate.

The point of the gate is the reading, not the paperwork. `docs/prds/README.md` records why it
exists: one capability was routinely split across several task files, and post-shipping
corrections left old tasks telling a story the code had stopped matching. A task file is
evidence of what one session did. The PRD is the current statement of what the product
promises, which is the thing a change has to keep true.

## Workflow — one branch, many agents on `main`

All work happens directly on `main`. There are no worktrees and no feature branches: every agent — interactive or autonomous — edits, tests, and commits on the same `main` checkout. This is deliberate. The isolation a branch would give is bought instead with the live coordination signals below, so agents stay out of each other's way while sharing one tree.

Because several agents run in parallel on that one working tree:

- **Foreign dirty changes are normal.** `git status` will show edits you did not make — another agent is mid-task. Leave them untouched: never stash, revert, discard, or commit someone else's work, and don't be thrown by them. Stage and commit only the files you yourself touched.
- **Claim your work through the board before you touch a file.** `.kanban/` is the shared session channel where agents tell each other what they're doing. Before starting: read `.kanban/board.md` and open every task in `Doing` to see who is working where. Then move your task into `Doing` (WIP limit = 2) and, in its task file, list the files you are about to change under an `## Owner / files (agent lock)` heading with your session id. That heading is how other agents see, at file granularity, what is already spoken for.
- **Overlap → coordinate, don't collide.** If a file you need is already claimed in another `Doing` task, take different work, wait for the claim to clear, or split the change so your edits and theirs don't overwrite each other. Two agents editing the same lines on one branch is exactly the collision this protocol exists to prevent — check first, then write.
- **Release when done.** When your task leaves `Doing`, the claim is gone: clear its `Owner / files` list (or archive the task) so those files are free again, and update `.kanban/board.md` per the session-end step below.
- **Moving a task is a delete plus an insert.** A task line lives in exactly one column. Adding your line to `Doing` without removing the one you left behind puts the same task in two columns, and the stale copy reads as free work — another agent will pick up what you are already doing. Grep the board for your task id after you move it; the answer must be `1`.
- **Keep the shared test target compiling, even mid-red.** TDD here means a test that *fails*, not a test that fails to *build*. `Tests/` is one target shared by every concurrent agent, so a test naming a type that does not exist yet takes `swift test` down for everyone and destroys their evidence, not just yours. Land the type and its empty or throwing members in the same edit as the test that names them, then let the assertions be the red.
- **A new source file ships with its `@domain:` tag.** `DomainTagFitnessTests` holds the untagged count at zero, so an untagged new file turns the suite red for every concurrent agent — the fix is one line above the imports, and the rules are in `docs/domains.md`.

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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **tenon** (36355 symbols, 320410 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/tenon/context` | Codebase overview, check index freshness |
| `gitnexus://repo/tenon/clusters` | All functional areas |
| `gitnexus://repo/tenon/processes` | All execution flows |
| `gitnexus://repo/tenon/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
