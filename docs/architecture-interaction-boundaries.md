# Interaction boundary law

**Status:** accepted, normative · **Date:** 2026-07-25
**Applies to:** Swift host, SwiftUI shell, plugin runtime, shipped plugins, palette,
keybindings, CLI, agent adapters, tests, and forward-looking design documents.

This document is the source of truth for choosing an interaction mechanism in Tenon.
`docs/design-intent-bus.md` specifies the intent kernel after this law has selected
**INTENT**; it does not decide which interactions are intents.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, and **MAY** are used as
defined by RFC 2119.

## Goal

Every product/domain interaction has one deterministic classification:

1. **DIRECT**
2. **SCOPED FACILITY**
3. **INTENT**
4. **EVENT**
5. **RESOURCE / STREAM / TASK**
6. **CONTRIBUTION**

Protocol, registry, request, provider, and resource lifecycle operations use the exact
closed **reserved control plane** below. They are not a seventh extensible product
mechanism and MUST NOT carry domain verbs.

The classification follows semantics and ownership, not taste, naming, file layout, or
whether a call happens to be asynchronous. Two reviewers applying the ordered decision
law below to the same interaction MUST reach the same answer.

The hard truth behind this decision is that “every finite operation is an intent” is
over-engineering for a local native application. It would make ordinary in-process calls
pay for value conversion, schema validation, policy, routing, admission, cancellation,
and telemetry without gaining an ownership boundary. The opposite extreme—letting every
caller choose a convenient direct callback—would recreate private paths and policy drift.
Tenon pays boundary cost exactly where the boundary creates isolation, authority, public
discovery, provider selection, or lifecycle value.

## Terms

### Semantic owner

A **semantic owner** is the authority allowed to change an operation's behavior and ship
that change atomically without negotiating a public contract with an independently
lived component.

Two pieces belong to the same semantic owner only when all of these are true:

- they ship and roll back as one Tenon app release;
- they run under the same trust principal;
- neither can be installed, disabled, upgraded, or hot-reloaded independently;
- the caller does not require policy-filtered discovery or runtime provider selection;
- changing the callee's typed Swift interface does not require ecosystem compatibility.

Directory, Swift target, actor, thread, and process location do not create semantic
ownership by themselves.

For the current product:

- `TenonCore`, `TenonApp`, and their built-in Swift services are one semantic owner;
- each plugin `PluginID` is a separate semantic owner because it is independently
  installed, disabled, and hot-reloaded;
- CLI, user, and agent entry points are public adapter principals even though the app
  ultimately serves them;
- two plugins always have different semantic owners, including bundled plugins.

### Principal

A **principal** is the host-minted caller identity used for policy. Principals and semantic
owners answer different questions:

- semantic owner chooses **DIRECT versus a public boundary**;
- principal determines **what a public boundary caller may discover and invoke**.

The current public intent caller audiences are `plugin`, `user`, `cli`, and `agent`.

`user` is one principal with many surfaces: the command palette, the launcher in each of
its anchors, a registered product keybinding, and any other host surface carrying an
accepted gesture. They are surfaces of the same caller — *a person, acting now, in this
window* — rather than a principal each. Naming it for the person instead of for one control
is what keeps a new surface from looking like it needs a new identity: it does not.

Built-in Swift UI is part of the host semantic owner and mints no principal of its own; when
it carries a person's gesture across a public boundary it carries `user`, and when it calls
its own services it stays DIRECT. A provider making a nested call uses its plugin principal;
"core" does not mint extra authority.

### Public adapter boundary

A public adapter boundary is an entry point whose contract must remain coherent across
independent callers: plugin runtime, CLI socket, agent/MCP projection, palette, or a
registered product-keybinding projection. Crossing one is architecturally equivalent to
crossing semantic owners even when both sides currently run in one process.

A keyboard gesture is a public keybinding projection only when it names a product command
registered from plugin-owned intent presentation metadata and is host-wide, discoverable,
or rebindable outside one focused view. A gesture consumed only by the focused SwiftUI/AppKit
view or responder, with no public command registration—such as editor save, palette
Escape, or list navigation—is same-owner UI control and stays DIRECT. The physical input
device never determines the mechanism.

### Classification unit

Classify one semantic interaction, not an entire file, namespace, or implementation object.
A public namespace may contain several interactions, but every exact public path has one
classification below.

Mechanism-local setup and teardown do not create a seventh domain mechanism. Provider bind,
event subscribe/unsubscribe, contribution registration, request cancellation, and resource
read/cancel are control/lifecycle operations of their named mechanism. For example:

- `tenon.views.set` publishes a CONTRIBUTION;
- a callback delivered through `tenon.views.onSelect` is an EVENT fact;
- `tenon.events.on` registers observation of an EVENT channel whose publisher exists
  independently;
- `tenon.fs.watch` creates a caller-owned RESOURCE whose lifetime ends on cancel;
- `SurfacePool.reconcile` is a typed DIRECT call, while the retained terminal surface has
  RESOURCE lifecycle.

This distinction prevents classifying every subscription as a resource or every resource
method as a new intent.

## Ordered decision law

Apply these questions in order. Stop at the first match.

0. **Is this one of the exact reserved protocol/mechanism control operations below?**
   Use that reserved control operation. A product verb cannot qualify for this exception.

1. **Is an independently owned contributor publishing declarative state or static
   registration whose snapshot it owns and whose validation/reconciliation/rendering the
   host owns?**
   Use **CONTRIBUTION**.

2. **Is the message a fact that already happened on a publisher-owned channel whose
   producer exists independently of this observer?**
   Use **EVENT**.

3. **Does the caller establish/own the producer or receive multiple correlated values, a
   large pull-based body, or a lifetime handle that remains usable after the initial reply
   for read/progress/cancel?**
   Use **RESOURCE / STREAM / TASK**.

4. **Are caller and callee inside one semantic owner and outside every public adapter
   boundary?**
   Use a typed **DIRECT** call.

5. **Is it one of the three explicitly allowlisted plugin-private facilities below?**
   Use **SCOPED FACILITY**.

6. **Is it one finite unicast request/reply crossing a semantic-owner or public-adapter
   boundary?**
   Use **INTENT**.

7. **Otherwise, the design is under-specified.**
   It MUST NOT be implemented until ownership, result cardinality, and lifetime are
   explicit enough to repeat this decision.

The operation's English verb does not choose the mechanism. “Open,” “read,” “set,” and
“cancel” can describe different semantics. Result cardinality, lifetime, owner, and public
reachability choose it.

## The six mechanisms

