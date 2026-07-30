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
- CLI, palette, agent, and registered product-keybinding entry points are public adapter
  principals even though the app ultimately serves them;
- two plugins always have different semantic owners, including bundled plugins.

### Principal

A **principal** is the host-minted caller identity used for policy. Principals and semantic
owners answer different questions:

- semantic owner chooses **DIRECT versus a public boundary**;
- principal determines **what a public boundary caller may discover and invoke**.

The current public intent caller audiences are `plugin`, `palette`, `cli`, and `agent`.
A registered product keybinding uses the palette projection/principal and invokes a
plugin-provided intent carrying presentation metadata. Built-in Swift UI is part of the host
semantic owner and has no generic app intent principal. A provider making a nested call uses
its plugin principal; “core” does not mint extra authority.

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
- `WorkspaceStore` and typed workspace use cases;
- terminal and web surface pool retain/reconcile/focus/lifecycle;
- pane activity/attention state (T-029): one `PaneActivity` per slot, fed by the shell's
  fixed-interval terminal-observation poll and the shell's viewed projection, read
  same-owner DIRECT by tab chips, pane headers, sidebar rollups, the title-bar count,
  and the host-native completion-notification adapter. No plugin EVENT exists for this
  state; if a plugin ever needs visibility into pane attention, that is a NEW classified
  EVENT admitted through this law's ordered decision — never a reuse of this host state;
- plugin-host administration from the Settings UI;
- pure parsers, ranking, schemas, and value transformations;
- `tenon.path.join/normalize/basename/dirname/extname`, implemented entirely inside the
  plugin runtime as pure string functions.

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
| Filesystem | `filesystem.directory.list.v1`, `filesystem.file.read.v1`, `filesystem.path.exists.v1`, `filesystem.file.write.v1`, `filesystem.directory.create.v1`, `filesystem.file.create.v1`, `filesystem.path.move.v1`, `filesystem.path.trash.v1` | plugin, CLI, agent |
| File/OS | `file.reveal.v1`, `file.open.v1` | plugin, CLI, agent |
| Clipboard | `clipboard.write.v1` | plugin |
| Process | `process.exec.v1` | plugin, CLI, agent |
| Terminal | `terminal.write.v1`, `terminal.run.v1`, `terminal.viewport.read.v1`, `terminal.wait.v1` | plugin, CLI, agent |
| Browser surface | `browser.surface.load.v1`, `browser.surface.back.v1`, `browser.surface.forward.v1`, `browser.surface.reload.v1` | plugin |
| User interaction | `ui.pick.v1`, `ui.prompt.v1`, `ui.confirm.v1`, `ui.toast.v1` | plugin |
| Secrets | `secrets.get.v1`, `secrets.set.v1`, `secrets.delete.v1` | plugin |
| Workspace | `workspace.state.v1`, `workspace.tab.create.v1`, `workspace.pane.split.v1`, `workspace.pane.focus.v1`, `workspace.pane.close.v1`, `workspace.pane.content.set.v1`, `workspace.content.open.v1`, `workspace.tab.next.v1`, `workspace.tab.previous.v1`, `workspace.pane.focus-next.v1`, `workspace.select.v1` | plugin, CLI, agent |
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
| `filesystem` | `filesystem.directory.list.v1`, `filesystem.file.read.v1`, `filesystem.path.exists.v1`, `filesystem.file.write.v1`, `filesystem.directory.create.v1`, `filesystem.file.create.v1`, `filesystem.path.move.v1`, `filesystem.path.trash.v1` |
| `system` | `file.reveal.v1`, `file.open.v1`, `clipboard.write.v1` |
| `process` | `process.exec.v1` |
| `network` | `network.fetch.v1` |
| `workspace` | `workspace.state.v1`, `workspace.tab.create.v1`, `workspace.pane.split.v1`, `workspace.pane.focus.v1`, `workspace.pane.close.v1`, `workspace.pane.content.set.v1`, `workspace.content.open.v1`, `workspace.tab.next.v1`, `workspace.tab.previous.v1`, `workspace.pane.focus-next.v1`, `workspace.select.v1` |
| `terminalImmediate` | `terminal.write.v1`, `terminal.run.v1`, `terminal.viewport.read.v1` |
| `terminalWait` | `terminal.wait.v1` |
| `browser` | `browser.surface.load.v1`, `browser.surface.back.v1`, `browser.surface.forward.v1`, `browser.surface.reload.v1` |
| `userPrompt` | `ui.pick.v1`, `ui.prompt.v1`, `ui.confirm.v1` |
| `userNotification` | `ui.toast.v1` |
| `secrets` | `secrets.get.v1`, `secrets.set.v1`, `secrets.delete.v1` |

