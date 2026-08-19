# PRD — Files, content placement, editing, diffs, and filesystem resources

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-008` |
| Lifecycle | `partial` |
| Owner | editor-and-diff, row-list, repository-read, workspace-model, intent-bus, and plugin-host domains |
| Reviewers | product, native UI, accessibility, filesystem security, plugin runtime, performance, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-18 |
| Related work | T-010, T-014, T-016, T-024, T-028, T-030, T-038, T-054, T-081, T-083, T-085, T-086, T-103; agent entry points sourced from an undated Files context-menu feature request (screenshot), captured 2026-08-18, no task filed yet |
| Existing designs | [`design-plugin-host-capabilities.md`](../design-plugin-host-capabilities.md), [`design-intent-bus.md`](../design-intent-bus.md), [`design-pane-header.md`](../design-pane-header.md), [`agent-control.prd.md`](agent-control.prd.md) for the agent contracts FC-FR-037/038 consume |
| Acceptance specification | [`files-and-content.feature`](files-and-content.feature) |

## 1. Executive summary

### Problem

Tenon lets a person browse a project, edit files, inspect repository changes, and move
between these surfaces without turning every action into another tab. Ownership is split
deliberately: Files and Git are replaceable plugins — bundled-swift since T-167, no longer
JavaScript — while file, image, HTML, Changes, and diff panes are host-native. The historical
record now contradicts the live tree in two important places. T-030 claims a manual project-root pin that current source
does not contain. T-083 rules that staged write must become `.v2`, while current source
still widens the closed `filesystem.file.write.v1` schema with `cursor` and `commit`.

Without a canonical contract, a change can fix placement while losing editor state, add
metadata while breaking a public major, or copy a task checkbox that no longer describes
the app. It must also remain explicit that native Changes and plugin Files share a row
vocabulary, while plugin Git intentionally remains a form with inline repository verbs.

### Proposed outcome

Files presents a native declarative tree and performs operations through public intents.
Ordinary Open uses one host policy: remain in the resolved tab, prefer a matching focused
pane, then a matching pane, then an empty pane, otherwise add a pane where the canvas has
room and split only when it has none; never create a tab. The
host selects a renderer, preserves editor state per pane/path, reconciles disk changes
without losing dirty work, and renders bounded native diffs lazily. Pane cwd and automatic
project root are distinct facts, so Files/Git re-root only when the project root changes.

Filesystem contracts remain capability-scoped and race-resistant. Directory listing is
v2; staged write is a bounded host-owned RESOURCE. This PRD cannot become `shipped` until
the write contract is removed or reminted as v2, manual project-root pin is restored or
formally retired, and the remaining installed-app observations are recorded.

### Why now

The user reported that fixing one behavior repeatedly removes another. These thirteen task
records contain both shipped behavior and claims disproved by current source. Canonical PRD
and Gherkin are the context boundary required before more content work continues.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| placement | [`WorkspaceStore.swift`](../../Sources/TenonCore/WorkspaceStore.swift), [`WorkspaceIntentProvider.swift`](../../Sources/TenonApp/WorkspaceIntentProvider.swift), [`WorkspaceOpenContentTests.swift`](../../Tests/TenonCoreTests/WorkspaceOpenContentTests.swift) | high | exact-tab targeting, reuse priority, free-canvas-then-split creation, never-new-tab |
| Files plugin | [`manifest.json`](../../plugins/file-explorer/manifest.json), [`FileExplorerPlugin.swift`](../../Sources/TenonBundledPlugins/FileExplorerPlugin.swift), [`FileExplorerPluginTests.swift`](../../Tests/TenonCoreTests/FileExplorerPluginTests.swift) | high | ownership, menus, editing, intents, root following |
| file renderers | [`FilePaneKind.swift`](../../Sources/TenonCore/FilePaneKind.swift), [`FileSlotView.swift`](../../Sources/TenonApp/FileSlotView.swift), [`FilePreviewSlotViews.swift`](../../Sources/TenonApp/FilePreviewSlotViews.swift) | high | image/web/text choice, editor and preview lifecycle |
| editor state/syntax | [`EditorPaneState.swift`](../../Sources/TenonApp/EditorPaneState.swift), [`SourceEditorView.swift`](../../Sources/TenonApp/SourceEditorView.swift), [`SyntaxHighlighting.swift`](../../Sources/TenonApp/SyntaxHighlighting.swift) | high | state retention, STTextView, tree-sitter |
| diff | [`LineDiff.swift`](../../Sources/TenonCore/LineDiff.swift), [`DiffRows.swift`](../../Sources/TenonCore/DiffRows.swift), [`DiffSlotView.swift`](../../Sources/TenonApp/DiffSlotView.swift) | high | bounded/off-main projection and lazy rendering |
| rows | [`PluginRuntimeModels.swift`](../../Sources/TenonCore/PluginRuntimeModels.swift), [`TreeRowsView.swift`](../../Sources/TenonApp/TreeRowsView.swift), [`ChangesPanelView.swift`](../../Sources/TenonApp/ChangesPanelView.swift) | high | one declarative row schema/renderer |
| cwd/root | [`ProjectRoot.swift`](../../Sources/TenonCore/ProjectRoot.swift), [`SurfacePool.swift`](../../Sources/TenonApp/SurfacePool.swift), [`PluginHost.swift`](../../Sources/TenonCore/PluginHost.swift) | high | automatic resolution and `pane.cwd-changed` |
| persistence | [`WorkspaceCatalogStore.swift`](../../Sources/TenonCore/WorkspaceCatalogStore.swift), [`TenonApp.swift`](../../Sources/TenonApp/TenonApp.swift) | high | cwd seeds a fresh shell; no current pin field or replay |
| filesystem | [`IntentPolicy.swift`](../../Sources/TenonIntentCore/IntentPolicy.swift), [`FilesystemIntentProvider.swift`](../../Sources/TenonCore/FilesystemIntentProvider.swift), [`CoreIntentName.swift`](../../Sources/TenonCore/CoreIntentName.swift) | high | missing-ancestor binding, directory v2, staged write and current v1 name |
| task archive | T-010, T-014, T-016, T-024, T-028, T-030, T-038, T-054, T-081, T-083, T-085, T-086, T-103 | medium/high | intent/receipts; live source supersedes drift; user-directed Docs-pane removal is in progress |
| row menus are flat, per-instance | [`FileExplorerPlugin.swift:396-446`](../../Sources/TenonBundledPlugins/FileExplorerPlugin.swift) (`runMenu`), [`:751-772`](../../Sources/TenonBundledPlugins/FileExplorerPlugin.swift) (`fileMenu`/`directoryMenu`), [`PluginRuntimeModels.swift:17-29`](../../Sources/TenonCore/PluginRuntimeModels.swift) (`RowMenuItem`) | high | `cd Here` already writes composed text into a terminal via `terminal.write.v1`; `RowMenuItem` has no submenu vocabulary, so a new agent entry is a set of dynamically generated flat items, not a nested menu |
| agent composition already public | [`AgentIntentProvider.swift`](../../Sources/TenonApp/AgentIntentProvider.swift), [`AgentLaunchCommand.swift:62`](../../Sources/TenonApp/AgentLaunchCommand.swift) (`AgentLaunchComposer`), [`agent-control.prd.md` AC-FR-031…036](agent-control.prd.md) | high | `agent.inventory.v1` and `agent.command.v1` are shipped and compose a quoted command line without starting anything; a plugin MUST reach composition only through the intent per invariant 9, never by calling `AgentLaunchComposer` itself |
| terminal pane creation accepts an explicit cwd | [`TerminalIntentProvider.swift:166-210`](../../Sources/TenonApp/TerminalIntentProvider.swift) (`terminal.open.v1`) | high | `workingDirectory` is validated to exist and be a directory before any shell starts there; `command` is optional and delivered the same way `terminal.write.v1` delivers text |
| live agent inventory is not yet public | [`agent-control.prd.md` §9](agent-control.prd.md), rows for `agent.list.v1`/`agent.get.v1` | high | those two contracts remain `planned`, not `shipped`; no public intent today lets a plugin discover which panes currently run a live agent |
| drag-out ships for Finder/sidebar, not for a Tenon terminal | [`TreeRowsView.swift:289-301`](../../Sources/TenonApp/TreeRowsView.swift) (`RowDragModifier`, `onDrag` with a plain `NSItemProvider(object: URL...)`), [`WorkspaceFolderDropAdapter.swift:22-33`](../../Sources/TenonApp/WorkspaceFolderDropAdapter.swift) (the only `registerForDraggedTypes` call in `Sources/TenonApp`), [`GhosttySurface.swift:552`](../../Sources/TenonApp/GhosttySurface.swift) (`GhosttyNSView`, no dragging-destination registration), [`SurfacePool.swift:286`](../../Sources/TenonApp/SurfacePool.swift) (`sendTextWhenReady`, the DIRECT delivery service both `terminal.write.v1` and a future drop target would call) | high; confirmed live by the operator during this PRD's drafting, 2026-08-18 | a row's drag payload is a standard file URL, so it already lands in Finder, other macOS apps, and Tenon's own sidebar; a `grep` across the app tree finds exactly one drop target registered anywhere, and it is not the terminal surface, so a row dropped on a Tenon terminal pane today does nothing |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| Core problem? | Explore, edit, preview, compare, and mutate project content without context explosion or data loss. | product behavior |
| Primary users? | Operators plus plugin, CLI, and agent callers working with workspace-scoped content. | current entry points |
| Success? | Opens stay in the intended tab, editor state survives, conflicts preserve work, large diffs remain bounded, and grants contain filesystem work. | Gherkin/tests |
| Fixed constraints? | native design system, typed DIRECT host services, classified public boundaries, closed schemas, bounded resources | normative docs |
| Unresolved? | manual pin, write major repair, and installed-app observations | source/task audit |

### Assumptions to validate

| ID | Assumption | Validation method | State |
|---|---|---|---|
| `FC-A-001` | Reusing one content pane beats a pane/tab per file. | installed workflow/user feedback | shipped policy |
| `FC-A-002` | Nearest ancestor with `.git` is the right automatic anchor. | fixtures and live worktree observation | headlessly proven; live owed |
| `FC-A-003` | Manual project-root pin remains desired. | product decision | unresolved; absent from source |
| `FC-A-004` | Diff bounds fit ordinary review. | fixtures and real large-diff observation | pure bounds proven; live owed |
| `FC-A-005` | A flat, dynamically-generated list of installed/live agents is sufficient; a nested submenu is not required. | operator confirmation once shipped; `RowMenuItem` has no submenu vocabulary today | shipped-pattern-consistent; unresolved |
| `FC-A-006` | Dropping a row onto a Tenon terminal should insert quoted path text, not submit it — mirroring what `cd Here` already does rather than sending an unreviewed Enter. | operator confirmation once shipped | unresolved, see `FC-OQ-005` |

## 3. Users and jobs

### Primary user

An operator working across terminals, files, agents, and repository state in one spatial
workspace. They need navigation without losing an unsaved buffer, switching tabs
unexpectedly, or re-rooting tools on every `cd`.

### Secondary users and affected actors

- Plugin authors using public filesystem/workspace intents without native object access.
- CLI and agent callers opening typed content or operating on scoped paths.
- Accessibility users navigating rows, menus, fields, headers, and diff text.
- Security/support engineers reviewing containment and resource settlement.

### Jobs to be done

- Select many files while reusing the editor pane already being watched.
- Choose Open to the Side when a separate editor is intentional.
- Refresh clean content but retain dirty content when disk changes externally.
- Inspect a large diff without blocking the window or building every row view.
- Let Files and Git follow a linked worktree once, not churn on every directory.
- Safely create or query a path whose ancestor was absent at authorization time.

### Product vocabulary

| Term | Meaning | Not to be confused with |
|---|---|---|
| Files | bundled `dev.tenon.file-explorer` plugin | removed built-in Files case |
| File pane | host `SlotContent.file(path:)` | Files tree |
| Smart open | shared host placement use case | explicit Open to the Side |
| Changes | native changed-file list using shared rows | plugin Git form |
| Cwd | terminal working directory | project root or pin |
| Staging | host temporary file/registry across write calls | Git index |

## 4. Goals and success measures

### Goals

- `FC-G-001` — Opening preserves tab context and deterministically selects one pane.
- `FC-G-002` — Native files/diffs remain stateful, bounded, and fail-soft.
- `FC-G-003` — Files/repository panels share facts without duplicating ownership.
- `FC-G-004` — Filesystem operations are scoped, atomic where promised, and race-safe.
- `FC-G-005` — Public versions and lifecycle classifications match actual shape.
- `FC-G-006` — Files' own context menu is a same-click way to start or hand work to a coding
  agent, and a dragged row reaches every native destination a dragged Finder file would,
  including Tenon's own terminal panes.

### Success metrics

| ID | Metric | Target | Measurement |
|---|---|---|---|
| `FC-M-001` | ordinary content opens adding a tab | zero | placement/provider tests |
| `FC-M-002` | dirty buffers lost on navigation/external edit | zero | editor tests |
| `FC-M-003` | offscreen diff row views built eagerly | viewport-bounded | hosted instrumentation |
| `FC-M-004` | Files/Git reroots inside one repo | zero | root/pool/plugin tests |
| `FC-M-005` | successful operation escaping grant | zero | policy/provider race tests |
| `FC-M-006` | closed schema widened within a major | zero | catalog fitness test |
| `FC-M-007` | manual steps between "right-click a folder" and an agent running there | one selection, zero typed commands | menu/provider composition tests |
| `FC-M-008` | a row dropped on a Tenon terminal pane failing to deliver its path | zero once `FC-FR-040` ships | hosted drop-target tests |

### Guardrail metrics

| ID | Limit | Value |
|---|---|---|
| `FC-GM-001` | editor text | 8 MB, valid UTF-8 |
| `FC-GM-002` | production diff | 5,000 total lines and 512 changed-span lines |
| `FC-GM-003` | directory page | 1…256 entries plus encoded limits |
| `FC-GM-004` | staged write | 4 concurrent, 1 MiB each, fixed 300 s lifetime |
| `FC-GM-005` | editor state | 64 pane/path records |
| `FC-GM-006` | HTML preview | no JS/network/persistent data/navigation |

## 5. Scope

### In scope

- Files tree, roots, header, menus, inline operations, trash, drag-out, and intents.
- Smart placement for every current `SlotContent` kind.
- Native image, local HTML, editor, Changes, and unified/split diff panes.
- Editor syntax/save/state/external-change behavior.
- Automatic cwd/project root, restored spawn cwd, and `pane.cwd-changed`.
- Shared row vocabulary and explicit Git-form exclusion.
- Scoped list/read/exists/write/create/move/trash, metadata, and staged writes.
- Known contract gaps and remaining human verification.
- Removal of the redundant `Open Docs` command and `.docs` content kind, with fail-soft legacy decode.
- A directory-menu entry that opens any installed supported agent at that folder.
- A file-menu entry that delivers a path to a live agent already running in the workspace,
  once that agent is publicly discoverable.
- A Tenon terminal pane accepting a dragged row's file URL the way Finder already does.

### Non-goals

- A second host-native Files browser or plugin document handlers.
- New tabs from ordinary file/Git selection; T-024 supersedes T-010 wording.
- Browser behavior in local HTML preview; PRD-006 owns browsing.
- Persisting terminal process or scrollback with cwd.
- Public intents for same-owner SwiftUI file/editor mutations.
- Converting Git's form into rows solely for visual uniformity (T-086 is closed).
- Retaining a separate hard-coded Docs pane when the file explorer and file renderers own that job.
- Reimplementing agent discovery, command composition, or lifecycle inside Files; it consumes
  `agent.inventory.v1`, `agent.command.v1`, and (once shipped) `agent.list.v1`/`agent.get.v1`
  exactly as PRD-017 defines them, and never assembles a command line or shell quoting itself
  (invariant 9; `AC-FR-036`).
- Submitting a prompt on the agent's behalf; `FC-FR-038` inserts text into an existing PTY the
  same way `cd Here` already does, it does not press Enter for the operator.
- A generic "send this file to any pane" command; the file menu only ever targets a pane a
  public contract can show is actually running a supported agent.
- A drop target on non-terminal panes (editor, diff, plugin views); `FC-FR-040` is
  terminal-pane only.

### Later possibilities

- Bulk binary transfer under a separately designed resource contract.
- Linear-space diff after measurement.
- Editor-buffer recovery across app relaunch.
- Once PRD-017 ships `agent.prompt.v1`, an explicit "Send and Run" variant of `FC-FR-038` that
  atomically submits and waits rather than only inserting text.

## 6. User experience

### Files and smart open

Files root precedence is setting, followed root, workspace, then home. It pages directory
v2, shows directories before files, hides `.git`, and renders only expanded descendants.
Normal selection sends `workspace.content.open.v1`. The host searches only the scoped tab:
focused matching pane, first matching pane, focused/first empty pane, else horizontal split.
The target is focused and tab count is unchanged. Open to the Side explicitly splits and
sets content, bypassing reuse.

### Editing and preview

The final extension selects image, web, or text. Image decode runs off MainActor. HTML uses
a nonpersistent JavaScript-disabled WKWebView, reads only the containing directory, blocks
remote subresources, and cancels navigation. Text uses STTextView with line numbers,
current-line highlight, native find/selection, tree-sitter where available, and Command-S.

State is keyed by pane UUID and exact path: scroll, selection, pending buffer, baseline hash,
and conflict survive view destruction. A clean external change reloads while retaining the
user's place; a dirty change retains the buffer and shows Changed on disk; an own-save echo
does nothing. File header priority is error, conflict, dirty, then empty.

### Changes and diff

Changes projects Staged/Changes into shared rows in tree or flat layout and deliberately
publishes no row menus. A click opens native diff content. Git resolves HEAD/index/worktree,
untracked/deleted/renamed sources off-main. Bounded Myers creates hunks once, rows flatten
once with line-number identities, and LazyVStack builds only visible Unified/Split rows.

### Cwd and project root

The terminal reports cwd; `ProjectRoot` chooses the nearest `.git` file/directory. The pool
records every cwd but publishes only when project root changes. Files/Git follow that fact.
Current source persists last cwd only to seed a fresh shell; it does not restore a process.
Current source has no T-030 Set Project Directory/Use Automatic control or `projectRootPin`.
That promise is pending until restored or explicitly retired.

### Filesystem resources

Policy pins the deepest existing ancestor and a lexical missing suffix. Use-time operations
walk with `O_NOFOLLOW`, so a new symlink fails closed. Directory v2 returns bounded pages,
resolved path, and opt-in nullable metadata. Single-page writes atomically replace. A
multi-page write owns a bounded staging file/registry until commit, expiry, or failure and
publishes only by atomic rename.

### Agent entry points and native drag delivery

A directory row's menu gains one item per supported agent this machine actually has installed
(read from `agent.inventory.v1`, the same list the Launcher already offers, so an agent neither
installed nor habitually run never appears). Selecting one composes that agent's command line
through `agent.command.v1` — no prompt, no session, options as this person habitually passes
them — then opens it with `terminal.open.v1`, `workingDirectory` set to the folder and
`command` set to the composed line; a fresh pane starts there rather than borrowing whatever
pane the operator was last looking at.

A file row's menu gains a "Send to Agent" group only when the workspace has at least one live
agent pane a public contract can name; each entry identifies its pane by alias or provider plus
location. Choosing one delivers the row's absolute, shell-quoted path into that exact pane the
same way `cd Here` already delivers a path — inserted as text, not submitted, so the operator
keeps the choice of what runs.

Every row still carries its existing file-URL drag payload. Dropping it on Finder, another
macOS application, or Tenon's own sidebar already works today, unchanged. Dropping it on a
Tenon terminal pane inserts that same shell-quoted path into the pane's PTY as text, without
moving focus into that pane or submitting anything on the operator's behalf.

### Accessibility and input parity

- Rows expose native selection, disclosure, menu, editing, file-URL drag, and readable text.
- Enter/blur commits once; Escape cancels. Every drag result also has a menu/click path.
- Diff text is selectable and added/removed meaning uses signs/text as well as color.
- Menu-less row space does not swallow pane-level context menus.
- Dropping a row on a Tenon terminal is pointer-only, but it changes nothing a keyboard route
  cannot already reach: the same row's context menu already offers "Copy Path", and pasting
  that into a focused terminal reaches the identical text.
- "Open in Agent" and "Send to Agent" are ordinary context-menu items, reachable the same way
  every other row menu item already is — keyboard menu invocation, VoiceOver rotor, and click.

## 7. Requirements

### Functional requirements

- `FC-FR-001` — Files MUST be a bundled plugin; the host MUST NOT restore a built-in Files case.
- `FC-FR-002` — Each Files instance MUST resolve its owning workspace through `workspace.pane.owner.v1` and retain instance-local state.
- `FC-FR-003` — Root precedence MUST be configured `rootPath`, followed root, workspace path, then home.
- `FC-FR-004` — Files MUST page `filesystem.directory.list.v2` to completion and never call v1.
- `FC-FR-005` — The tree MUST order directories before files, omit `.git`, preserve expansion/selection, and reject stale render generations.
- `FC-FR-006` — File menus MUST expose Open, Open to the Side, external open, reveal, copy path, rename, and Trash.
- `FC-FR-007` — Directory menus MUST expose external open, reveal, copy, cd, create file/folder, rename, and Trash.
- `FC-FR-008` — Create/rename MUST use one inline edit; Enter/blur commits once and Escape/empty cancels.
- `FC-FR-009` — Trash MUST use the public recoverable-trash intent and clear stale plugin selection/expansion.
- `FC-FR-010` — Files, Git, host UI, CLI, and agent ordinary opens MUST use the same smart-open service.
- `FC-FR-011` — Open to the Side MUST explicitly split the scoped pane and set its file.
- `FC-FR-012` — External open, reveal, clipboard, and terminal cd MUST use registered public intents and policies.
- `FC-FR-013` — Smart open MUST act only in resolved invocation scope and never add a tab.
- `FC-FR-014` — Smart open MUST prefer focused matching non-empty, first matching non-empty, focused/first empty, else add a pane through the shared creation policy — free canvas beside the active pane when the layout has any, a split only when it has none; plugin panes match exact plugin/view.
- `FC-FR-015` — Pure `FilePaneKind` MUST select image/web/text by case-insensitive final extension and default unknown to text.
- `FC-FR-016` — Image preview MUST decode off-main, fit the pane, and fail visibly without crashing.
- `FC-FR-017` — HTML preview MUST disable JS/persistence, restrict local read scope, block remote resources, and refuse navigation.
- `FC-FR-018` — Text MUST use STTextView with line numbers, current-line highlight, native find/selection, horizontal scrolling, and Command-S.
- `FC-FR-019` — Supported files/injections MUST use tree-sitter; unsupported grammars MUST remain plain text.
- `FC-FR-020` — Editor MUST refuse text above 8 MB or invalid UTF-8 explicitly, never lossy/partial.
- `FC-FR-021` — Scroll, selection, pending text, baseline, and conflict MUST survive by pane/path in a 64-record store.
- `FC-FR-022` — The one pane header MUST show only highest-priority error, conflict, dirty, or empty state.
- `FC-FR-023` — Disk changes MUST ignore own echo, reload clean content in place, and retain dirty buffers with conflict.
- `FC-FR-024` — Terminal panes MUST track canonical cwd and nearest-`.git` automatic project root separately.
- `FC-FR-025` — Host MUST publish `pane.cwd-changed` on initial resolution/root change; Files/Git MUST reroot from it.
- `FC-FR-026` — Relaunch MUST use last valid cwd only to spawn a fresh shell, falling back to workspace path.
- `FC-FR-027` — Git panel MUST retain its plugin-owned form and inline verbs, not adopt rows for appearance alone.
- `FC-FR-028` — Changes MUST share TreeRowItem/TreeRowsView, support tree/flat/collapse in header, publish no row menus, and open diff on selection.
- `FC-FR-029` — Diff MUST resolve inline and Git sources off-main and discard stale generations.
- `FC-FR-030` — Diff MUST offer Unified/Split and explicit loading, binary, error, no-change, added, and removed states.
- `FC-FR-031` — Diff MUST compute bounded hunks once, flatten stable rows once, and lazily render correct horizontal extents.
- `FC-FR-032` — Public filesystem MUST provide bounded list/read/exists/atomic-write/create/exclusive-move/recoverable-trash.
- `FC-FR-033` — Directory v2 MUST return resolved path and optional nullable metadata without changing symlink kind; vanished entries stay with null metadata and clean end-of-scan succeeds.
- `FC-FR-034` — Staged write MUST bind provider/target/token/offset and end only by atomic commit, expiry, failure, or invalidation.
- `FC-FR-035` — Manual root pin MUST be fully restored/persisted if retained, or explicitly retired with T-030 corrected.
- `FC-FR-036` — The host MUST remove `Open Docs`, `.docs` slot/default content, and its dedicated renderer; a saved docs slot MUST restore empty, unknown docs preferences MUST preserve the rest of the document, and docs recents MUST be dropped.
- `FC-FR-037` — A directory's context menu MUST offer one "Open in `<agent>`" item per agent `agent.inventory.v1` reports installed, MUST compose that agent's command line only through `agent.command.v1`, and MUST start it with `terminal.open.v1` set to that folder's absolute path and the composed command; zero installed agents MUST omit the group rather than show a disabled or empty entry.
- `FC-FR-038` — A file's context menu MUST offer one "Send to `<agent>`" item per live agent pane a public contract can name in the current workspace, and MUST deliver the file's absolute, shell-quoted path into that exact pane through `terminal.write.v1` without submitting it; the group MUST be absent, not disabled, when no live agent pane is discoverable.
- `FC-FR-039` — A row declaring a `path` MUST remain draggable as a plain file-URL `NSItemProvider`, landing unchanged in Finder, other macOS applications, and Tenon's own sidebar folder-open target.
- `FC-FR-040` — A Tenon terminal pane's native surface MUST accept a dropped row's file-URL drag and insert its absolute, shell-quoted path into that pane's PTY as text, without changing focus or submitting the line.

### Non-functional requirements

- `FC-NFR-001` — Native content MUST follow [`designs.md`](../designs.md) with no feature-local tokens.
- `FC-NFR-002` — Blocking I/O, image/Git/diff work MUST run off MainActor; stale/cancelled work MUST not publish.
- `FC-NFR-003` — Renderer, root, external-change, diff, row, and placement rules MUST remain pure/testable where possible.
- `FC-NFR-004` — Row identities MUST derive from content and lazy work MUST be viewport-proportional.
- `FC-NFR-005` — Authorization MUST anchor existing ancestry, validate missing suffixes, use descriptor-relative no-follow, and fail closed on races.
- `FC-NFR-006` — Pages, scans, stores, diff complexity, staging capacity/bytes/lifetime, and command walks MUST have deterministic bounds.
- `FC-NFR-007` — Replacement MUST be atomic; intermediate staging MUST not appear at target; failed staging MUST release ownership/residue best-effort.
- `FC-NFR-008` — Plugins MUST receive declarative values/intents/events, never native views, editor models, terminal surfaces, or handles.
- `FC-NFR-009` — Closed schemas MUST not widen inside one major; current file-write v1 MUST be removed or reminted v2 before `shipped`.
- `FC-NFR-010` — Pointer-only row/edit/menu/drag outcomes MUST have keyboard/accessibility alternatives; status MUST not rely on color.
- `FC-NFR-011` — Watches, records, tasks, instances, and staged resources MUST end or remain bounded with their owner lifecycle.
- `FC-NFR-012` — Files/Changes MAY share row semantics; Git form MUST remain excluded unless its interactions actually become row-like.
- `FC-NFR-013` — Every path text this PRD delivers into a PTY — composed agent launch, sent file path, or dropped row — MUST be quoted through the same posix-quoting path `agent.command.v1` already uses (`AutomationAuthoring.posixQuoted`), never hand-assembled per call site, and MUST refuse a path containing a control character before any byte reaches the PTY.

## 8. Acceptance specification

[`files-and-content.feature`](files-and-content.feature) is canonical. Requirement tags map
lower-case (`FC-FR-014` → `@req-fc-fr-014`). Completion requires exact bidirectional tag
coverage, focused pure/hosted tests, installed reroot/large-diff observations, file-write v2
repair or removal, a reviewed manual-pin implementation or retirement, and completed legacy Docs
state migration.

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Class | Reason |
|---|---|---|
| native UI → application services | DIRECT | same owner |
| Files/Git rows/body/header | CONTRIBUTION | declarative registration |
| select/menu/edit callback | EVENT | fact that interaction happened |
| `pane.cwd-changed` | EVENT | observed cwd/root fact |
| finite plugin/CLI/agent operations | INTENT | bounded cross-owner request/reply |
| read/list paging | RESOURCE/STREAM body | multi-result pull body |
| staged write | RESOURCE | host state outlives initial reply |
| `tenon.path.*` | DIRECT JavaScript | pure local calculation |
| `agent.inventory.v1`, `agent.command.v1` (Files' consumption of them) | INTENT (shipped, PRD-017) | bounded cross-owner reply; Files is a plugin and MUST NOT assemble a command line itself (invariant 9) |
| `agent.list.v1`/`agent.get.v1` (Files' consumption of them) | INTENT (planned, PRD-017) | same reason; `FC-FR-038` has no visible menu group until PRD-017 ships these |
| Terminal pane accepts a dropped row | native UI → `SurfacePool.sendTextWhenReady` | DIRECT | same owner as `terminal.write.v1`'s own host-side delivery; no new public inventory entry, mirrors `WorkspaceFolderDropAdapter`'s existing sidebar drop target |

Core audiences remain `{plugin, cli, agent}` or `{plugin}`. Palette/user projection is
plugin-owned metadata, not a generic app principal.

### Native design-system constraints

Use TenonTheme, one pane header, compact shared rows, stable accessory columns, existing
placeholders/scrollbars, and non-color status. No second file/diff toolbar.

### Domain and ownership map

| Concern | Domain |
|---|---|
| editor/diff/renderers | `editor-and-diff` |
| shared rows | `row-list` plus bounded plugin-host values |
| repository reads | `repository-read` |
| placement/cwd/root | `workspace-model` |
| filesystem contracts | `intent-bus` |
| Files/Git implementation | `dev.tenon.file-explorer`/`dev.tenon.git`, `bundled-swift` runtime since T-167; no longer plugin-local JavaScript |
| terminal drop target (`FC-FR-040`) | `terminal-surface`, same domain `TerminalIntentProvider.swift`/`GhosttySurface.swift` already carry |

### Data, lifecycle, security

- Catalog owns pane/content; bounded editor cache owns ephemeral pane/path state.
- One file watch dies with its model; one diff task generation drops stale publication.
- SurfacePool owns cwd; automatic root is derived. A future manual pin is a distinct override.
- Read cursors carry identity; write cursor names provider-owned staging and is a RESOURCE.
- Capability binding uses canonical descriptor-relative paths and rejects symlink races.
- HTML preview has no network, JavaScript, persistent data, or broad local-file access.

### Compatibility

- Directory v1 is removed; bundled callers use v2.
- Current file write remains v1 but is not an acceptable final canonical name.
- T-010 new-tab wording is superseded by T-024/current tests.
- T-030 no-cwd-persistence wording is superseded by fresh-shell cwd restoration; its pin
  claim remains unresolved.
- T-086 closes bespoke Git rows.
- T-103 removes the redundant Docs content kind with no public alias; old workspace/preferences/
  recents data degrades fail-soft instead of invalidating unrelated state.

## 10. Delivery plan

| Group | Current state | Exit evidence |
|---|---|---|
| Files/placement FC-FR-001…014 | shipped | plugin/placement/scope tests |
| previews/editor FC-FR-015…023 | shipped | kind/I/O/state/external-change tests |
| Docs retirement FC-FR-036 | shipped | zero source/manifest symbols plus workspace/preferences/recents migration tests |
| cwd/root FC-FR-024…026,035 | automatic/restore shipped; pin unresolved | root/pool/relaunch + decision/live check |
| Changes/Git/diff FC-FR-027…031 | shipped; live look owed | parse/row/diff tests + observation |
| filesystem FC-FR-032…034, NFR-005…009 | behavior shipped; write major invalid | provider/policy/catalog + v2 migration |
| drag-out to Finder/other apps/sidebar FC-FR-039 | shipped | `RowDragModifier` + operator-confirmed live behavior, 2026-08-18; no new automated test added this session — still resting on code inspection and the operator's live observation, not a headless assertion |
| Open in Agent FC-FR-037 | shipped, T-181 2026-08-18 | `FileExplorerPlugin.swift` menu/composition/open tests |
| Send to Agent FC-FR-038 | planned; blocked on PRD-017 `agent.list.v1`/`agent.get.v1` shipping | menu/provider tests once unblocked |
| terminal drop target FC-FR-040 | shipped, T-181 2026-08-18; wiring/quoting proven headlessly, the AppKit `registerForDraggedTypes` registration itself still needs a live human drag | `TerminalFileDropTests` + `GhosttyNSView` dragging-destination methods |
| PTY quoting NFR-013 | shipped for FC-FR-040 (`SurfacePool.handleFileDrop` via `AutomationAuthoring.posixQuoted`); FC-FR-037 inherits it for free through the already-shipped `agent.command.v1` quoting, no new quoting code needed there | `TerminalFileDropTests` |

Phases: canonical capture; write-contract repair; manual-pin decision; installed-app
evidence. Write v2 must update inventory, source, manifests/callers, architecture tests/docs,
and delete v1 in one reviewed change. A pin must extend the one catalog store without
materializing surfaces. Agent entry points ship in two slices: `FC-FR-037`/`039`/`040` need
nothing outside this PRD; `FC-FR-038` waits on PRD-017's `agent.list.v1`/`agent.get.v1`.

## 11. Dependencies, risks, and mitigations

### Dependencies

| Dependency | Owner | Needed by | Failure/fallback |
|---|---|---|---|
| `agent.list.v1`/`agent.get.v1` (`planned`, not yet in source) | PRD-017 agent-control | `FC-FR-038` | until shipped, the "Send to Agent" group stays absent everywhere; Files ships `FC-FR-037`/`039`/`040` without it |
| `agent.inventory.v1`, `agent.command.v1` (`shipped`) | PRD-017 agent-control | `FC-FR-037` | already available; no fallback needed |
| `terminal.open.v1` `workingDirectory`/`command` (`shipped`) | PRD-009 terminal | `FC-FR-037` | already available; no fallback needed |

### Risks

| Risk | Mitigation |
|---|---|
| file write stays widened v1 | repair/remove before shipped |
| task resurrects nonexistent pin | pending requirement and explicit decision |
| smart open hijacks wrong tab/content | exact scope/kind/tab-count tests |
| external edit overwrites dirty work | pure policy, baseline, conflict, generations |
| large diff stalls | off-main bounds, lazy rows, explicit refusal |
| symlink appears after authorization | pinned descriptor/no-follow race tests |
| row vocabulary becomes generic form framework | retain T-086 exclusion |
| a "Send to Agent" target exits or is replaced between menu build and click | `agent.list.v1`/`agent.get.v1` bind pane, surface incarnation, and provider identity (`AC-FR-005/006`); a stale reference MUST fail typed, never retarget by pane position |
| a composed or dropped path carries shell metacharacters that escape its quoting | reuse `AutomationAuthoring.posixQuoted` exactly as `agent.command.v1` already does (`FC-NFR-013`); no second quoting implementation |
| Files quietly grows its own agent-launch logic instead of calling PRD-017's contracts | non-goal stated explicitly; fitness/source-inventory review before merge, mirroring `AC-FR-036` |
| a long composed agent command line silently loses its trailing Enter — T-159 (`.kanban/tasks/T-159-a-command-longer-than-the-pty-queue-silently-loses-its-enter.md`) measured this at ~1.6 KB against macOS's 1024-byte `MAX_INPUT`, using an `agent.command.v1` claude launch as one of its two live repro cases; `FC-FR-037` composes and delivers exactly that kind of line through `terminal.open.v1` | not mitigated here — T-159 is unclaimed, host-side (`GhosttySurface.createSurface()`), and out of `FC-FR-037`'s scope; a habitual argument set long enough to cross that bound reproduces silently until T-159 ships |

## 12. Open questions and decisions

- `FC-OQ-001` — Restore manual project-root pin or formally retire it?
- `FC-OQ-002` — Retain staged write as v2 or replace it with another resource contract?
- `FC-OQ-003` — Do current diff bounds reject a real expected workflow?
- `FC-OQ-004` — Should "Open in Agent" order/filter its items by this person's launch habit
  (`AgentLaunchSuggestion.habitDescription`), or list every installed agent identically?
- `FC-OQ-005` — Should "Send to Agent" and the terminal drop target insert text only (current
  assumption `FC-A-006`), or submit immediately once `agent.prompt.v1` exists to make that
  atomic and occupant-safe?
- `FC-OQ-006` — Does `FC-FR-040`'s drop target ever need to extend past terminal panes, or does
  every other pane kind remain out of scope permanently?

| Date | Decision | Supersedes |
|---|---|---|
| 2026-08-18 | Files' context-menu agent entry points and the terminal drop target are scoped into PRD-008, not a new PRD, because the trigger surface — Files' own menus and drag rows — already belongs to this PRD's stated scope | none; new requirements added to an existing boundary |
| 2026-08-18 | "Open in Agent" and "Send to Agent" reach agent composition only through `agent.inventory.v1`/`agent.command.v1`/`agent.list.v1`/`agent.get.v1`; Files never assembles a command line itself | `AC-FR-036`, invariant 9 |
| 2026-08-18 | "Send to Agent" ships only once `agent.list.v1`/`agent.get.v1` are public; no interim private-signal substitute is built | verified zero live-agent discovery intent exists in current source |
| 2026-08-18 | Installed-agent lookup for `FC-FR-037` is cached on `Pane` at `open`/explicit `refresh`, not re-fetched inside `render`, after a peer session (debugging a live "Plugin view unavailable" regression) flagged that `render` already fires on every `workspace.changed`/`pane.cwd-changed`/`workspace.slot-focused` churn event across every open pane, and suspected exactly that loop of overflowing `BundledPluginRuntime`'s 256-slot mailbox | cross-session coordination, T-181; the peer's own hypothesis is unverified, so this is a precaution against contributing to it, not a claim their bug is fixed |
| 2026-08-09 | ordinary open never creates a tab | T-010 historical wording |
| 2026-08-09 | live source, not task checkboxes, determines shipped status | T-030/T-083 overclaims |
| 2026-08-09 | restored cwd seeds only a fresh shell | T-030 old handoff |
| 2026-08-09 | Files/Changes share rows; Git form does not | T-086 proposal |
| 2026-08-09 | `Open Docs` and `.docs` are removed rather than deprecated; file panes own document rendering | T-103 user direction |
| 2026-08-09 | PRD remains partial | prior catalog shipped label |
| 2026-08-14 | smart open adds its pane through the shared creation policy, so free canvas is taken before any pane is narrowed | `FC-FR-014`'s "else split" wording and the `splitActiveSlot` call it described |

## 13. Verification receipts

| Area | Receipt | Gap |
|---|---|---|
| placement | WorkspaceOpenContent/provider tests | none headlessly |
| placement on free canvas | 2026-08-14, T-157: three `WorkspaceOpenContentTests` cases red first — a 6-column terminal beside 6 empty columns was cut to 3 and the file placed at x=3 (leaving the empty half untouched), and a 4-column pane with 8 columns free opened no pane at all because `SpatialLayout.split` refuses a pane under `minimumWidth * 2`; green after `openContent` routes through `addSlot`. Scope 14 / 0, full suite 2243 / 0 | not photographed; the geometry is asserted, not seen |
| Files | real bundled JS tests | none headlessly |
| editor/previews | kind/I/O/state/change/syntax tests | visual review on design change |
| diff | pure/model/hosted tests and historical 5,130-line measurement | real human look |
| cwd/root | root/pool/subscription/event tests | live linked-worktree reroot |
| filesystem | catalog/policy/provider/pager/staging/race tests | write-major repair |
| manual pin | no current symbol/field/UI/test found | whole requirement or retirement |
| Docs retirement | 2026-08-09, T-103: `rg '\.docs\b'` over `Sources/`, `Tests/` and `plugins/` returns nothing; suite 1696 / 0; the fail-soft preference decode is mutation-proved (reverting one key to a strict `decodeIfPresent` turns `AppPreferencesTests` red, restore `cmp`-verified) | the empty-state launcher lost a button and was not photographed; no offscreen renderer exists for that card |
| Open in Agent / terminal drop | 2026-08-18, T-181: `FileExplorerPluginTests` (6/0, three new: menu ordering with two installed agents, successful compose-then-open with exact `workingDirectory`/`command` assertions, and a failed `agent.command.v1` never reaching `terminal.open.v1`) and `TerminalFileDropTests` (2/0, new: a space-and-single-quote path arrives literally quoted, multiple dropped files arrive space-separated) both red before their implementation, green after; full suite **2366 / 0**, `ShippedPluginsTests` confirms `plugins/file-explorer/manifest.json`'s three new `uses` entries match Swift-source intent calls | `GhosttyNSView.draggingEntered`/`performDragOperation`'s real AppKit registration is not exercised by any test — constructing a real `GhosttyNSView` in the shared suite risks the T-135 crash, so this repeats that gap's existing shape rather than adding a new kind of one; needs a live human drag on an installed build |

## 14. Change history

| Date | Author | Change |
|---|---|---|
| 2026-08-09 | Codex | Created current-source canonical PRD and exposed write-version/manual-pin gaps. |
| 2026-08-09 | Codex | Added the user-directed Docs-pane removal and fail-soft legacy-state contract. |
| 2026-08-14 | Claude | Restated `FC-FR-014`'s creation branch as the shared placement policy after an operator hit a half-width pane being quartered while half the canvas stood empty. |
| 2026-08-16 | Claude | Corrected the Files-plugin source link: T-167 ported `file-explorer` to the compiled bundled runtime, deleting `plugins/file-explorer/main.js`; the row now points at `FileExplorerPlugin.swift`. |
| 2026-08-18 | Claude | Added `FC-FR-037…040`/`FC-NFR-013` for a Files-menu agent launch/send and a Tenon-terminal drop target, from an operator feature request; documented that `FC-FR-038` is blocked on PRD-017's unshipped `agent.list.v1`/`agent.get.v1`, and pinned already-shipped row drag-out (`FC-FR-039`) with a requirement it previously lacked. |
| 2026-08-18 | Claude | Shipped `FC-FR-037`/`039`/`040`/`NFR-013` (T-181): Files' directory menu now offers "Open in `<agent>`" per installed agent, composed through `agent.command.v1` and opened through `terminal.open.v1`; a Tenon terminal pane accepts a dropped row's file URL and inserts its posix-quoted path. `FC-FR-038` remains explicitly unshipped, blocked on PRD-017. Full suite **2366 / 0**. |