| Mechanism | Required semantics | Current examples | Explicitly absent behavior |
|---|---|---|---|
| **DIRECT** | Same semantic owner; typed in-process API | SwiftUI → workspace use case, intent provider → same use case, `SurfacePool`, `PluginWebSurfacePool`, `tenon.path.*` | no string routing, no `IntentValue`, no discovery |
| **SCOPED FACILITY** | Plugin-private, fixed host service on the closed allowlist | `tenon.settings.get`, `tenon.storage.get/set`, `tenon.log` | no provider choice, no CLI/palette/agent exposure |
| **INTENT** | Finite unicast request/reply across an independent principal boundary | filesystem, workspace, terminal, browser navigation, UI prompt, network, plugin-owned actions | no broadcast, no unbounded lifetime |
| **EVENT** | Immutable fact; zero-to-many observers; publisher does not await observers | workspace changed, terminal title changed, browser navigation facts | no command hidden in an event, no reply |
| **RESOURCE / STREAM / TASK** | Multi-result/large pull body, or caller-owned lifetime that outlives the initial reply | timers, `process.stream`, `fs.watch`, terminal/web surface lifetime | no indefinite request held open in place of a handle |
| **CONTRIBUTION** | Declarative state/metadata owned by contributor and rendered/indexed by host | plugin views, status, setting schemas, intent palette metadata | no imperative host mutation hidden in data |

### DIRECT

DIRECT is the default inside the host semantic owner. Calls MUST use typed Swift domain or
application-service interfaces. They MUST NOT encode/decode `IntentValue` merely to cross a
file, actor, target, or test seam.

DIRECT is also the default inside one plugin's own semantic owner. Functions inside one
plugin generation call ordinary JavaScript functions directly; they MUST NOT self-send
intents merely to organize implementation. The plugin's public intent handler is an adapter
that calls that same local function when external invocation is required.

One behavior may have several adapters but only one implementation:

```text
built-in Swift UI ───────────────► typed application service
plugin / CLI / agent ─► intent provider adapter ─► the same typed application service
```

This is not a duplicate public path. The first caller is internal to the owner; the second
crosses a public principal boundary. Validation and policy live in the adapter/kernel;
domain semantics live once in the typed service.

Current DIRECT inventory:

- ordinary functions/modules inside one plugin generation;
- SwiftUI workspace, tab, pane, and settings interactions;
- app lifecycle and composition-root wiring;
- install-channel routing: the exact closed set `{production, staging}` is resolved from
  the app bundle identity at the composition root. Each channel is a singleton within
  itself and owns a distinct Unix socket/claim plus a distinct Application Support root;
  production retains the legacy paths. This is same-owner DIRECT lifecycle selection,
  not a caller principal, public adapter, or field added to the CLI wire protocol. The
  production-default CLI remains compatible, while a terminal inherits its owning
  channel's exact socket through `TENON_SOCKET_PATH`, even when that channel's server is
  degraded. Shared Codex/Claude hook configuration stays channel-neutral and resolves the
  owning runtime script from the terminal's `TENON_AGENT_HOOK_SCRIPT` environment. A launch
  that cannot prove ownership of its channel claim stops before state/UI assembly, and
  activation probes reject socket-path symlinks rather than following them across channels;
- `WorkspaceStore` and typed workspace use cases;
- terminal and web surface pool retain/reconcile/focus/lifecycle;
- pane activity/attention state (T-029): one `PaneActivity` per slot, fed by the shell's
  fixed-interval terminal-observation poll and the shell's viewed projection, read
  same-owner DIRECT by tab chips, pane headers, sidebar rollups, the title-bar count,
  and the host-native completion-notification adapter. No plugin EVENT exists for this
  state; if a plugin ever needs visibility into pane attention, that is a NEW classified
  EVENT admitted through this law's ordered decision — never a reuse of this host state;
- launcher surfaces and tab-context placement (T-039, AIO-8): the title-bar `+`, a tab
  right-click, and a right-click on an unoccupied spatial-grid cell all host the same
  `LauncherMenu`, which alone selects and ranks the appropriate `CommandIndex` projection
  and merges the shell's bounded host-agent suggestion snapshot — there is no second
  anchor-owned list or presentation. The ordinary launcher reads `launcherOnly`; an
  empty-grid launcher reads `paneFillersOnly`, derived from the declarative
  `palette.fillsPane` CONTRIBUTION, so structural actions such as New Tab and Split are not
  offered where they cannot satisfy the click. Detecting the clicked empty cell, resolving
  the largest valid empty `GridRect` that contains it, reserving that exact rectangle with
  an empty pane, and presenting/dismissing the popover are host-native DIRECT UI/workspace
  control: same semantic owner, no caller principal, no independent lifetime, and no new
  public mechanism. Plugin-contributed entries remain CONTRIBUTIONs (palette declarations),
  and choosing one takes the existing finite INTENT path under the `user` principal with
  its existing authority, failure, and admission semantics. A detected Codex or Claude row
  is instead the host-native DIRECT convenience described below; it never enters that
  projection's intent adapter. The title-bar `+` creates a
  blank tab through the typed workspace service and invokes the chosen intent against that
  tab's pane scope. While either a new-tab or empty-grid scoped reservation is live,
  `workspace.tab.create.v1` fills and claims it instead of opening a second tab; correlation
  is by pane scope plus the host-minted user-gesture identity, never by guessing from
  concurrently opened tabs. An empty-grid selection is scoped to the reserved pane, so
  `workspace.content.open.v1` fills the exact clicked rectangle; failure or a successful
  provider that leaves the reservation empty removes only that untouched reservation,
  without spatial reflow. A matching reservation that has become stale fails closed and
  never falls through to ordinary tab/content placement. Claiming fills the reserved pane
  by ID without overriding workspace/tab navigation that happened while the intent was
  awaiting. Pointer right-click, the canvas's Option-Return control, and VoiceOver custom
  actions all enter this same DIRECT target/presentation path; accessibility does not add a
  second command registry or dispatch mechanism. A tab anchor names
  scope at the call site through the pure `TabContextPlacement` rule so a background tab
  receives its own result. Content placement inside the named tab stays in
  `workspace.content.open.v1`: reuse the pane showing this kind of content, otherwise
  split, never open another tab;
- personal runbooks (source-owned as `QuickCommand`): the single title-bar library control,
  editor sheet, project/everywhere filtering, and persisted recent selection are host-native
  DIRECT UI and preference state. A run is one finite fire-and-return operation inside the
  host semantic owner, carries no public principal or independent lifetime, and reports only
  whether the typed placement/send operation was accepted. A Terminal runbook calls
  `WorkspaceStore` and `SurfacePool` directly and explicitly chooses the focused terminal or
  a fresh tab; if the focused target cannot receive terminal input, placement fails over to
  a fresh terminal tab. Codex and Claude runbooks always create a fresh terminal tab and
  write one POSIX-quoted brief to the selected host-supported executable so the live PTY has
  its own stable pane identity and return path. Authority is the accepted in-window gesture;
  bodies are capped at 6,000 characters, the library at 40 entries, and the feature adds no
  queue beyond `SurfacePool`'s existing one-pending-string-per-pane readiness path. This
  focused-view convenience is neither registered nor discoverable as a product keybinding,
  does not mint an app principal, and adds no intent or public `tenon` path. The public
  `terminal.run.v1`/`terminal.open.v1` providers remain adapters over the same
  workspace/surface services for plugin, CLI, and agent callers;