Every core intent belongs to exactly one lane. Every lane owns a distinct bounded serial
mailbox. Global admission, authority, generation leasing, cancellation, health, and
retirement apply across the complete generation.

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
- settings-change and plugin lifecycle facts.

An event MUST NOT be used to ask the host to mutate state. If the publisher needs a result,
failure, deadline, or authorization decision, the interaction is not an event.

### RESOURCE / STREAM / TASK

The initial finite request MAY return a handle, but all subsequent multi-result or
independently continuing lifetime semantics belong to a bounded resource protocol. A
resource protocol MUST define owner, capacity, overflow, cancellation, teardown on hot
reload, and terminal state.

Current RESOURCE inventory:

- `tenon.timers.after/every/cancel`;
- `tenon.process.stream` and its output/exit/overflow/cancel lifecycle;
- `tenon.fs.watch` and its cancel lifecycle;
- terminal surfaces and browser surfaces retained by their host pools;
- future large filesystem/process/terminal bodies returned as opaque handles.

Plugin runtime retirement MUST cancel or retire every resource owned by that generation.
No resource callback may enter a destroyed JavaScript context.

### CONTRIBUTION

Contributions are authoritative snapshots or registrations, not commands. The contributor
owns the data; the host owns validation, indexing, rendering, reconciliation, and native
objects.

Current CONTRIBUTION inventory:

- manifest setting schemas and plugin presentation metadata;
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

- CLI framing/version negotiation, `ping`, and single-instance app activation/focus;
- intent `list`/`describe` discovery and projection revision handling;
- provider stage, bind, readiness, generation swap, retire, and lease drain;
- request cancellation, progress, settlement, tracing, and telemetry metadata;
- resource handle status/read/progress/cancel where the resource protocol defines them;
- plugin runtime activation, hot-reload generation teardown, and health diagnostics.

The CLI has exactly two direct domain-adjacent controls: `ping` and the single-instance
activation/focus handshake. Workspace state/mutation, terminal send/read/wait, files,
processes, and every other finite action use `intent list`, `intent describe`, and
`intent send`.

A control-plane message MUST NOT contain a product-specific operation such as “split pane”
or “open file.” Adding such a payload is a boundary violation, even if it avoids adding a
new public intent.

## Public plugin-runtime inventory

This table is exhaustive. A new top-level `tenon` member requires classification and a
fitness-test update in the same change.

| Surface | Classification |
|---|---|
| `tenon.apiVersion` | reserved immutable runtime metadata |
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

The UI thread MUST perform only UI work. Filesystem, process, network, schema compilation,
plugin execution, and unbounded resource work MUST NOT run on `MainActor`. Execution
isolation preserves forward progress for built-in UI, unrelated provider generations, and
unrelated core execution lanes.

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
- two public mechanisms perform the same action.

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
  meet the budget without removing a safety invariant.

Passing tests is necessary but not sufficient. The product-level proof is that one
operation behaves identically through every authorized public adapter, same-owner UI stays
responsive through typed direct calls, and exhaustive search finds no competing public
path.
