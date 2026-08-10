# PRD — Plugin runtime, trust, capabilities, and generation lifecycle

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-010` |
| Lifecycle | `partial` |
| Owner | plugin-host, plugin-settings, plugin-events, plugin-contributions, and intent domains |
| Reviewers | product, plugin authors, architecture, security, concurrency, operations, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-017, T-018, T-021, T-033, T-037, T-049, T-053, T-062, T-080, T-093 |
| Existing designs | [`design-plugin-builtins.md`](../design-plugin-builtins.md), [`design-plugin-host-capabilities.md`](../design-plugin-host-capabilities.md), [`plugin-author-guide.md`](../plugin-author-guide.md), [`plugin-migration-v0.2.md`](../plugin-migration-v0.2.md), [`research-plugin-runtimes.md`](../research-plugin-runtimes.md) |
| Acceptance specification | [`plugin-runtime.feature`](plugin-runtime.feature) |

## 1. Executive summary

### Problem

Tenon executes replaceable JavaScript plugins that can contribute UI and request sensitive host
work. Without one closed runtime contract, each feature can add another helper, command registry,
permission exception, or lifecycle path. That fragmentation makes plugins difficult to author and
creates security and reliability defects: a manifest can appear to grant itself trust, a stale
generation can mutate current state, a resource can outlive its plugin, or one malformed user plugin
can prevent every bundled plugin from loading.

JavaScriptCore is currently isolated to one pinned thread per runtime, but it still executes inside
the Tenon process. That is an execution boundary, not a hostile-code sandbox. The current
`tenon.process.stream` implementation also terminates only the Foundation `Process` leader, not an
owned process group. The product must state those two limitations honestly instead of implying
containment that does not exist.

### Proposed outcome

Plugin discovery, identity, trust, declaration, policy, activation, replacement, teardown, and
diagnostics follow one deterministic lifecycle. A closed `tenon` vocabulary maps each semantic
interaction to INTENT, EVENT, RESOURCE, CONTRIBUTION, DIRECT, or one of exactly three scoped
facilities. Finite host effects use canonical intents and the same typed services as built-in Swift;
resource callbacks are bounded and generation-owned; plugin state and consent are installation
scoped.

One bad user plugin loses alone. A replacement generation is staged before it can replace the last
good generation. Disable, uninstall, failure, reload, and app shutdown settle every owned lifetime.
Hard OS process isolation and race-free descendant containment remain explicit planned work. Policy
is infrastructure, not a product ceremony: trusted bundled/development code should receive its
declared installation grants automatically, and local code should normally be approved once when
enabled or when its manifest materially expands—not interrupted on every ordinary operation.

### Why now

Historical task state no longer matches the tree. T-080 still has unchecked boxes even though the
ordered bounded `PluginLogQueue`, dropped-line reporting, shutdown drain, and
`PluginLogOrderingTests` ship. Conversely, research used the word “sandboxed” while the author guide
and inventory source correctly say the writable inventory is not a sandbox. This PRD reconciles
those facts so future work cannot restore deleted APIs or accidentally declare the two real gaps
complete.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| normative runtime inventory | [`design-plugin-builtins.md`](../design-plugin-builtins.md), interaction-boundary fitness tests | high | exact top-level API and mechanism classification |
| capability architecture | [`design-plugin-host-capabilities.md`](../design-plugin-host-capabilities.md), intent catalog/providers | high | finite effects use intents and typed application services |
| trust and identity | `PluginInventory`, `PluginInstallationStore`, inventory/persistence tests | high | host-owned provenance, disabled user installs, rotation on trust change |
| runtime boundary | `PluginRuntimeBootstrap`, `PluginRuntime`, built-ins/concurrency tests | high | closed globals, pinned thread, explicit finite limits, bounded shutdown |
| lifecycle | `PluginHost`, host/single-file tests | high | staged swap, last-good preservation, serialized transitions, diagnostics |
| consent and policy | `PluginHostPolicy`, caller-consent and bundled-consent tests | high | separate declaration/grant/consent and fail-closed revocation |
| resources and events | runtime, watcher/event routing/backpressure tests | high | generation ownership, finite queues, explicit overflow |
| historical tasks | T-017/T-018/T-021/T-033/T-037/T-049/T-053/T-062/T-080/T-093 | medium | intended outcomes; old helper/command shapes and stale checkboxes are superseded |
| external runtime research | [`research-plugin-runtimes.md`](../research-plugin-runtimes.md) | medium | process isolation/process-group patterns worth adopting, not current proof |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Let replaceable plugins do useful work without receiving ambient host authority or escaping their owned lifecycle. |
| Primary users? | bundled and user plugin authors, operators enabling plugins, and product features implemented as plugins |
| Success? | deterministic activation, no undeclared effect, no stale callbacks/resources, one-plugin failure isolation, honest trust language |
| Fixed constraints? | mandatory interaction boundary law, closed public inventory, same typed domain implementation, explicit bounded lifetimes |
| Unknown? | exact OS isolation technology and migration release; process-group launch design for streaming commands |

| ID | Assumption | Validation | State |
|---|---|---|---|
| `PRT-A-001` | JavaScriptCore remains suitable for trusted bundled and explicitly enabled local plugins while hard isolation is developed. | threat model and installed-plugin incident review | accepted only with explicit non-sandbox wording |
| `PRT-A-002` | One runtime thread per active generation remains affordable under the supported plugin count. | launch/reload/resource benchmark | continuous measurement |

## 3. Users, jobs, and vocabulary

The primary user is a plugin author who needs a small, predictable API and immediate diagnostics
when declarations, capabilities, or lifecycle behavior are wrong. The affected operator needs to
know when code is bundled/trusted versus locally enabled, and expects disabling or uninstalling it
to end its authority. Host engineers need one semantic implementation and finite shutdown.

- Discover a plugin from a directory or one JavaScript file without different authority rules.
- Know which API to use from the interaction's meaning rather than a feature-specific convention.
- Develop with hot reload while the last valid generation remains usable after a bad edit.
- Enable or disable user code without consent or state leaking across installation identities.
- Observe actionable failures and bounded-loss summaries rather than silent drops or host hangs.

| Term | Meaning | Not to be confused with |
|---|---|---|
| inventory | ordered host-configured plugin root with a trust class | a sandbox or manifest field |
| installation | stable `(PluginID, installationID)` principal | one hot-reload generation |
| generation/session | one monotonically revised runtime for an installation | plugin package version string |
| staging | validation/evaluation/provider binding before public activation | already-active code |
| standing consent | persisted approval for eligible `.policy` contracts | permission declaration or `.always` approval |
| retirement | admission close, cancellation, teardown, state removal, runtime shutdown | merely hiding a pane |

## 4. Goals, measures, scope, and bounds

- `PRT-G-001` — Every public plugin interaction has one normative mechanism and inventory entry.
- `PRT-G-002` — Trust, authority, and persisted state never cross installation provenance silently.
- `PRT-G-003` — Every request, generation, queue, callback, and resource reaches a terminal state.
- `PRT-G-004` — A malformed or colliding late inventory plugin cannot take down valid earlier plugins.
- `PRT-G-005` — Runtime isolation claims match actual technical containment.
- `PRT-G-006` — Permission cost remains proportional to actual irreversible/sensitive risk and does not slow the write–reload–test loop.

Targets: exact public-surface fitness tests stay green; zero undeclared finite host helpers; zero
user plugins auto-enabled; zero stale-generation mutations; all accepted resource queues have a
documented bound and overflow result; host reload/quit returns within its owned deadline; one bad
late-inventory plugin yields one visible failure; secret material never enters JSON/log/telemetry.

Current central bounds include 256 pending outbound calls, 256 storage writes, 512 queued log
lines, 256 timers, 32 process streams, 64 watchers, 256 pending callbacks, 512 owned host tasks,
8 dynamic palette providers, 50 results, 8 actions per result, 256 palette text characters, 8,192
bridge messages per drain, 256 pending watcher paths, 32 published/observed channels, and 128
characters per channel. Persistence admits at most 4,096 installations in a 1 MiB document.

In scope: inventories, discovery, manifests, identity, policy, consent, JavaScript boundary,
built-ins, intents, events, resources, contributions, hot reload, disable/uninstall, persistence,
logs, diagnostics, low-friction permission UX, and isolation gaps. Non-goals: a plugin marketplace, remote package installation,
Node/npm module loading at runtime, arbitrary native object access, compatibility for deleted
finite helpers/command registries/sidebar, or claiming hostile-code safety before OS isolation.

## 5. User experience

Bundled plugins are discovered from the sealed host-controlled inventory. User-authored plugins are
discovered from a separate writable inventory and appear disabled until explicitly enabled. A
directory uses `manifest.json` plus `main.js`; a top-level `.js` plugin carries the same manifest in
its leading `tenon-manifest` block. Plain scripts are ignored. A claimed but malformed plugin gets a
diagnostic without stopping valid siblings.

During reload, the host validates the complete candidate set and stages the candidate runtime and
providers. Only a fully admitted generation replaces the current one. A syntax error, missing
handler, conflict, or activation failure leaves the last good generation and its contributions
active. Disable/uninstall removes authority and contributions, cancels pending work/resources, and
persists the final state. Re-enable retains an installation; uninstall then reinstall creates a new
one.

Plugin failures and resource-limit refusals are visible through the existing Settings/extensions
and diagnostic surfaces. Logs remain ordered and include a dropped-line summary when a plugin
outproduces the bounded queue. There is no runtime UI that describes in-process JavaScriptCore as a
sandbox. Permission presentation is installation-scoped: trusted bundled/development inventories do
not prompt per operation; a local plugin is normally reviewed when enabled and again only when its
declared authority materially expands. Per-operation confirmation is reserved for actions whose
actual sensitivity, irreversibility, or external effect justifies interruption. Host-native
presentation follows [`designs.md`](../designs.md), including keyboard,
VoiceOver, focus, semantic color, and non-color-only status.

## 6. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `PRT-FR-001` | The host **MUST** discover plugins from two ordered inventories: sealed bundled first and writable user inventory second; trust **MUST** follow the exact owning root. | shipped | `@req-prt-fr-001` |
| `PRT-FR-002` | Discovery **MUST** sort entries deterministically, tolerate an absent root, include immediate manifest directories and claimed top-level JavaScript plugins, and ignore unclaimed plain scripts. | shipped | `@req-prt-fr-002` |
| `PRT-FR-003` | Directory and single-file packages **MUST** use the same `PluginManifest` decoder, identity, policy, activation, hot-reload, and retirement paths. | shipped | `@req-prt-fr-003` |
| `PRT-FR-004` | A manifest **MUST** declare a stable plugin ID, bounded name/version, an `intents` envelope, unique permissions/settings/uses/provisions, owner-valid provisions, and valid optional palette/event/automation blocks before evaluation; unknown permissions **MUST** grant nothing and surface a warning. | shipped | `@req-prt-fr-004` |
| `PRT-FR-005` | Reserved namespaces, duplicate IDs/directory identities, overlapping late namespaces, unknown provisions, and catalog conflicts **MUST** reject the losing plugin without displacing earlier valid plugins; a conflict inside the primary inventory **MUST** fail that primary batch. | shipped | `@req-prt-fr-005` |
| `PRT-FR-006` | A newly discovered plugin in the explicit-enablement inventory **MUST** start disabled and receive no standing consent until the person enables it. | shipped | `@req-prt-fr-006` |
| `PRT-FR-007` | Only host-configured bundled provenance **MAY** auto-enable and seed eligible standing consent; a manifest **MUST NOT** claim or promote its own trust class. | shipped | `@req-prt-fr-007` |
| `PRT-FR-008` | Trust-class change, legacy unknown provenance, uninstall/reinstall, or ID reuse across provenance **MUST** rotate installation identity; settings, storage, secrets, and consent **MUST NOT** cross that rotation, and downgrade **MUST** disable. | shipped | `@req-prt-fr-008` |
| `PRT-FR-009` | Installation enablement and monotonically increasing session revision **MUST** persist through an atomic, locked, deterministic, bounded document; a failed commit **MUST NOT** publish in-memory state. | shipped | `@req-prt-fr-009` |
| `PRT-FR-010` | Each runtime **MUST** own one pinned-thread JavaScriptCore context whose global scope matches the tested allowlist; `console` and the public native bridge **MUST** be absent, while immutable internal lifecycle hooks remain host-owned. | shipped | `@req-prt-fr-010` |
| `PRT-FR-011` | The top-level public namespace **MUST** be exactly `apiVersion`, `agents`, `intents`, `settings`, `storage`, `log`, `path`, `events`, `timers`, `process`, `fs`, `statusBar`, `views`, and `palette`, with method inventory fixed by the boundary law. | shipped | `@req-prt-fr-011` |
| `PRT-FR-012` | `tenon.apiVersion` **MUST** be immutable reserved runtime metadata and **MUST NOT** grant behavior or authority. | shipped | `@req-prt-fr-012` |
| `PRT-FR-013` | The exact scoped-facility allowlist **MUST** remain settings, storage, and log; settings **MUST** expose only declared keys, storage **MUST** be installation-private non-secret JSON, and logs **MUST** be generation-attributed. | shipped | `@req-prt-fr-013` |
| `PRT-FR-014` | Accepted storage writes **MUST** commit FIFO, update the local cache only after persistence succeeds, preserve the last committed value on failure, and drain during orderly shutdown. | shipped | `@req-prt-fr-014` |
| `PRT-FR-015` | `tenon.path` **MUST** perform pure string transformation with no native post, I/O, host-state read, or permission; filesystem facts/effects **MUST** use canonical intents/resources. | shipped | `@req-prt-fr-015` |
| `PRT-FR-016` | `tenon.intents.send` **MUST** accept only manifest-declared uses, copy bounded input, authorize target/scope/provider, and settle one Promise with one canonical `IntentResult`; runtime retirement **MUST** settle or cancel every outstanding send. | shipped | `@req-prt-fr-016` |
| `PRT-FR-017` | `tenon.intents.handle` **MUST** bind exactly once during staging to a manifest-declared plugin-owned provision and **MUST** be ready before the generation becomes active. | shipped | `@req-prt-fr-017` |
| `PRT-FR-018` | A provider's nested `call.send` **MUST** preserve parent request, causal scope, deadline, progress, and cancellation; explicit retargeting **MUST** be re-authorized under the provider principal. | shipped | `@req-prt-fr-018` |
| `PRT-FR-019` | Intent list/describe discovery **MUST** return only the contracts visible to that installation principal and **MUST** remain reserved catalog control plane rather than self-sent intents. | shipped | `@req-prt-fr-019` |
| `PRT-FR-020` | Policy **MUST** separately evaluate active generation, exact audience, declared use, capability, canonical path/URL pointers, invocation pane/workspace scope, network allowlist/redirect, consent, target eligibility, and provider readiness. | shipped | `@req-prt-fr-020` |
| `PRT-FR-021` | For `.policy` consent, concurrent first calls for one installation/contract/fingerprint **MUST** share one prompt; approval **MUST** persist only after durable storage and survive hot reload for the same installation. | shipped | `@req-prt-fr-021` |
| `PRT-FR-022` | `.always` contracts **MUST** prompt on every invocation; `.never` contracts **MUST NOT** create consent records; user-inventory plugins **MUST NOT** receive bundled standing consent. | shipped | `@req-prt-fr-022` |
| `PRT-FR-023` | Disable, uninstall, trust withdrawal, or queued lifecycle supersession **MUST** revoke applicable consent and authority before later calls can enter; consent-persistence failure **MUST** fail closed. | shipped | `@req-prt-fr-023` |
| `PRT-FR-024` | Host event subscription **MUST** be manifest/policy gated, deliver immutable facts without a reply channel, unsubscribe explicitly, and disappear on generation retirement. | shipped | `@req-prt-fr-024` |
| `PRT-FR-025` | Plugin event publication **MUST** require a declared owner-local channel, prefix it with stable plugin ID, and deliver only to manifests declaring the fully qualified observed channel. | shipped | `@req-prt-fr-025` |
| `PRT-FR-026` | Event emit **MUST** be fire-and-forget and bounded, preserve accepted order per generation, reveal no delivery count/listener identity, and keep a slow observer from blocking publisher or peers. | shipped | `@req-prt-fr-026` |
| `PRT-FR-027` | Timers **MUST** be bounded generation-owned resources, enforce the repeating interval floor, support explicit cancel, and stop on failure/reload/disable/uninstall/shutdown. | shipped | `@req-prt-fr-027` |
| `PRT-FR-028` | `tenon.process.stream` **MUST** require `process.exec`, bound concurrent streams/output/callbacks, report stdout/stderr/overflow/one exit, and cancel its current process leader on resource or generation teardown. | partial | `@req-prt-fr-028` |
| `PRT-FR-029` | `tenon.fs.watch` **MUST** require `filesystem.read`, bound watcher count and pending paths, report explicit overflow/failure, ignore late callbacks, and cancel on handle or generation teardown. | shipped | `@req-prt-fr-029` |
| `PRT-FR-030` | Status, views, and palette **MUST** remain bounded declarative contributions plus owner-scoped callback facts; publication alone **MUST NOT** mutate host domain state or grant authority. | shipped | `@req-prt-fr-030` |
| `PRT-FR-031` | Dynamic palette providers **MUST** be bounded, query by monotonically revisioned owner events, drop stale result revisions, and make each selectable result designate a declared plugin-owned intent. | shipped | `@req-prt-fr-031` |
| `PRT-FR-032` | `tenon.agents.run` **MUST** remain pure JavaScript composition over its four declared terminal intents, accept only top-level intents or a provider call as sender, inherit sender deadline/cancellation, and grant no extra authority. | shipped | `@req-prt-fr-032` |
| `PRT-FR-033` | Load and reload **MUST** validate manifests/contracts and stage runtime/provider bindings before publishing a candidate generation or its contributions. | shipped | `@req-prt-fr-033` |
| `PRT-FR-034` | A failed replacement **MUST** preserve the last good active generation, contributions, providers, resources, and installation identity; stale callbacks from a replaced candidate **MUST** be refused. | shipped | `@req-prt-fr-034` |
| `PRT-FR-035` | Reload, disable, re-enable, uninstall, and shutdown for the same host **MUST** serialize so a later lifecycle request determines final state even when earlier work completes out of order. | shipped | `@req-prt-fr-035` |
| `PRT-FR-036` | Retirement **MUST** close admission and cancel/drain provider calls, nested intents, subscriptions, timers, watches, process streams, callbacks, state publication, and accepted persistence/log work exactly once. | shipped | `@req-prt-fr-036` |
| `PRT-FR-037` | Runtime shutdown **MUST** use one end-to-end deadline, report the stalled phase, let concurrent callers join one operation, and return control even when plugin JavaScript never yields. | shipped | `@req-prt-fr-037` |
| `PRT-FR-038` | Host activation/reload **MUST** reconcile restored plugin-pane instances from the complete workspace catalog and keep hidden instances alive until their catalog pane is removed. | shipped | `@req-prt-fr-038` |
| `PRT-FR-039` | Plugin logging **MUST** preserve accepted line order, use a finite queue outside runtime re-entry, count dropped lines, emit a drop summary, and drain accepted final lines on shutdown. | shipped | `@req-prt-fr-039` |
| `PRT-FR-040` | Manifest, conflict, staging, runtime, resource-limit, and retirement failures **MUST** identify the losing plugin and actionable reason without erasing unrelated failures or healthy plugins. | shipped | `@req-prt-fr-040` |
| `PRT-FR-041` | User-authored plugin execution **MUST** move behind a hard OS process/sandbox boundary before Tenon describes it as sandboxed or safe for hostile code. | planned | `@req-prt-fr-041` |
| `PRT-FR-042` | Streaming process launch **MUST** own a POSIX process group (or equivalently race-free descendant set) so cancel/overflow/retirement terminates the leader and descendants before process-tree containment is claimed. | planned | `@req-prt-fr-042` |
| `PRT-FR-043` | Finite filesystem/process/workspace/terminal/browser/UI/secrets/network/clipboard/OS operations **MUST** use canonical intents; removed handwritten helpers, runtime commands, and sidebar contribution **MUST NOT** be compatibility contracts. | shipped | `@req-prt-fr-043` |
| `PRT-FR-044` | Plugins **MUST NOT** receive native `Process`, `FileHandle`, filesystem watcher, AppKit, pasteboard, Ghostty, WebKit, application-model, or provider-service objects. | shipped | `@req-prt-fr-044` |
| `PRT-FR-045` | Permission UX **MUST** be installation-scoped and low friction: trusted bundled/development provenance auto-grants declared capability policy; explicitly enabled local code is reviewed once at enablement or material manifest expansion; unchanged ordinary operations **MUST NOT** repeatedly prompt, while truly sensitive/irreversible actions **MAY** retain per-operation confirmation. | planned/partial | `@req-prt-fr-045` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `PRT-NFR-001` | architecture | Every public surface **MUST** satisfy the ordered interaction-boundary law and have one semantic implementation; new inventory requires normative/source inventories, fitness tests, and superseded-path deletion together. | shipped/continuous | `@req-prt-nfr-001` |
| `PRT-NFR-002` | security | Runtime documentation and UI **MUST** distinguish trusted provenance, explicit local enablement, in-process execution, and hard sandboxing; authority **MUST** derive only from host policy. | partial until FR-041 | `@req-prt-nfr-002` |
| `PRT-NFR-003` | boundedness | Every bridge value, queue, collection, depth, resource, callback, persistence document, and drain **MUST** have a central finite bound with explicit refuse/drop/fail behavior. | shipped | `@req-prt-nfr-003` |
| `PRT-NFR-004` | concurrency | JavaScript values **MUST** stay on the pinned executor; native callbacks **MUST** copy Sendable values into finite mailboxes and never re-enter the actor/log sink synchronously. | shipped | `@req-prt-nfr-004` |
| `PRT-NFR-005` | lifecycle | Runtime, installation, generation, resource, callback, contribution, and consent ownership **MUST** have an explicit terminal transition and idempotent teardown. | shipped | `@req-prt-nfr-005` |
| `PRT-NFR-006` | reliability | One malformed late plugin, failed persistence write, failed candidate, stalled script, or overflowing resource **MUST NOT** corrupt healthy plugin state or leave the host operation unbounded. | shipped except hard isolation | `@req-prt-nfr-006` |
| `PRT-NFR-007` | performance | Discovery, manifest preparation, filesystem work, log delivery, and resource callbacks **MUST NOT** block `MainActor`; dynamic provider work **MUST NOT** block or reorder the static ranked palette. | shipped | `@req-prt-nfr-007` |
| `PRT-NFR-008` | privacy | Secrets **MUST** remain in Keychain under installation isolation and **MUST NOT** enter plugin JSON storage, logs, telemetry, manifests, or broad discovery. | shipped | `@req-prt-nfr-008` |
| `PRT-NFR-009` | compatibility | Additive manifest evolution **MUST** define explicit defaults/migration; single-file and directory forms remain equivalent; API v0.2 finite helpers/commands/sidebar remain intentionally removed. | shipped | `@req-prt-nfr-009` |
| `PRT-NFR-010` | observability | Failures, policy refusals, overflows, dropped-log summaries, and stalled shutdown phase **MUST** be attributable without exposing secrets or listener identity. | shipped | `@req-prt-nfr-010` |
| `PRT-NFR-011` | determinism | Ordered inventory, discovery, manifest/catalog preparation, policy fingerprint, persistence encoding, and lifecycle serialization **MUST** produce the same winner/state for the same inputs. | shipped | `@req-prt-nfr-011` |
| `PRT-NFR-012` | verification | Closed-surface, shipped-plugin, policy, inventory, persistence, concurrency, teardown, backpressure, hot-reload, and Swift 6 warnings-as-errors tests **MUST** pass before public runtime change ships. | shipped process | `@req-prt-nfr-012` |
| `PRT-NFR-013` | developer velocity | Manifest declaration, policy compilation, diagnostics, and hot reload **MUST** make the common trusted write–reload–test loop non-interactive; adding architecture ceremony **MUST** be justified by a concrete risk or cross-owner compatibility need. | planned/continuous | `@req-prt-nfr-013` |

## 7. Acceptance and architecture

[`plugin-runtime.feature`](plugin-runtime.feature) maps all 58 requirements. Evidence is split
between pure manifest/policy/persistence tests, hosted runtime and JavaScript boundary tests,
concurrency/backpressure tests, lifecycle integration tests, shipped-plugin fitness tests, and two
pending containment scenarios.

| Interaction | Classification | Constraint |
|---|---|---|
| runtime/register/list/handle lifecycle | CONTROL PLANE | exact reserved protocol operations only |
| settings/storage/log | SCOPED FACILITY | exact plugin-private allowlist, never secrets |
| path composition | DIRECT | pure JavaScript and no bridge/I/O |
| finite cross-owner work | INTENT | manifest declaration plus policy/provider resolution |
| immutable published fact | EVENT | no reply and bounded delivery |
| timer/process stream/watch | RESOURCE | caller/generation-owned lifetime after initial creation |
| views/status/palette state | CONTRIBUTION | host validates and renders/indexes values |
| host internals to domain services | DIRECT | same semantic owner, typed calls |

No host-native UI is introduced here beyond existing plugin/settings diagnostics; any change to it
uses Tenon's design system. Source ownership begins in `plugin-host`, `plugin-settings`, and
`plugin-events`, then follows touched symbols with literal edge searches as required by
[`domains.md`](../domains.md).

## 8. Delivery matrix, rollout, risks, and decisions

| Requirements | Source/evidence | State/gap |
|---|---|---|
| 001…009 | loader, inventory, installation/value stores; inventory/single-file/persistence tests | shipped |
| 010…015 | bootstrap/runtime built-ins; built-ins/platform/storage tests | shipped |
| 016…023 | intent manifest, dispatcher/policy, caller/bundled consent tests | shipped |
| 024…032 | event routing/backpressure, resource, palette, agents-run tests | shipped; FR-028 cannot yet claim descendant containment |
| 033…040 | host activation/retirement/reconcile/log queue and lifecycle tests | shipped; T-080 stale boxes superseded by current source/tests |
| 041 | no current process sandbox for user-authored JavaScript | planned; architecture/threat-model work required |
| 042 | Foundation `Process.terminate()` stops the leader | planned; owned POSIX process-group launch/kill required |
| 043…044 and NFR-001…012 | boundary law, capability providers, exact-inventory and shipped-plugin fitness | shipped/continuous; security wording remains partial with FR-041 |
| 045/NFR-013 | current bundled standing consent and installation fingerprints are the base; consolidated local enable/authority review remains product-policy work | planned/partial; optimize developer velocity without bypassing declared boundaries |

Rollout for FR-041 must define process host protocol, capability token, parent-death behavior,
Seatbelt or equivalent profile, crash/restart policy, migration of contributions/resources, and a
compatibility mode that never silently promotes untrusted code. FR-042 should land with the process
launcher and descendant-kill tests before documentation changes its current limitation.

Principal risks are ambient authority from in-process execution, identity/state inheritance,
stale-generation callbacks, lifecycle deadlock, process descendants surviving cancellation,
backpressure hiding data loss, and API growth bypassing the boundary law. Host-owned provenance,
installation rotation, generation tokens, finite mailboxes/deadlines, explicit overflow, pending
containment work, and exact inventory tests mitigate them.

Decisions: inventories—not manifests—own trust; explicit user enablement is not a sandbox claim;
installation identity owns persisted authority; static declarations precede evaluation; finite
operations are intents; resource callbacks exist only for multi-result lifetimes; staging preserves
last-good state; old helpers/commands/sidebar are removed, not deprecated API; T-080 is shipped by
source/test evidence; hard isolation and descendant containment remain pending; permissions are a
low-friction installation policy, not repeated ceremony, and extra interruption requires concrete
risk proportional to the action.

## 9. Verification receipts and change history

| Date | Worktree | Result | Exclusions |
|---|---|---|---|
| 2026-08-09 | current dirty tree, documentation audit | runtime inventory, source bounds, trust/identity, consent, lifecycle, resource and log tests mapped | no new runtime test execution in this documentation-only pass; FR-041/042 intentionally pending |

Initial canonical PRD created 2026-08-09. It supersedes historical task shapes where they conflict
with the accepted interaction boundary or current source, without deleting the evidence artifacts.