- detected agent launch suggestions: the shell performs one off-main, read-only scan for the
  exact host-supported executables `{codex, claude}` and reads at most 512 KiB from the tail
  of each known shell-history file. It retains no raw history and projects at most one row
  per installed agent. Only an exact source-owned allowlist of reusable startup options is
  learned; prompt text, cwd/add-dir, resume/session identity, settings bodies, and shell
  operators are discarded. The semantic owner is the built-in `TenonApp` shell and its
  typed `WorkspaceStore`/`SurfacePool` services; the caller is an accepted in-window
  gesture with no public principal. One click returns one finite placement/delivery outcome,
  creates no new lifetime beyond the terminal pane the workspace already owns, and fails
  before mutation when the executable or anchor is unavailable. The title-bar `+` opens a
  fresh tab, a tab anchor opens a fresh pane in that tab, and empty-tab/empty-pane/empty-grid
  anchors fill their designated space. Backpressure is the existing one-pending-string per
  pane readiness slot. This adds no intent, event, contribution, resource protocol, command
  registry, public `tenon` path, or persisted preference;
- file-pane renderer selection (T-038): `SlotContent.file(path:)` and its native editor
  were already host-owned, so rendering a PNG as a picture or an HTML file as a page
  crosses no ownership boundary — same-owner DIRECT, no new intent, no new plugin, no new
  `tenon` member. `FilePaneKind` is the pure rule that picks the renderer, asserted without
  a window. The HTML preview deliberately does **not** borrow `PluginWebSurfacePool`: that
  pool keys surfaces by plugin installation so each plugin owns a persistent browser
  profile, and minting a fake installation would give a host pane a plugin's identity and
  its cookie jar. The preview is a renderer, not a browser — no JavaScript, ephemeral data
  store, read access scoped to the file's own directory, and any navigation away is
  refused;
- a file cited in Agent Lens prose (T-068): agents name paths constantly, and the return
  path from a claim to the file it is about crosses no ownership boundary. Agent Lens is
  host-native `TenonApp` UI and `SlotContent.file(path:)` is the host's own pane, so the
  click calls the typed `WorkspaceStore.openContent` use case, exactly as the changes panel
  already does for a diff. `workspace.content.open.v1` remains the public adapter over that
  same service for plugin, CLI, and agent callers — one typed semantic implementation, no
  second public path, and no app intent principal minted for built-in UI. Which spans are
  citations is the pure `AgentFileReferenceRule`, and only a path that resolves to a file
  under the workspace root renders as a link, so a click always lands on evidence;
- plugin-host administration from the Settings UI;
- Automation Canvas and Settings separation: the host-native `SlotContent.automation`
  pane reads manifest declarations, scheduler phase, plugin availability, and delivery
  history; its schedule selection, search/filter controls, Run Now, Create with AI, and
  persisted per-schedule Pause/Resume call typed application services **DIRECT**. The
  semantic owner is the built-in host, the caller is an accepted in-window gesture with no
  public principal, each action has one finite local outcome, and no queue or lifetime is
  created. A pause is host preference state: ticks keep advancing while automatic delivery
  is suppressed, so resume never catches up skipped events; manual Run Now remains
  available. A global preference epoch invalidates a whole in-flight batch across an Off/On
  cycle, while per-schedule epochs skip only the changed owner and preserve unrelated
  firings. Persistence is best-effort through the existing preferences store and live state
  changes immediately. **host-native core:** VISION requires built-in Canvas slot
  surfaces and makes human supervision, explicit attention, and evidence navigation the
  product; plugin declarations remain CONTRIBUTIONs and event delivery remains EVENT.
  Settings owns only the persisted global scheduled-delivery preference and applies it
  through the same-owner composition root; disabling scheduled delivery does not disable
  the declaring plugin. Empty-pane placement is typed `WorkspaceStore` control. The
  discoverable `dev.tenon.core-commands.automation.open.v1` row is plugin-owned palette/
  launcher metadata (CONTRIBUTION); accepting it carries the `user` principal through that
  finite plugin-owned INTENT, whose provider nested-sends the existing
  `workspace.tab.create.v1` INTENT with `content.kind = automation`. This adds no core
  intent, generic app principal, public `tenon` path, or second workspace mutation API;
- browser-surface renderer identity (T-077): the User-Agent a `WebSurface` sends, and the
  disposition of a `target="_blank"` navigation the main frame asks for. Both are properties
  of the host-owned WebKit renderer, whose single semantic owner is `PluginWebSurfacePool` —
  already DIRECT above. A plugin asks a surface to go somewhere through the
  `browser.surface.*` INTENTs and never sees the header the host writes, so neither decision
  crosses an ownership boundary, adds a principal, or adds a `tenon` member. The identity is
  one contribution to the string WebKit composes (`applicationNameForUserAgent`), never a
  whole-string `customUserAgent` override, so there stays exactly one knob for it. The popup
  disposition is the pure `WebSurface.popupTarget` rule — an allowed http/https URL named by
  the **main frame** loads in place; a subframe's request is declined, because adopting it
  would let an embedded third party replace the pane's top-level document with no user
  gesture. Both rules are asserted without a window;
- pure parsers, ranking, schemas, and value transformations;
- `tenon.path.join/normalize/basename/dirname/extname`, implemented entirely inside the
  plugin runtime as pure string functions.

#### Adding a DIRECT entry

This inventory has 17 entries, pinned in `DirectInventoryGateTests`.

Step 4 of the ordered decision law is self-ratifying. The five same-owner conditions in
**Terms** — one semantic owner, no caller principal, no independent lifetime, no public
mechanism, no ecosystem contract — are satisfied by construction for any Swift shipping
inside the app bundle, so an author who writes a behaviour in the host has already met the
test that would have sent it elsewhere. The measurement: this inventory went from 11
entries and 3,363 normalized characters at `fcac70d` to 17 entries and 10,788 characters,
while the public plugin surface moved about one intent. Growth of 1.55× in entries and
3.21× in characters over that span was ambient, not decided. Adding to this inventory is
therefore a reviewed edit.

An entry that is **added**, or an existing entry that is **enlarged**, MUST carry exactly
one labelled clause:

- **why not a plugin:** naming the specific missing CONTRIBUTION, EVENT, or INTENT — name
  the missing thing, not the difficulty; or
- **host-native core:** citing the VISION requirement that puts the behaviour in the host.

Enlarging an existing entry is the same act as adding one, and it is how this inventory
actually grew. `launcher surfaces and tab-context placement (T-039, AIO-8)` went from 1,571
to 2,727 characters over the same span and absorbed an entire further DIRECT behaviour —
empty-grid launcher placement — under an unchanged heading. A gate that counted only
entries would have passed that change without a word.

"No plugin presentation surface existed" is refuted by shipped code and MUST NOT be offered
as justification. `PluginViewModal` (`poc/Sources/TenonCore/PluginRuntimeModels.swift:81`)
publishes a window-level sheet over the whole shell across the plugin boundary, and the
bundled kanban plugin already uses it (`poc/plugins/kanban/main.js`, `specification.modal =
modal`). A justification must name what is missing, and that one is not.

Removal is legitimate and is the direction this law wants: reclassifying a DIRECT behaviour
into a CONTRIBUTION, EVENT, or INTENT and deleting its entry shrinks the host's private
surface. The fix for the resulting red is to lower the pinned count in the same change, not
to keep the entry.

The 17 entries above predate this rule and are grandfathered — pinned in that test by exact
lead phrase and exact normalized length, so they can shrink or disappear freely but cannot
quietly grow. Convenience, familiarity, and "it was easier in Swift" are not justifications.

### SCOPED FACILITY

SCOPED FACILITY is a deliberately closed exception for fixed plugin-runtime services. Its
exact allowlist is:

| Surface | Scope and reason |
|---|---|
| `tenon.settings.get` | read-only snapshot of this plugin's manifest-declared settings |
| `tenon.storage.get/set` | this plugin's private, host-persisted non-secret state |
| `tenon.log` | diagnostic output attributed to this plugin runtime |

A scoped facility MUST satisfy every property:

- its namespace is fixed by the host and cannot have alternate providers;
- it is scoped to the current plugin identity and runtime generation;
- it cannot address another plugin or arbitrary host capability;
- it is not discoverable or invocable from palette, CLI, agent, or another plugin;
- it does not create a product verb that an external caller may need;
- it has one unsurprising implementation and no routing decision.

The allowlist is exact, not an example list. A fourth facility requires changing this
decision record and its architecture fitness test in the same reviewed change. A new
finite plugin→host capability defaults to INTENT.

Secrets are not storage: `secrets.*` remain intents because Keychain access is sensitive,
policy-gated authority. Path helpers are not facilities: they are pure DIRECT JavaScript
functions with no bridge crossing.

### INTENT

INTENT is selected only after the preceding classes fail. An intent MUST:

- cross a plugin, CLI, agent, palette/registered-product-keybinding, or other independent
  principal boundary;
- be finite and settle exactly once;
- have one canonical versioned name, input schema, output schema, effects, domain errors,
  audiences, authority bindings, timeout, and owner;
- enter the same contract catalog, policy engine, provider registry, admission, lifecycle,
  and telemetry path on every public adapter;
- call a typed application service at a host provider boundary rather than reimplementing
  domain behavior in the provider.

A finite operation on an already existing terminal or browser surface is still an intent
when a plugin/CLI/agent asks for it and policy must authorize the operation. The surface's
creation, retention, and destruction remain RESOURCE/DIRECT lifecycle. This separates a
finite cross-principal action from the resource it targets.

Elapsed time alone does not change cardinality. A finite wait or collected process may run
asynchronously, observe an internal cancellable resource, honor a deadline, and still be an
INTENT when the caller receives exactly one terminal result. It becomes a public RESOURCE
when the initial reply returns a handle through which the caller observes subsequent
values or controls an independently continuing lifetime. Rate-limited request progress is
control-plane metadata, not an additional result.

Workspace and pane designation lives in `options.scope.workspaceID/paneID`, not repeated in
every input schema. Those IDs are explicit caller-selected designations, never authority:
policy still authorizes the resolved resource for that principal. `userGestureID` is
host-minted only. A provider's nested `call.send` preserves causal scope by default and may
explicitly retarget only within that provider/plugin principal's own grants.

#### Canonical core intent inventory

The inventory, audience profile, and execution-lane classification are closed and
code-owned by `CoreIntentName`. Adding, removing, renaming, or changing a classification
requires the change protocol below.

| Domain | Canonical v1 intents | Audience |
|---|---|---|
| Filesystem | `filesystem.directory.list.v2`, `filesystem.file.read.v1`, `filesystem.path.exists.v1`, `filesystem.file.write.v1`, `filesystem.directory.create.v1`, `filesystem.file.create.v1`, `filesystem.path.move.v1`, `filesystem.path.trash.v1` | plugin, CLI, agent |
| File/OS | `file.reveal.v1`, `file.open.v1`, `url.open.v1` | plugin, CLI, agent |
| Clipboard | `clipboard.write.v1` | plugin |
| Process | `process.exec.v1` | plugin, CLI, agent |
| Terminal | `terminal.write.v1`, `terminal.run.v1`, `terminal.open.v1`, `terminal.viewport.read.v1`, `terminal.scrollback.read.v1`, `terminal.wait.v1` | plugin, CLI, agent |
| Browser surface | `browser.surface.load.v1`, `browser.surface.back.v1`, `browser.surface.forward.v1`, `browser.surface.reload.v1` | plugin |
| User interaction | `ui.pick.v1`, `ui.prompt.v1`, `ui.confirm.v1`, `ui.toast.v1` | plugin |
| Secrets | `secrets.get.v1`, `secrets.set.v1`, `secrets.delete.v1` | plugin |
| Workspace | `workspace.state.v1`, `workspace.pane.owner.v1`, `workspace.tab.create.v1`, `workspace.pane.split.v1`, `workspace.pane.focus.v1`, `workspace.pane.close.v1`, `workspace.pane.content.set.v1`, `workspace.content.open.v1`, `workspace.tab.next.v1`, `workspace.tab.previous.v1`, `workspace.pane.focus-next.v1`, `workspace.select.v1` | plugin, CLI, agent |
| Network | `network.fetch.v1` | plugin, CLI, agent |

Core intents have exactly two audience profiles:

- **programmatic:** `{plugin, cli, agent}`;
- **plugin-only:** `{plugin}`.

No core intent is exposed directly to the palette. Palette/registered-product-keybinding
rows come from plugin-owned intent contracts with presentation metadata. No core intent is
exposed to a generic app audience. No contract grants a `core` caller extra authority.

#### Core execution-lane law

`dev.tenon.core` is one provider identity with one active generation. Its physical
execution topology is the following closed map:

| Lane | Exact intents |
|---|---|
| `filesystem` | `filesystem.directory.list.v2`, `filesystem.file.read.v1`, `filesystem.path.exists.v1`, `filesystem.file.write.v1`, `filesystem.directory.create.v1`, `filesystem.file.create.v1`, `filesystem.path.move.v1`, `filesystem.path.trash.v1` |
| `system` | `file.reveal.v1`, `file.open.v1`, `url.open.v1`, `clipboard.write.v1` |
| `process` | `process.exec.v1` |
| `network` | `network.fetch.v1` |
| `workspace` | `workspace.state.v1`, `workspace.pane.owner.v1`, `workspace.tab.create.v1`, `workspace.pane.split.v1`, `workspace.pane.focus.v1`, `workspace.pane.close.v1`, `workspace.pane.content.set.v1`, `workspace.content.open.v1`, `workspace.tab.next.v1`, `workspace.tab.previous.v1`, `workspace.pane.focus-next.v1`, `workspace.select.v1` |
| `terminalImmediate` | `terminal.write.v1`, `terminal.run.v1`, `terminal.open.v1`, `terminal.viewport.read.v1`, `terminal.scrollback.read.v1` |
| `terminalWait` | `terminal.wait.v1` |
| `browser` | `browser.surface.load.v1`, `browser.surface.back.v1`, `browser.surface.forward.v1`, `browser.surface.reload.v1` |
| `userPrompt` | `ui.pick.v1`, `ui.prompt.v1`, `ui.confirm.v1` |
| `userNotification` | `ui.toast.v1` |
| `secrets` | `secrets.get.v1`, `secrets.set.v1`, `secrets.delete.v1` |

Every core intent belongs to exactly one lane. Every lane owns a distinct bounded mailbox,
which bounds both what may be **queued** and how many of its requests may be **running**.
Concurrency is **1 — serial — for every lane by default**, and a lane raises it only where
serialization does no work: its requests must be mutually independent, hold no resource, and
carry no meaningful order between them. Raising it is a change to this law and takes the
change protocol below.

| Lane | Concurrency | Why |
|---|---|---|
| `terminalWait` | 8 | `terminal.wait.v1` blocks until a pane-scoped condition holds. Waits are independent, each scoped to its own pane, hold nothing, and have no order between them. Serial, a second supervised agent could not be waited on at all — see the resolved counterexample under **Falsification**. Bounded at 8 because supervision is human-scale. |
| every other lane | 1 | Filesystem, workspace, process, terminal writes: ordering is the property that makes the lane mean something. |

Global admission, authority, generation leasing, cancellation, health, and retirement apply
across the complete generation, and retirement settles **every** running request in a lane,
not merely one.

Browser v1 uses one fixed `browser` lane. Its handlers settle after enqueueing an operation
on the caller-scoped surface. A future handler that awaits navigation completion must define
bounded partition cardinality, surface-key lifecycle, and cross-surface progress tests before
introducing per-surface lanes.

Plugin-owned contracts MUST be namespaced by the full `PluginID`, declare `uses` and
`provides` before evaluation, and may expose only audiences permitted by host policy.

### EVENT

An event's name is past tense or otherwise states a fact. Publishing succeeds when the
fact is accepted for delivery; it does not mean observers completed work. Observers MUST
NOT be part of the publisher's transaction.

An observer may retain an unsubscribe token. That token controls observation; it does not
own the publisher or create the underlying fact producer, so the channel remains EVENT.
When a call creates a producer whose outputs are correlated to and controlled by the
caller's handle—such as a filesystem watch or process run—the interaction is RESOURCE.

Current EVENT inventory:

- workspace/tab/pane/content/focus facts emitted by `WorkspaceStore`;
- terminal title, command-finished, exit, and other terminal facts;
- host-private agent lifecycle facts reported by Codex and Claude provider hooks. Each
  adapter accepts an already-happened root session event (`session_id`, `transcript_path`)
  only for the exact live terminal-surface incarnation; provider identity is explicit and
  the hook resolves the provider ancestor's process group rather than reporting its own
  short-lived shell group. Same-directory transcript recency is never treated as session
  identity. These facts do not request provider mutation, are not exposed to plugins, and
  never enter the intent dispatcher;
- `pane.cwd-changed`: a pane's working directory and resolved project root. Published by
  the host after it resolves the root (`ProjectRoot.resolve`), and only when the *root*
  moves — an ordinary `cd` inside one repository updates the pane and notifies nobody, so
  observers cannot be made to thrash by shell noise. Named `pane.*` rather than
  `terminal.*` deliberately: the `terminal.` prefix gates delivery on the `terminal.read`
  permission, and observing which directory a pane is anchored to must not require
  permission to read terminal contents;
- targeted browser URL/title/loading/navigation facts;
- plugin view user facts delivered to the owning plugin (`onSelect`, `onSubmit`,
  `onOpen`, `onClose`);
- palette query facts (`text`, host-owned monotonic `revision`) delivered owner-scoped
  to plugins that registered a palette provider (`tenon.palette.onQuery`); the palette
  publishes them without awaiting any observer;
- `automation.fired` (T-046): a manifest-declared automation schedule came due.
  Published by the host scheduler owner-scoped to exactly the declaring plugin, never
  broadcast — a schedule is that plugin's own declaration, so its firing needs no
  permission gate and must not be observable by anyone else. Payload: `scheduleId`,
  `scheduledFor` (ISO 8601), `late`, `trigger`. After a missed stretch at most the
  latest occurrence fires, and only within the schedule's declared grace;
- settings-change and plugin lifecycle facts.

An event MUST NOT be used to ask the host to mutate state. If the publisher needs a result,
failure, deadline, or authorization decision, the interaction is not an event.

### Two-way interaction, without a two-way channel

Reviewed in full 2026-07-31 (T-042) against five shipped cases. The conclusion was that the
existing rungs compose, and that **no CHANNEL rung is admitted**. This section exists so the
question is answered rather than reopened.

**The trap.** What people reach for when they say "channel" is almost always *an event with
a reply*. That is a command wearing an event's clothes: a reply means somebody must answer,
which means failure, deadline and authority semantics, which is an INTENT. Every real case
below had exactly one answerer (intent) or none (event). None needed both at once.

**The three composed patterns.** Use these; they are sufficient.

| Shape | Mechanism | Worked example |
|---|---|---|
| Ask and be answered, either direction | INTENT out via `intents.send`; INTENT in via a contract in `intents.provides` + `intents.handle`. Two directions is two declared contracts, not one duplex pipe | plugin↔plugin request/reply |
| Tell, with 0..n listeners | EVENT. No reply — if the publisher needs one, it is an intent | `automation.fired`, palette `onQuery` |
| Long work with progress and cancellation | **A bounded value that names the work, re-presented on each call.** Not a live handle | `terminal.open.v1` → pane id; progress via `terminal.wait.v1`/`terminal.scrollback.read.v1` scoped to it; cancel via `workspace.pane.close.v1` |

**Why the third row is a value and not a handle.** An agent's lifetime *is* its pane's
lifetime — closing the pane releases the surface and frees the PTY with its child process —
so the workspace already names the work, and a TASK handle would be a second name for it. A
value survives hot reload, can be persisted, and leaks nothing when dropped. The same shape
appears in `terminal.scrollback.read.v1`'s cursor, arrived at independently: **an opaque
value, re-presented, is how this codebase expresses continuity.** Reach for it before
reaching for a handle.

**The gap that was real, now closed (T-049).** A plugin could observe facts and not publish
one. `tenon.events.emit` completes the rung. Two declarations, and neither side names the
other: a publisher declares only the **local** name of a channel it owns, and the host adds
the owning prefix from the identity it already holds — so `automation.fired` and other
plugins' channels are unreachable by construction, not by a check. An observer declares the
fully qualified name it wants, which is the second gate: publishing makes a fact available,
observing is still declared authority. The publisher learns nothing about who listened, and
a fact with no observers is delivered nowhere and succeeds. The moment either of those
stopped holding, this would be a fan-out command rather than an event.

**Out of scope by construction.** Structured conversation with an agent running in a PTY is
framing *inside the byte stream* — which is what OSC 133 already is. A Tenon-level duplex
channel would have nothing on the other end, because the CLI speaks its own stdio.

### RESOURCE / STREAM / TASK

The initial finite request MAY return a handle, but all subsequent multi-result or
independently continuing lifetime semantics belong to a bounded resource protocol. A
resource protocol MUST define owner, capacity, overflow, cancellation, teardown on hot
reload, and terminal state.

**A continuation token is not a handle.** An intent may hand back an opaque value that a
later call passes in — a paging cursor is the standard case — and that does not move the
interaction onto this rung. The test is ownership and lifetime, not repetition: a handle
names host state that exists between calls, has to be torn down on hot reload, and leaks if
the caller forgets it. A cursor is a value, it can be dropped with no consequence, and it
expires by being refused. `terminal.scrollback.read.v1` pages this way and stays an INTENT;
continuous terminal output, which the host would push without being asked, would not.

**The staged half of `filesystem.file.write.v1` is a resource protocol, not a cursor.** One
call with no cursor is a finite atomic write and stops at INTENT. Passing `commit: false`
opens a staging: a dot-file beside the target plus a ledger entry naming it, which is host
state that exists between calls and leaks if the caller walks away — exactly what the
paragraph above says a cursor is not. It is therefore inventoried here and MUST keep
answering the six questions this rung asks:

- **owner** — one `FileWriteStagingRegistry` per `FilesystemIntentProvider` instance, so
  every bound below is enforced against the provider generation that opened the staging;
- **capacity** — four concurrent stagings, each pinning one parent directory descriptor;
  a fifth open fails closed with `staging-capacity-exhausted`;
- **overflow** — 1 MiB total staged bytes (`maximumStagedFileWriteBytes`), each page
  separately bounded by the inline text limit;
- **cancellation** — any failed page discards the staging and unlinks its dot-file; the
  cursor it issued is then refused as invalid input;
- **teardown on hot reload** — the registry belongs to the provider generation and dies
  with it; a staging that outlives its opener is swept at the next write, and its
  300-second lifetime is fixed when it opens and never extended;
- **terminal state** — the committing rename, or expiry. The target never holds
  intermediate content; only the rename is observable.

The 113 KB kanban board is why this exists: a supervision artifact a plugin must rewrite
atomically does not fit one inline page, and half-writing it is worse than refusing it.

Current RESOURCE inventory:

- `tenon.timers.after/every/cancel`;
- `tenon.process.stream` and its output/exit/overflow/cancel lifecycle;
- `tenon.fs.watch` and its cancel lifecycle;
- `filesystem.file.write.v1` stagings, bounded as above;
- terminal surfaces and browser surfaces retained by their host pools;
- Agent Lens transcript tails: one bounded, cancellable read resource for the exact
  hook-bound root transcript of a terminal-surface incarnation;
- future large filesystem/process/terminal bodies returned as opaque handles.

Plugin runtime retirement MUST cancel or retire every resource owned by that generation.
No resource callback may enter a destroyed JavaScript context.

Known conformance gap: `tenon.process.stream` currently terminates its Foundation `Process`
leader but cannot prove descendant retirement. It is not process-tree supervision until its
launcher owns a POSIX process group and joins it during generation teardown.

### CONTRIBUTION

Contributions are authoritative snapshots or registrations, not commands. The contributor
owns the data; the host owns validation, indexing, rendering, reconciliation, and native
objects.

Current CONTRIBUTION inventory:

- manifest setting schemas and plugin presentation metadata;
- manifest `automation.schedules` declarations (T-046): wall-clock cadence the plugin
  owns and the host validates fail-closed, reconciles per generation, and fires as the
  owner-scoped `automation.fired` event;
- `tenon.statusBar.set`;
- `tenon.views.register/set` and owner-scoped select/submit/open/close callbacks;
- `tenon.palette.registerProvider/setResults`: dynamic palette provider registration and
  its revision-scoped result snapshots (bounded; a publication for a superseded query
  revision is dropped; each result designates an intent the publishing plugin provides);
- plugin view trees, rows, menus, and native component descriptions;
- plugin-owned intent contracts and their palette/registered-product-keybinding presentation
  metadata.

Repeated publication replaces the contributor's previous state for the same key. Hot
reload removes the retired generation's contributions atomically.

## Reserved control plane

Control-plane operations maintain a protocol, registry, provider generation, request, or
resource. They are not product/domain intents and MUST NOT be extensible by plugins.

Reserved control-plane operations are:

- CLI framing/version negotiation, `ping`, and per-install-channel single-instance app
  activation/focus;
- intent `list`/`describe` discovery and projection revision handling;
- provider stage, bind, readiness, generation swap, retire, and lease drain;
- request cancellation, progress, settlement, tracing, and telemetry metadata;
- resource handle status/read/progress/cancel where the resource protocol defines them;
- plugin runtime activation, hot-reload generation teardown, and health diagnostics.

The CLI has exactly two direct domain-adjacent controls: `ping` and the same-channel
single-instance activation/focus handshake. Production and staging never address one
another through that handshake. Workspace state/mutation, terminal send/read/wait, files,
processes, and every other finite action use `intent list`, `intent describe`, and `intent
send`.

A control-plane message MUST NOT contain a product-specific operation such as “split pane”
or “open file.” Adding such a payload is a boundary violation, even if it avoids adding a
new public intent.

## Public plugin-runtime inventory

This table is exhaustive. A new top-level `tenon` member requires classification and a
fitness-test update in the same change.

| Surface | Classification |
|---|---|
| `tenon.apiVersion` | reserved immutable runtime metadata |
| `tenon.agents.run` | DIRECT JavaScript composition over the INTENT adapter (T-048): runs a command in a new pane to completion and returns its transcript by composing `terminal.open.v1` → `terminal.wait.v1` → `terminal.scrollback.read.v1` inside the caller's generation. Caller-principal: every underlying send is policy-checked against this plugin's own declared uses; the function grants nothing and crosses no new bridge |
| `tenon.intents.send` | INTENT adapter |
| `tenon.intents.handle` | reserved provider control plane |
| `tenon.intents.list` | reserved discovery control plane |
| `tenon.settings.get` | SCOPED FACILITY |
| `tenon.storage.get` | SCOPED FACILITY |
| `tenon.storage.set` | SCOPED FACILITY |
| `tenon.log` | SCOPED FACILITY |
| `tenon.path.join` | pure DIRECT utility |
| `tenon.path.normalize` | pure DIRECT utility |
| `tenon.path.basename` | pure DIRECT utility |
| `tenon.path.dirname` | pure DIRECT utility |
| `tenon.path.extname` | pure DIRECT utility |
| `tenon.events.emit` | EVENT publication control for manifest-declared, plugin-owned channels |
| `tenon.events.on` | EVENT subscription control |
| `tenon.timers.after` | RESOURCE creation |
| `tenon.timers.every` | RESOURCE creation |
| `tenon.timers.cancel` | RESOURCE lifecycle control |
| `tenon.process.stream` | RESOURCE creation |
| `tenon.fs.watch` | RESOURCE creation |
| `tenon.statusBar.set` | CONTRIBUTION publication |
| `tenon.views.register` | CONTRIBUTION registration |
| `tenon.views.set` | CONTRIBUTION publication |
| `tenon.views.onSelect` | EVENT subscription control for owner-scoped UI facts |
| `tenon.views.onSubmit` | EVENT subscription control for owner-scoped UI facts |
| `tenon.views.onOpen` | EVENT subscription control for owner-scoped lifecycle facts |
| `tenon.views.onClose` | EVENT subscription control for owner-scoped lifecycle facts |
| `tenon.palette.registerProvider` | CONTRIBUTION registration |
| `tenon.palette.onQuery` | EVENT subscription control for owner-scoped palette query facts |
| `tenon.palette.setResults` | CONTRIBUTION publication (revision-scoped; host drops stale revisions) |

Finite filesystem, process execution, terminal, browser navigation, workspace, UI, secrets,
network, OS, and clipboard operations are available only through `tenon.intents.send`.
The former unrendered sidebar surface was removed; pane-hosted `tenon.views` is the
declarative view contribution.

## Performance and lifecycle consequences

- DIRECT calls pay normal typed Swift dispatch only.
- Pure `tenon.path.*` functions stay inside JavaScript and cross no bridge.
- SCOPED FACILITY calls perform only plugin-scope lookup/validation; they do not enter
  contract resolution or provider mailboxes.
- INTENT converts JS/CLI JSON to `IntentValue` once at the trust boundary, uses compiled
  validators, O(1) catalog/provider lookup, bounded admission, and one conversion at the
  provider boundary. It MUST NOT stringify/parse JSON between in-process Swift layers.
- EVENT delivery is bounded and cannot block the fact publisher on observer work.
- RESOURCE queues and buffers are bounded; overflow behavior is explicit.
- CONTRIBUTION updates are diffed/coalesced by key and rendered from immutable snapshots.
- A `confirmation: policy` wait is bounded by the caller's deadline like every other phase of
  a dispatch. An unanswered prompt expires into `tenon.deadline-exceeded`; it does not hold
  the request. A prompt shared by several waiters survives the first of them expiring, so one
  caller's deadline cannot take the dialog away from another who is still waiting on it.

**Confirmation is interactive by design, and is not granted to non-interactive principals.**
A plugin holds standing consent because it was *installed* — a human act of trust over a
manifest that declares exactly which intents it uses. A CLI or agent principal has neither:
anything able to open the control socket is that principal, so seeding it with standing
consent would let any process on the machine run `.policy` verbs unprompted. That is not
consent, it is an open door. The lawful route for unattended work is to be a plugin, which
is what `tenon.agents.run` and the shipped fleet-review example do. The consequence is
accepted and stated rather than worked around: a CLI caller with no human at the window can
read state, and its `.policy` verbs expire at their deadline instead of hanging.

The UI thread MUST perform only UI work. Filesystem, process, network, schema compilation,
plugin execution, and unbounded resource work MUST NOT run on `MainActor`. Execution
isolation preserves forward progress for built-in UI, unrelated provider generations, and
unrelated core execution lanes.

### The kernel latency budget

**One `IntentDispatcher.send` MUST cost at most 700× the CPU of the same provider operation
invoked as a typed DIRECT call**, measured as the cheapest of fifteen samples.

**Why a ratio.** An absolute microsecond figure from one machine under one load is
unreproducible, and an unreproducible budget is not a budget. Per-send absolutes swung
294–365 µs across nine runs on one idle machine in one build configuration; the ratio over
the same runs moved by 6%.

**What the denominator is.** An `actor` method returning the same `IntentValue`, awaited
from the same context, so both arms pay exactly one actor hop. A non-actor baseline would
omit the hop the intent path necessarily pays, and would inflate the ratio for free.

**What the ratio therefore isolates.** `IntentValue` conversion, compiled input and output
validation, catalog and contract lookup, policy, capability and audience checks, the
confirmation authorizer, provider selection, admission, mailbox enqueue and drain, and
telemetry. Idempotency is **not** on this path: the fixture's `.pessimistic` effects declare
`idempotency: .none` (`poc/Sources/TenonIntentCore/IntentEnvelope.swift:114`). The
confirmation authorizer **is** on it, because `.pessimistic` declares `confirmation: .policy`
(`:116`) — a read-shaped contract declaring `.never` pays less, so this ratio is the
expensive end of the kernel, not its average.

**Measurement record.** 2026-08-07, Apple Silicon, `swift test` debug build, 15 samples of
100 paired iterations after 200 paired warmups. Nine runs gave per-run medians of 393.4× to
416.8×, with the worst single sample at 463.4×; the direct arm cost 746–937 ns per call and
the intent arm 294–365 µs per call. The ceiling of 700× is 1.68× headroom over the worst
observed median. The debug absolutes are large in their own right and are recorded here so a
future release-build measurement has something to be compared against; the enforced figure is
the debug ratio, because that is the configuration the fitness suite runs in.

**Why CPU time.** `getrusage(RUSAGE_SELF)` rather than wall time: under load the same
statistic computed from wall clock is dominated by scheduling, and a flaky fitness test gets
deleted rather than fixed. `.kanban` T-074 records exactly that failure mode for two existing
wall-clock-dependent suites, so the instrument choice is load-bearing, not incidental.

**Resolving power, stated honestly.** This is a drift alarm, not a precision instrument. A
regression that doubles kernel CPU per send trips it from anywhere in the observed baseline
distribution (2 × 393.4 = 786.8 > 700). A 1.5× regression can pass (1.5 × 393.4 = 590.1). The
concrete regressions it is meant to catch are a JSON round trip between in-process Swift
layers — already forbidden in prose above, and until now unenforced — a per-send schema
recompile, and a second policy pass.

**Instrument caveat.** `getrusage(RUSAGE_SELF)` is process-wide, and every test target links
into one `TenonPackageTests.xctest` process. Work leaked by other test classes — plugin
runtimes, FSEvents, automation schedulers — lands in both arms. Because that contamination
scales with each arm's elapsed time it largely cancels in the ratio, but it is the first
thing to suspect if this test starts drifting. If XCTest is ever run with parallel test
classes, this measurement becomes invalid and the test MUST be revised, not suppressed.

`IntentKernelLatencyBudgetTests.testOneKernelSendStaysInsideTheDocumentedLatencyBudget`
enforces this, and it reads `700` out of the sentence above, so the law and its enforcement
cannot drift apart.

## Change protocol

A change that adds or changes an interaction MUST include all of the following:

1. Apply the ordered decision law and name the selected mechanism in the design/review.
2. State semantic owner, caller principals, result cardinality, lifetime, authority,
   failure semantics, and backpressure.
3. Update the exact inventory in this document and the corresponding source-owned
   inventory in one change.
4. Add or update a fast architecture fitness test that fails before the implementation is
   accepted.
5. Delete the superseded public path in the same vertical slice. One behavior may keep
   internal typed service and public adapter entry points; it may not keep two public
   protocols.
6. Run source-wide stale-surface search plus the relevant build, tests, and performance
   probes.
7. Obtain a reviewer/verifier pass separate from the authoring pass.
8. A change that adds a DIRECT inventory entry, or enlarges an existing one, MUST
   additionally satisfy **Adding a DIRECT entry**: carry the labelled justification clause
   in the entry text, and update the pinned entry count and per-entry length in
   `DirectInventoryGateTests` in the same reviewed change. A reviewer MUST be able to name
   the missing CONTRIBUTION, EVENT, or INTENT from the entry text alone.

Changing the law itself requires an ADR-quality change: a concrete counterexample,
trade-off analysis, updated decision order, inventory migration, and updated fitness
functions. A feature request alone is insufficient.

## Required fitness functions

The architecture suite MUST fail when:

- a new `CoreIntentName` lacks an inventory, audience, or execution-lane classification;
- a core intent audience differs from its exact profile above;
- the implemented core lane map differs from the exact table above;
- a core intent belongs to zero or multiple lanes;
- two core lanes share one physical mailbox;
- lane creation depends on unbounded caller input;
- global admission can be multiplied by adding lanes;
- logical cancellation releases global or per-principal admission while the started
  operation remains physically active;
- generation shutdown begins while any lane remains physically active;
- app/UI code creates or uses a generic app intent principal;
- a public adapter bypasses the dispatcher for a finite cross-principal operation;
- ordinary same-owner app code serializes through `IntentValue` or calls the dispatcher;
- a registered, discoverable, or rebindable product keybinding bypasses the plugin-owned
  intent presentation projection;
- a focused-view-local keyboard control with no public command registration enters the
  intent dispatcher;
- a new public `tenon` path is outside the exact runtime inventory;
- a fourth scoped facility appears;
- shipped plugin code uses a finite handwritten host API instead of a declared intent;
- a plugin sends an intent absent from `manifest.intents.uses`;
- a plugin handles an intent absent from `manifest.intents.provides`;
- a product command appears in CLI/control-plane code;
- an EVENT asks for a result, an INTENT streams indefinitely, or a CONTRIBUTION performs an
  imperative mutation while being parsed;
- two public mechanisms perform the same action;
- a DIRECT inventory entry is added or enlarged without the labelled justification clause
  required by **Adding a DIRECT entry**;
- the DIRECT inventory's entry count or per-entry size differs from the pinned values
  without a matching edit to this document;
- one `IntentDispatcher.send` exceeds the kernel latency budget.

Fitness failures are architecture failures. The accepted responses are to fix the
violation or revise this law and its enforcement together; suppressing the test alone is
not an accepted response.

## Falsification

This decision is wrong and MUST be revised if evidence proves any of these:

- two engineers applying the ordered law to a real interaction reach different answers
  because a term remains ambiguous;
- a scoped facility needs provider choice, cross-plugin addressing, external discovery,
  capability policy, or a product-level contract;
- a direct call needs independent lifecycle, principal authority, or ecosystem
  compatibility;
- an intent produces more than one terminal result or must stay alive indefinitely;
- a resource cannot state a finite buffer, owner, cancellation, and teardown rule;
- the adapter and built-in UI cannot share one typed domain implementation;
- compiled intent validation/routing causes a measured user-visible regression that cannot
  be removed without removing a safety invariant;
- one `IntentDispatcher.send` exceeds the kernel latency budget above — 700× the CPU of the
  equivalent typed DIRECT call — and cannot be brought back under it without removing a
  safety invariant;
- **a lane's serial mailbox makes a legitimate concurrent product use impossible.**
  Recorded 2026-07-31 against `terminalWait`, with a measurement rather than an argument.

### Resolved counterexample: `terminalWait`'s serial mailbox forbade supervising two agents

**Raised and resolved 2026-07-31.** Kept because the law changed because of it, and because
it is the worked example of what a falsification entry is for.

`terminal.wait.v1` sat alone in the `terminalWait` lane, and every lane was serial. Two
supervised agent runs (`tenon.agents.run`, T-048) therefore could not both be in flight: the
second run's wait queued behind the first, which by design does not return until its
condition is met, while the second run's `terminal.write.v1` proceeded on the unblocked
`terminalImmediate` lane. Its command finished while its wait was still queued; the wait then
snapshotted a baseline that already counted that finish and waited for a second one that
never came. Measured — first agent succeeded, second returned `dev.tenon.agents.timeout`:

```
fleet: alpha=OK-ALPHA beta=ERR:dev.tenon.agents.timeout
```

The serialization was doing no work. Waits are mutually independent, each scoped to its own
pane; ordering between them carries no meaning, and a wait holds no resource — it is a
bounded poll with a deadline, which is precisely why it was split out of `terminalImmediate`
so long waits would not block short operations. Serializing waits among themselves
reintroduced that blocking one level down.

**Resolution: lanes gained a concurrency bound, defaulting to 1.** `IntentMailboxLimits`
carries `maxConcurrentRequests`; the mailbox holds its running requests in a bounded set
rather than one slot, and `drain` starts up to the limit instead of awaiting each reply
inline — the inline await was the whole mechanism. Every lane but `terminalWait` is
constructed at 1, so nothing else changed behaviour. Retirement now settles every running
request rather than one.

The rejected alternative was latch semantics on `terminal.wait.v1` — cheaper, and worse: it
changes what the contract means ("the next finish" becomes "a finish"), and T-044 chose
baseline-relative deliberately so a caller could not be answered by a command that finished
before it asked.

Fitness tests: `IntentMailboxTests.testALaneRunsConcurrentlyWhenItsConcurrencyLimitAllows`
(a start barrier no serial lane can fake) and `testALaneIsSerialByDefault` (the default is
the property that must not drift). End to end,
`AgentFleetIntegrationTests` fans out two agents through the real provider and both complete.
Mutation-proven: returning `terminalWait` to 1, or restoring the drain gate, reddens them.

Passing tests is necessary but not sufficient. The product-level proof is that one
operation behaves identically through every authorized public adapter, same-owner UI stays
responsive through typed direct calls, and exhaustive search finds no competing public
path.
