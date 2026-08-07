# The intent bus — one invocation plane with explicit contracts

**Status:** accepted and implemented; hard runtime isolation remains open · **Reviewed:** 2026-08-06
**Scope:** interactions already classified as **INTENT** by
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Historical audit — superseded channels (non-normative)

The first audit found six request shapes for one part of the system to ask another to do
something. The symbols in this section are retained only as evidence of the fragmentation
that motivated the intent kernel. They are not current or proposed APIs:

| channel | shape | who can call | who can serve |
| --- | --- | --- | --- |
| `tenon.*` members | 65 callable JS members across 20 public surfaces | plugins | host only |
| `WorkspaceCommand` | 11-case Swift enum | host only | shell only |
| `WebCommand` | 5-case Swift enum | host only | shell only |
| `HostCommand` | 4-case Swift enum | host only | shell only |
| `CLIAction` | 9-case Swift enum over a socket | external processes | shell only |
| `PluginCommand` | palette entries | user | plugins only |

The cost of that fragmentation was measurable. Adding the former terminal-run helper —
**one** verb — required edits in three files at three layers: a new member in
`PluginRuntime.installAPI`, a new case in `WorkspaceCommand`, and a new case in the shell's
`switch`. Nothing about that verb was knowable by the core in advance, yet the core had to
name it.

Three consequences, each a direct contradiction of a VISION principle:

1. **The host must know every verb in advance.** "Replaceable everything" is false while
   `WorkspaceCommand.runInTerminal` lives in the core: if the terminal ever becomes a
   plugin, the core still hardcodes what it means to run a command.
2. **Plugins cannot talk to each other.** `git` cannot ask `file-explorer` to reveal a
   path; it can only ask the host. Every plugin↔plugin interaction has to be laundered
   through a core verb somebody has to write first.
3. **Shared execution was not a shared contract.** `CLIAction.runCommand` converged CLI and
   palette execution through `PluginHost.invoke`, but discovery, schema, authorization,
   lifecycle, and errors remained on separate surfaces. The shipped kernel supersedes both
   paths with canonical intent contracts.

## Goal

Provide **one canonical invocation contract for every interaction that the normative
boundary law classifies as INTENT**. The caller normally does not know who serves it, and
the dispatch kernel does not hardcode the verb.

This bus is a public-boundary mechanism, not Tenon's internal function-call convention.
Same-owner app code uses typed DIRECT services, and code inside one plugin generation uses
ordinary JavaScript functions. Scoped plugin-private facilities, events,
resources/streams/tasks, and contributions retain their own contracts. The complete,
ordered classification law lives in
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md); this
document MUST NOT broaden that law with a shortcut such as “finite means intent.”

The callers we must serve are already four: a plugin, the user (palette / registered product
keybinding), an external process (`tenon-cli`), and — the one that matters most for this
product — **an AI agent running in a pane**. They should enter the same invocation kernel
and receive the same contract, policy, lifecycle, and error semantics. Their discovery views
may differ because
reachability, presentation, and authority are different concerns.

---

## Research: what the systems that solved this actually did

### Android Intents — the reference implementation

An `Intent` is a passive data object describing an operation: `action` (verb),
`data` (URI + MIME type), `category`, `extras`, and optionally an explicit `ComponentName`.
Two modes:

- **explicit** — names the component. Used inside one app, or where trust matters.
- **implicit** — names only the action; the system resolves who serves it.

Resolution is a three-part test against every declared `<intent-filter>`: the **action**
must match one of the filter's actions; **every** category in the intent must appear in the
filter (extra categories in the filter are fine); the **data** URI/MIME must match. Zero
matches throws `ActivityNotFoundException`; multiple matches shows a **chooser**, and the
user can set a default.

Two details worth stealing outright:

- **`CATEGORY_DEFAULT`**: an activity does not receive implicit intents unless it opts in
  explicitly. Being callable is a separate decision from existing.
- **`android:exported` is mandatory** (Android 12+ refuses to install otherwise). The
  platform learned that "exported by accident" is the root of a vulnerability class.

And the failure modes are documented in Android's own security guide, which is the more
valuable half of the research:

- **Implicit intent hijacking** — a malicious app registers a filter for someone else's
  action and intercepts the payload. Google's mitigation: don't use implicit intents where
  the receiver matters; never for `Service` (since API 21 `bindService()` with an implicit
  intent throws).
- **Intent redirection / confused deputy** — app A unparcels a nested intent from extras
  and launches it with A's authority. Mitigation: sanitize, allowlist, never forward
  blindly.
- **`PendingIntent` mutability** — a mutable `PendingIntent` wrapping an implicit intent
  lets the holder rewrite it and act as the grantor. Android 12+ forces an explicit
  `FLAG_IMMUTABLE`/`FLAG_MUTABLE` choice; the guidance is immutable by default.
- **Android 13+ filter-match enforcement**: an intent must actually match a declared
  filter, closing "undeclared but reachable" components.

### Web Intents — the post-mortem worth more than the spec

Chrome shipped Web Intents experimentally and later removed it. Paul Kinlan's own
post-mortem explains why:

1. Every action got the same generic picker — no affordance per verb.
2. No stacking context: kill the caller and the returned data had nowhere to go.
3. **No way to declare whether an intent returns a value**, so the UI could not
   distinguish one-way from two-way.
4. Uncontrolled schema proliferation — "standardizing these is incredibly hard."
5. **No defaults**: the user chose a handler on every single invocation.
6. No fallback when nothing handled the intent.
7. Registration was spoofable.

His conclusion: *start narrow with one use case, establish affordances and return semantics
before generalizing.*

### D-Bus — the mature bus, with written API guidelines

Well-known names (`org.freedesktop.NetworkManager`), object paths, interfaces, and a hard
split between **methods** (request→reply), **signals** (broadcast), and **properties**
(state + a single `PropertiesChanged`). Introspection is a protocol method returning the
full interface XML — discovery is part of the bus, not documentation.

Its design guidelines are unusually blunt and every rule maps onto our problem:

- **Version in the name from day one**; bump the name on a breaking change.
- **Always reply to a method call.** The named anti-pattern: "start a long-running
  operation, never reply, notify completion via a signal."
- **Errors are error replies, not error codes in the return value** — "a reply always
  indicates success."
- **Minimize round trips**; batch instead of per-item calls.
- **Enumerated strings over booleans** — booleans cannot grow a third value.
- **Don't put human-readable strings on the bus** — the two ends may be in different
  locales.
- `a{sv}` (string→variant dict) for payloads that must stay extensible.

### MCP — the same problem, solved for AI callers

JSON-RPC 2.0 with three server primitives: **tools** (actions the model invokes),
**resources** (addressable context), and **prompts** (reusable templates). In the stable
2025-11-25 revision, tools require JSON Schema `inputSchema` and may also declare a
separate `outputSchema`; requests can carry progress tokens and cancellation is correlated
by request ID.
Client and server perform capability/version negotiation at initialization. Tasks exist in
that revision but remain experimental, which is a reason to keep persistent-task semantics
outside the v1 intent core.

MCP is the closest existing thing to what Tenon needs, because its caller *is* a language
model: discovery, schemas, and stable names are the whole product.

### Apple App Intents — typed, statically discoverable actions

An `AppIntent` is a type with a `title`, typed `@Parameter`s, and a `perform()`. The
compiler generates discovery information from these declarations so Spotlight, Siri,
Shortcuts, widgets, and other system experiences can offer the app's actions.
`AppEntity`/`AppEnum` give parameters a domain type so the resolver can ask the user to
fill a missing one.

The lesson: **static declaration buys discovery**. A verb that can only be found by running
the plugin cannot appear in a palette, a CLI `--help`, or an agent's tool list.

### VS Code — commands as the universal verb

`vscode.commands.registerCommand` / `executeCommand` is one channel used by the palette,
keybindings, menus, other extensions, and the extension API itself. `package.json`
`contributes.commands` declares them statically; `onCommand:<id>` activation means a command
id is also the lazy-loading trigger. Built-in commands are callable by extensions exactly
like extension commands are — no private door.

The lesson: one registry can serve UI, scripting, and inter-extension calls at once. Its
weakness is equally instructive — arguments are untyped `any[]`, so there is no schema, no
validation, and no discovery beyond prose docs.

### Fuchsia / object-capability security — how to keep a bus from becoming a hole

Components declare capabilities in a manifest and the framework **routes** them; a component
can only use what was explicitly offered to it. The rule is *no designation without
authority* and *no ambient authority*: you cannot exercise a permission you were never
handed, which is what makes the confused-deputy attack structurally impossible rather than
merely discouraged.

This is the security model Tenon's canonical policy path preserves: manifest designation,
host-minted principal identity, separate authority checks, and no ambient transfer of
caller grants.

---

## Design review

### What is already strong

| strength | why it survives |
| --- | --- |
| One registry for plugin, palette, CLI, and agent callers | Removes duplicated catalogs and drift while preserving surface-specific adapters and one source of discovery. |
| Static declaration before plugin activation | Palette, CLI help, policy, and MCP discovery work without executing plugin code. |
| Input **and** output contracts | Bad calls fail before the handler; bad providers fail before corrupting callers. |
| Explicit and implicit addressing | Normal calls stay decoupled; security-sensitive calls can pin an exact provider. |
| Always-reply request semantics | Every request reaches one terminal state; progress never substitutes for completion. |
| Capability-gated host boundary | The bus cannot become a side door around the existing permission invariant. |
| Narrow first implementation | One real vertical slice can falsify the design before the API surface hardens. |

### What the first pass left unsafe or contradictory

| severity | gap | mechanism that closes it |
| --- | --- | --- |
| P0 | `broadcast` intents had no reply while `send` promised one reply | Intents are unicast request/reply only; broadcasts remain events. |
| P0 | Chooser/no-chooser and two explicit-target syntaxes conflicted | Deterministic kernel resolution; a structured `target` option; chooser is an optional UI adapter. |
| P0 | Names were “versioned” but `.v1` was absent | Every public name carries `.v1` from its first release. |
| P0 | A manifest declaration could claim another plugin's namespace | Stable host-validated `PluginID`; one contract owner; duplicate identity/namespace is a load error. |
| P0 | Caller identity and authority were implicit | Host-minted principals; declaration, grant, payload scope, provider eligibility, and audience checks are separate gates. |
| P0 | Timeout/cancel had no started/not-started semantics | Request state machine plus `notStarted` or `unknown` outcome. No automatic retry after start. |
| P0 | Reload destroyed the good runtime before proving the replacement | Staging generation, atomic swap, generation leases, bounded drain. |
| P0 | Current JS handlers execute inline on the app's practical main-thread path | Per-plugin serial executor; no cross-plugin inline call; UI effects hop explicitly to `MainActor`. |
| P1 | Compact schema was expanded only at the MCP edge | Canonical JSON Schema 2020-12 at load time; all generated surfaces derive from it. |
| P1 | No bounded queues, fairness, or cycle rule | Closed execution-lane set per provider generation; one bounded serial mailbox per lane; global and per-principal admission across lanes; asynchronous dispatch; wait-cycle rejection. |
| P1 | “Same registry” implied “same exposure” | Each caller gets a policy-filtered projection of one registry. |
| P1 | Large/streaming values were forced into request/reply | Resource/stream handles carry large or continuous data. |

The first-pass direction was sound, but these are not polish. They define whether the bus
is deterministic, secure, cancellable, reload-safe, and capable of protecting the UI from
a bad plugin.

---

## Boundary selection: delegated to the interaction law

Tenon first removes exact protocol/registry/provider/request/resource lifecycle operations
into the closed reserved control plane; a product verb cannot use that exception. Product
interactions then use six mechanisms in this normative order:

1. declarative state/registration → **CONTRIBUTION**;
2. a fact that already happened → **EVENT**;
3. multi-result/large pull body, or caller-owned lifetime continuing after the initial
   reply → **RESOURCE / STREAM / TASK**;
4. same semantic owner outside public adapters → typed **DIRECT** call;
5. exact allowlist (`settings`, plugin-private `storage`, `log`) → **SCOPED FACILITY**;
6. finite unicast request/reply across a semantic-owner or public-adapter boundary →
   **INTENT**.

The exact semantic-owner definition, closed facility allowlist, current inventories,
audiences, control-plane reservations, change protocol, and falsification criteria are in
[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md).

This document begins only after step 6. `process.stream` and `fs.watch` are resources.
`views.set` is a contribution. Internal SwiftUI/workspace/surface calls are DIRECT. A
plugin, CLI, or agent asking for a finite workspace mutation uses an intent whose provider
adapts to the same typed workspace service.

A finite asynchronous wait or collected process remains an INTENT when it settles exactly
once; elapsed time is not result cardinality. A handle that survives the initial reply and
delivers later values belongs to a RESOURCE protocol.

---

## Recommended architecture

### Five kernel concerns, no God object

```text
palette / registered product keybinding ─┐
plugin runtime ─────────────────────────┤
CLI socket ─────────────────────────────┤
MCP projection ─────────────────────────┘
                                       │
                                       v
adapter ─> IntentDispatcher ─> provider-generation lease
              │      │               └─ execution-lane mailbox
              │      │                  └─ binding executor
              │      └─ PolicyEngine
              ├─ ContractCatalog
              ├─ ProviderRegistry
              └─ IntentTelemetry
```

1. **`ContractCatalog`** owns names, versions, schemas, error vocabulary, effects,
   audiences, deprecation, and contract ownership.
2. **`ProviderRegistry`** owns eligible providers, readiness, user defaults, generations,
   and leases. It exposes a declarative view (including why a declared provider is
   unavailable) and an immutable active-routing snapshot. It does not authorize callers.
3. **`PolicyEngine`** owns principals, declared uses, capability grants/scopes, consent,
   and audience exposure. It does not select a handler.
4. **`IntentDispatcher`** validates, authorizes, resolves, admits, schedules, cancels, and
   settles exactly once.
5. **`IntentTelemetry`** records structured audit/trace/metrics without making dispatch
   correctness depend on logging.

The plugin runtime is an adapter behind `IntentProvider`; the kernel contains no
`JSContext` or `JSValue`. Replacing JavaScriptCore with QuickJS, XPC, or a helper process
does not change an intent contract.

### Public JavaScript shape

All INTENT operations are async on every public adapter. There is no callback form for
finite request/reply. Scoped facilities and pure path helpers may be synchronous; resources
and contribution/event callbacks keep their own lifetime semantics.

```js
const result = await tenon.intents.send(
  "terminal.run.v1",
  { command: "claude --resume abc" },
  {
    timeoutMs: 30_000,
    scope: { paneID: "2A50…" }
  }
);

if (!result.ok) {
  tenon.log(result.error.code);
}

// Explicit provider selection is an option, not a second string grammar.
await tenon.intents.send(
  "file.open.v1",
  { path: "/repo/README.md" },
  { target: { providerID: "dev.tenon.editor" } }
);

// Static manifest declares the contract. Runtime code only binds its implementation.
tenon.intents.handle("dev.tenon.git.stage.v1", async (input, call) => {
  call.throwIfCancelled();
  call.progress({ completed: 0, total: input.paths.length });
  return { staged: input.paths };
});

const available = await tenon.intents.list();
```

`handle()` may bind only a name the manifest declared and only while its runtime is
staging. A late or duplicate bind is a load error. The catalog is usable before the
plugin runs; a handler makes one declared provider ready. Any function that sends takes
the sender as its last parameter, defaulting to `tenon.intents`; a handler passes its own
`call` into every function it calls that sends, so nested requests preserve parent
request, cancellation, trace, and causal scope. Top-level `tenon.intents.send` starts a
root plugin request.

### Manifest shape

```json
{
  "id": "dev.tenon.git",
  "name": "git",
  "version": "1.0.0",
  "permissions": ["process.exec", "filesystem.read"],
  "intents": {
    "uses": ["file.open.v1"],
    "provides": [
      {
        "name": "dev.tenon.git.stage.v1",
        "title": "Stage files",
        "description": "Stage workspace files in Git.",
        "audiences": ["plugin", "user", "cli", "agent"],
        "effects": {
          "kind": "write",
          "idempotency": "keyed",
          "retentionMs": 86400000,
          "confirmation": "policy",
          "external": false
        },
        "inputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "properties": {
            "paths": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 1
            }
          },
          "required": ["paths"],
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "properties": {
            "staged": {
              "type": "array",
              "items": { "type": "string" }
            }
          },
          "required": ["staged"],
          "additionalProperties": false
        },
        "errors": [
          "dev.tenon.git.path-not-found",
          "dev.tenon.git.index-locked"
        ]
      },
      {
        "name": "file.open.v1"
      }
    ]
  }
}
```

`dev.tenon.git.stage.v1` is owned by `dev.tenon.git`, so its owner supplies the contract.
`file.open.v1` is an open core contract, so the plugin only references and implements it;
it cannot redefine its schemas or risk metadata.

`uses` is a **designation allowlist and dependency declaration**, not authority. A plugin
cannot grant itself access by naming an intent. An invocation is allowed only when all are
true:

```text
declared exact use
AND caller principal holds the required capability grant
AND the payload is inside the grant's argument scope
AND the target provider is eligible and exported for this contract
AND this caller surface is allowed to discover/invoke it
AND required runtime consent succeeds
```

This separation is the balance between too loose and too rigid: the verb catalog evolves,
but identity, policy, lifecycle, and execution invariants stay fixed.

### The immutable envelope

The adapter accepts caller input; the host constructs the authoritative envelope:

```swift
struct IntentEnvelope: Sendable {
    let requestID: UUID
    let traceID: UUID
    let parentRequestID: UUID?
    let name: IntentName
    let input: IntentValue
    let caller: IntentPrincipal
    let scope: InvocationScope
    let deadline: ContinuousClock.Instant
    let target: ProviderID?
    let idempotencyKey: String?
}
```

- `IntentValue` is an owned JSON value enum, never a live `JSValue`, mutable dictionary,
  AppKit object, or runtime handle.
- `caller`, IDs, deadline, grants, and the final validated envelope are host-minted
  metadata; payload fields cannot overwrite them.
- A caller may explicitly designate `workspaceID`/`paneID` through `options.scope`.
  Designation is not authority: policy authorizes the resolved resource before constructing
  the final `InvocationScope`. `userGestureID` is host-minted only.
- A nested provider call preserves causal scope by default. It may explicitly retarget only
  within the provider/plugin principal's own grants.
- A provider invoked by another caller acts with **the provider's own authority**. Caller
  authority is never inherited or forwarded. If narrow delegation is ever needed, the host
  must mint an opaque, invocation-scoped, expiring, non-forwardable token; v1 has none.
- In-process dispatch converts JS→`IntentValue` once at the trust boundary and
  `IntentValue`→JS once at the provider boundary. It never stringifies/parses JSON between
  Swift components.

### The dispatch pipeline

The order is part of the security and performance contract:

```text
1. construct host-owned envelope and principal
2. lookup canonical descriptor
3. enforce payload size/depth/count budget
4. validate input against the compiled schema
5. check declared use + grants + argument scope + surface exposure
6. recover/validate an existing idempotency claim, or resolve and consent to one provider
7. atomically claim a new idempotency key, then acquire its generation lease and admission
8. execute asynchronously with deadline/cancellation
9. validate the provider result against the output schema
10. settle exactly once; persist keyed outcome; emit audit/trace/metrics
```

No public adapter may jump into a provider after step 1. Plugin, CLI, agent/MCP, and
palette/registered-product-keybinding invocations of plugin-owned contracts all enter this
pipeline. Same-owner built-in app code stays outside it and calls the provider's typed
application service DIRECT.

### Exactly one terminal result

```ts
type IntentResult<T> =
  | {
      ok: true;
      value: T;
      meta: { requestID: string; providerID: string };
    }
  | {
      ok: false;
      error: {
        code: string;
        details?: unknown;
        retryable: boolean;
        retryAfterMs?: number;
        outcome: "notStarted" | "unknown";
      };
      meta: { requestID: string; providerID?: string };
    };
```

`IntentResult` is the invocation envelope, not the provider's output schema. A successful
reply contains only a validated output value; a bus or domain failure occupies the failure
branch. Transport adapters may represent that branch with their native error mechanism,
but they cannot turn failure data into a valid success payload.

Error codes and typed `details` are locale-neutral. Human-facing messages/hints are
localized by the calling projection from the code and safe details; they are not stable
wire values. Validation details use bounded fields such as JSON path, failed keyword, and
expected type rather than echoing secret payload data.

Kernel errors use the closed `tenon.*` namespace:

| code | meaning |
| --- | --- |
| `tenon.unknown-intent` | No contract exists; may include nearest-name hints. |
| `tenon.undeclared-use` | Plugin caller omitted the exact name from `uses`. |
| `tenon.invalid-input` | Payload failed size or schema validation. |
| `tenon.denied` | Grant, scope, audience, or consent rejected the call. |
| `tenon.no-provider` | No eligible ready provider exists. |
| `tenon.ambiguous-provider` | More than one provider is eligible and no default/target resolves it. |
| `tenon.provider-unavailable` | Selected provider is activating, draining, failed, or disabled. |
| `tenon.overloaded` | Bounded admission rejected the call; may carry `retryAfterMs`. |
| `tenon.idempotency-conflict` | A keyed call changed input or explicit target before retention expired. |
| `tenon.cycle-detected` | Adding the awaited call would create a provider wait cycle. |
| `tenon.deadline-exceeded` | Deadline passed. Outcome says whether execution may have started. |
| `tenon.cancelled` | Caller cancelled. Outcome says whether execution may have started. |
| `tenon.provider-retired` | Drain limit forced an active generation to stop. |
| `tenon.handler-failed` | Provider threw an undeclared failure. |
| `tenon.invalid-output` | Provider returned a value outside its output schema. |
| `tenon.internal` | Kernel invariant failed; details stay in privileged diagnostics. |

Each descriptor may add declared, namespaced domain errors such as
`dev.tenon.git.index-locked`. A handler cannot invent undeclared public codes. Clients
must display unknown domain codes generically. Domain errors may carry schema-declared,
size-bounded details, so adding a domain error remains compatible without turning prose
into a programmatic contract.

Progress uses rate-limited `intent.progress` notifications correlated by `requestID`.
Its numeric `progress` value strictly increases on every notification whether or not an
optional total is known, and notifications stop at terminal settlement. Progress never
replaces the final result.

### Contract ownership, identity, and names

Every contract has exactly one owner:

| contract class | owner | provider rule | normal use |
| --- | --- | --- | --- |
| `sealed` | core catalog | Core only; typed provider adapter after all gates | Closed canonical fixed-host intents such as filesystem, terminal, workspace, and process |
| `open` | core catalog | Built-in trusted default plus user-approved alternatives | `file.open.v1`, `url.open.v1` |
| `plugin-owned` | one stable `PluginID` | Owning plugin only in v1 | Plugin-specific domain operations |

The normative boundary law owns the exact core inventory. An illustrative provider class
does not create a contract. Adding another open core contract requires the inventory,
audience, policy, fitness test, and source-owned catalog in the same reviewed change.

`PluginID` is immutable install identity, separate from mutable `name`/`displayName`. It
uses lowercase dot-separated DNS-label syntax. The manifest requests an ID; it does not
self-authenticate it. The host binds that request to an installation record before
evaluating JavaScript:

- built-in IDs are compiled into the trusted catalog;
- distributed-package IDs bind to the verified publisher/package identity;
- local-development IDs require an explicit user-approved installation record and receive
  no agent/CLI export by default.

The host rejects duplicate IDs and mismatched package bindings atomically. Core namespaces
are reserved. A plugin-owned intent begins with the full `PluginID`, so
`dev.tenon.git.stage.v1` cannot be claimed by a plugin whose verified identity is
`example.attacker`.

Intent names are 1–128 lowercase ASCII characters from `[a-z0-9.-]`; dot-separated
segments start/end with an alphanumeric character. This strict subset is valid as an MCP
tool name, so projection needs no lossy rename or collision table. All names end in a major
version from day one:

```text
terminal.run.v1
file.open.v1
url.open.v1
dev.tenon.git.stage.v1
```

There is no invisible “current version” alias. `v1` and `v2` may coexist during migration.
Display titles carry human-friendly wording; programmatic names optimize for stable,
unambiguous contracts.

### Canonical schema and evolution

**JSON Schema 2020-12 is the runtime contract**, not an MCP-only export and not a custom
shorthand. Both schemas have object roots in v1. The host compiles them when the catalog is
loaded and rejects an invalid descriptor before any provider becomes active.

Tenon supports a bounded profile rather than every possible vocabulary:

- explicit `$schema`; object/array/scalar validation, composition, and local
  `$defs`/`$ref`;
- no remote `$ref`, custom vocabulary, or validator feature the host does not implement;
- host limits for schema depth, reference depth, regex length, collection size, value
  depth, and encoded bytes;
- `default` and `format` retain their JSON Schema annotation meaning. The dispatcher does
  not coerce input, inject defaults, or turn `format` into an assertion implicitly.

The catalog stores a normalized `schemaDigest` and monotonic `catalogRevision`. Validators
are compiled and cached by digest. This makes discovery snapshots reproducible and avoids
parsing attacker-controlled schemas on the dispatch path.

Authoring does not require hand-maintaining four copies:

- Core contracts live in one typed declarative source that generates Swift values,
  JavaScript/TypeScript declarations, JSON Schema, docs, and MCP projections.
- Plugin authors use an SDK `defineIntent` declaration that emits the manifest fragment and
  `.d.ts`; raw JSON Schema remains supported for simple JavaScript plugins.
- Contract tests compare generated artifacts to the canonical normalized schema. A manual
  bridge, schema, or docs copy is a build failure.

Same-major evolution permits only changes that do not alter executable acceptance,
output shape, effects, or meaning:

| change | same major? |
| --- | --- |
| Clarify title, description, examples, or deprecation metadata | yes |
| Add a declared domain error; callers handle unknown domain codes generically | yes |
| Add any top-level input/output field to a closed object | no |
| Remove/rename a field or change its type, constraint, or meaning | no |
| Change side-effect, authority, idempotency, or confirmation semantics | no |

Core/open providers bind the canonical contract; they do not submit competing schemas.
Compatibility is checked against every retained revision of the same major, not only the
immediately previous one. Breaking changes create `.v2`.

Contracts that genuinely need open-ended output reserve an explicit, size-bounded
`extensions` object in v1. Keys inside it are full owner namespaces and consumers must
ignore unknown keys. This escape hatch is part of the original schema; it does not make
every object open or retroactively redefine `additionalProperties: false`.

Input **and output** are validated. A provider that repeatedly returns an invalid result is
marked unhealthy and removed from implicit resolution; the kernel never silently coerces
its result.

### Deterministic provider resolution

Resolution has one algorithm:

```text
1. explicit options.target.providerID -> require eligible exact provider
2. configured eligible default -> use it
3. contract's trusted default -> use it
4. exactly one eligible provider and contract policy allows auto-select -> use it
5. zero -> tenon.no-provider
6. more than one -> tenon.ambiguous-provider
```

An alternate provider never becomes default merely by declaring a filter. For an open
system intent, the built-in remains the default until the user explicitly chooses and
consents to an override. Consent is keyed by contract major, provider ID, and a policy
fingerprint; widening effects, capabilities, or payload scope invalidates the old consent.
The user can revoke it in Settings.

The kernel does not show a chooser. A palette or settings UI may handle
`tenon.ambiguous-provider`, let the user choose, persist the default, and retry as a new
request. Headless plugin/CLI/MCP callers receive the same explicit error.

### Authority, effects, and confused deputies

The ten coarse permissions remain the enforcement base while the same `PolicyEngine`
enforces contract, argument, network-host, and caller-scope rules. Intent names do not
replace permissions:

- `uses` answers **what the plugin intends to call**.
- capability grants answer **what authority the user gave it**.
- argument policy answers **where/on what data that authority applies**.
- audiences answer **which caller surfaces may see or invoke it**.
- provider consent answers **who may receive the payload and perform the action**.

These are deliberately separate. Combining them into one string would be simpler only
until the first `file.open.v1` call outside the workspace or the first provider that should
not see a terminal command.

Descriptors carry effect metadata:

```text
kind: read | write | destructive
idempotency: none | keyed
retentionMs: required for keyed, absent for none, host-bounded
confirmation: never | policy | always
external: true | false
```

`policy` confirmation presents one closed set of positive decisions: **Allow Once** for the
current coalesced request wave, **Always Allow** for the current caller/contract pair, and
**Always Allow for This User** for every `policy` contract invoked by the stable caller
identity. The caller-wide choice is a confirmation grant, not ambient authority: declared
use, audience, capabilities, argument/scope policy, provider consent, and admission still
run for every call. `always` presents only Allow Once and never reads or records standing
consent. Denial is wave-local, so a later request can ask again; unanswered prompts expire at
the caller's deadline.

For core contracts, the core catalog is authoritative. Plugin-owned metadata is untrusted:
missing fields get pessimistic defaults (`write`, `none`, `policy`, `external: true`) and
cannot lower host policy. This follows MCP's useful risk vocabulary without treating
provider-supplied hints as security facts.

Provider code receives caller identity for audit/display, not the caller's grants. A
provider that invokes another intent is a new caller under its own principal. This blocks
the classic confused-deputy path where a low-authority plugin tricks a high-authority
caller into forwarding a privileged operation.

### Request lifecycle, cancellation, and retry

```text
created
  -> validated
  -> authorized
  -> resolved(provider, generation)
  -> admitted
  -> queued
  -> started
  -> terminal
```

Every call has a host-enforced deadline. Callers may request a shorter timeout, never a
longer one than policy permits. Cancellation propagates to queued work and cooperatively to
the handler.

The key semantic distinction:

- Cancel/deadline **before `started`** returns `outcome: "notStarted"`; no handler ran.
- Cancel/deadline/crash/forced retirement **after `started`** returns
  `outcome: "unknown"` unless the provider supplies a durable completion record. The side
  effect may still have happened.

Cancellation means “the result is no longer wanted,” not rollback. A late reply cannot
settle the request twice, but telemetry records it.

The kernel performs **no automatic retry and no fallback after a provider starts**.
Retrying a terminal write, file mutation, or Git operation against another provider can
duplicate or split the effect. A caller may retry only when:

1. the descriptor declares `idempotency.mode: keyed` with a bounded `retentionMs`;
2. the caller supplies the same idempotency key; and
3. the selected provider passed keyed-idempotency conformance for that retention period.

For a keyed descriptor, `retentionMs` is explicit and capped by host policy. Before mailbox
admission, the host atomically claims `(principal, contract, idempotencyKey)` and persists:

```text
inputDigest, explicitTarget, providerID, requestID
state: claimed | running | terminal
terminal result, expiresAt
```

The first claim pins the provider ID before defaults can change. A duplicate with the same
input and target joins the in-flight request or recovers its terminal result, including
across reconnect/reload. A duplicate with different input or explicit target fails
`tenon.idempotency-conflict`; it never receives an unrelated cached result. Expired entries
are removed under a bounded count/byte policy. Tenon does not promise exactly-once
execution across loss of the durable claim store; it promises atomic deduplication while a
claim is retained, at-most-one settlement, and explicit outcome uncertainty.

Operations that must survive the caller or app interaction become tasks with opaque IDs,
retention, status, and cancellation semantics. They are not indefinitely held intent calls.

### Provider lifecycle and hot reload

```text
discovered
    -> staging(g+1)
    -> active(g+1)

active(g)
    -> draining(g)
    -> retired(g)

staging -> failed        (active g remains untouched)
active  -> disabled      (explicit user action; no replacement)
```

Staging performs manifest decode, identity/namespace checks, schema compilation, source
evaluation, and all required `handle()` bindings in an unpublished registry. Only then does
one atomic swap publish generation `g+1`.

Dispatch acquires a generation lease atomically with resolution:

- New requests after the swap go to `g+1`.
- An admitted request pins `g` until terminal settlement or the drain deadline.
- A failed candidate leaves `g` active and reports the staging error.
- A forced drain cancels queued requests as `notStarted`; started work settles
  `provider-retired` with `outcome: unknown`.
- Ordinary hot reload drains the previous generation; explicit disable, uninstall, or
  permission revocation cancels it immediately according to the same outcome rules.
- Defaults and consents reference stable provider ID, never a runtime pointer.

Provider identity, authority, health, activation, generation swap, cancellation, and
retirement remain generation-scoped. A retirement request covers every execution lane.
Generation shutdown starts only after every lane is physically idle and the generation
holds zero selections and leases.

This makes save/reload iteration safe: a syntax error in the new plugin does not remove the
working version, and no request jumps between generations halfway through execution.

### Scheduling, ordering, reentrancy, and backpressure

Each provider generation owns a closed set of execution lanes. Every exported contract maps
to exactly one lane, and every lane owns a distinct mailbox bounded by request count and
encoded bytes. Dispatch **always enqueues** into the selected lane across a provider
boundary; it never calls a plugin handler inline on the caller's stack. Lanes isolate
physical execution; routing, policy, authority, health, leases, activation, and retirement
remain properties of the provider generation.

For JavaScriptCore:

- one explicit `JSVirtualMachine` and one long-lived pinned executor/thread per plugin;
- the VM/context is created and destroyed on that same thread, whose run loop remains
  serviced for the runtime lifetime;
- every `JSContext`/`JSValue` interaction, Promise settlement, process callback, deferred
  GC/Wasm work, reload, and shutdown is marshalled onto that pinned executor;
- different plugin VMs may run concurrently;
- UI/workspace effects cross an async bridge and hop to `MainActor` only for the minimal
  AppKit/SwiftUI work.

Apple documents that threads sharing one virtual machine wait on each other. Separate VMs
plus pinned ownership satisfy JavaScriptCore's initialization-thread/run-loop constraint
and make ordering explicit instead of accidentally putting plugin execution on the UI
path. In-process JSC v1 uses one dedicated thread per plugin, so a synchronous runaway
handler cannot monopolize another plugin's executor. A future pool may host explicitly
trusted, cooperative built-ins only; untrusted plugins retain a dedicated thread or move
behind process/runtime isolation.

Ordering guarantees are:

- FIFO for one caller within one execution lane and provider generation;
- fair round-robin interleaving across principals within each lane;
- independent lanes and provider generations may progress concurrently; ordering
  guarantees end at a lane boundary;
- one active JavaScript handler per plugin runtime; each plugin generation uses one runtime
  lane.

A caller that requires ordering across lanes awaits the terminal result of the preceding
request before sending the dependent request.

If handler A awaits B and B attempts to await A, adding the second dependency would close a
wait-for cycle. The dispatcher rejects it with `tenon.cycle-detected`. A maximum causal
depth remains a secondary guard against infinite non-cyclic chains. Fire-and-forget
reactions belong in events, not detached intent calls.

Backpressure is explicit:

- request-count and byte budgets per lane;
- bounded global and per-principal in-flight work across all lanes;
- started work retains global and per-principal admission through logical cancellation until
  its lane reports physical completion; that completion releases the admission exactly once;
- reserved interactive capacity across global and lane admission;
- a closed lane inventory established during provider activation;
- queue entries expire at their request deadline;
- full admission returns `tenon.overloaded`, optionally with `retryAfterMs`;
- side-effecting intents are never dropped, coalesced, or silently overwritten.

Progress updates are rate-limited and coalesce to the latest state per request. Stream
adapters batch/chunk output and apply upstream pressure or terminate with an explicit
overflow result; they do not enqueue one unbounded main-thread task per output line. Event
topics may declare coalescing/drop policies because events have different semantics. Those
policies never leak into intents.

### Performance design

The fast path stays disciplined:

1. immutable hash-map snapshots make descriptor/provider lookup O(1) in provider count;
2. schemas compile once at catalog/staging time;
3. `IntentValue` copies once per trust boundary, with no in-process JSON text round-trip;
4. a sealed Swift provider dispatches to a typed closure after the common policy/schema
   gates;
5. filtered discovery lists cache by a composite projection revision;
6. trace/audit writes are buffered off the execution path.

Initial host policy uses a 64 KiB payload/result budget and a 1 MiB hard ceiling; a contract
may request a lower limit, while a host release may raise the ceiling only with benchmark
and memory evidence. Large file bodies, scrollback, process output, images, and diffs use
resource handles/streams rather than repeated dictionary copies.

Initial Release-build fitness targets — **targets, not measured claims**:

| path | p95 host overhead, excluding handler |
| --- | --- |
| Warm sealed Swift call, 1 KiB input/output | ≤ 0.5 ms |
| Warm JavaScript provider bridge, 1 KiB input/output | ≤ 1.5 ms |
| Queue overload burst | bounded memory; explicit rejections; no UI stall |
| Discovery from cached catalog | independent of plugin activation |

Release-performance receipts must record sealed Swift, JavaScript-provider, overload, and
cached-discovery measurements. The table remains a target until such a receipt is attached;
if a target is unrealistic, the number changes with evidence. Validation, authority, and
boundedness do not get removed to make a benchmark green.

### Observability and debugging

Each request emits one structured record:

```text
requestID, traceID, parentRequestID
intent name + version
caller principal + surface
provider ID + generation
created/queued/started/settled timestamps
queue wait, handler duration, total duration
input/output byte counts
consent decision + policy revision
terminal code + outcome
```

Payloads/results are not logged by default. The contract may nominate safe summary fields;
secret/file/terminal content remains redacted. Provider stack traces and invalid-result
details are available only in the privileged inspector, never returned across a plugin
boundary.

Metrics cover queue depth/fill rate, admission rejection, provider activation/reload,
handler failures, invalid results, deadline/cancellation, late replies, and latency by
contract/provider. Traces propagate through nested intents using host-owned IDs, matching
OpenTelemetry's requirement that producer/consumer context travel together.

The developer inspector can:

- list canonical contracts and schema versions;
- explain why an intent is hidden or denied for a principal;
- show eligible/default providers and generations;
- follow one causal trace;
- revoke provider defaults/consent;
- expose source-mapped plugin errors.

Structured diagnostics are part of AI-writability: a model can repair
`tenon.invalid-input at /paths/0: expected string` far more reliably than it can repair
`undefined` or a prose log.

### One catalog, policy-filtered projections

Public callers share contracts and execution, not an indiscriminate list:

| surface | projection |
| --- | --- |
| Plugin | Declared `uses` that policy allows, plus the plugin's own contracts |
| Palette/registered product keybinding | Plugin-owned intents with presentation metadata and satisfiable/collectable parameters |
| CLI | `intent list`, `intent describe`, `intent send`; only `ping` and single-instance activation/focus remain direct controls |
| MCP/agent | Allowed agent audience only, canonical schemas, pessimistic effect annotations, human confirmation policy |

`intents.list()` returns what the calling principal may currently discover. A privileged
inspector can see hidden/denied descriptors and the denial reason. Security-sensitive
contracts are not leaked to a plugin merely because they exist.

Callable surfaces such as MCP `tools/list` expose only active providers. Palette, Settings,
and the privileged inspector may also show declared-but-unavailable contracts with an
activation or denial reason; “known to the catalog” never implies “callable now.”

MCP is a policy-aware adapter, not the source of truth. Each session observes an immutable:

```text
ProjectionRevision =
  catalogRevision
  + providerRegistryRevision
  + policyRevision
  + principal/sessionRevision
```

Pagination cursors bind to that exact revision. A changed revision invalidates the cursor
and requires listing again. The adapter:

- negotiates protocol version/capabilities and advertises list-change support;
- paginates one immutable, principal-scoped projection revision;
- exposes the canonical Tenon name directly; the catalog's name grammar already satisfies
  MCP's 1–128-character safe-name guidance;
- projects canonical input/output schemas and validates `structuredContent`;
- maps MCP request IDs/progress tokens/cancellation onto the internal lifecycle;
- after receiving MCP cancellation, still settles/audits/releases the internal call
  exactly once but suppresses the cancelled request's wire response;
- maps malformed transport requests separately from domain/bus failures;
- applies per-session rate limits, output sanitization, audit, and human confirmation;
- emits `tools/list_changed` whenever that session's filtered tool set changes, including
  catalog swap, activation/disable/uninstall, provider health, permission/consent, or
  session-policy changes.

Provider-supplied effect hints remain untrusted; the host's policy controls exposure and
confirmation. Experimental MCP Tasks may adapt stable Tenon task handles only after
capability negotiation; they do not define the internal task model.

### Historical migration audit (non-normative)

The migration began with handwritten finite plugin APIs, three host-side command enums, a
domain-specific CLI action enum, and runtime-only command registrations. Those names are
historical evidence, not surfaces to preserve.

Every completed vertical slice now follows one rule:

1. declare the canonical versioned contract and policy;
2. adapt it to one typed application service;
3. route every authorized public adapter through the dispatcher;
4. project palette/registered-product-keybinding metadata from plugin-owned intent
   declarations;
5. remove the superseded public request path in the same change;
6. retain DIRECT internal calls, events, resources, scoped facilities, and contributions
   according to the normative interaction law.

Tenon may have multiple adapters to one typed service. It MUST NOT have multiple public
protocols for one operation.

---

## Decision record

### Trade-off matrix

| criterion | Literal universal bus | **Boundary law + contract-driven intent plane** | Per-verb public channels |
| --- | --- | --- | --- |
| Caller consistency | high | **high** | low |
| Semantic clarity | low; internals, streams, and events become disguised calls | **high; six deterministic mechanisms** | medium |
| Provider flexibility | high but unsafe by default | **high under owner/routing policy** | low |
| Compile/discovery support | medium | **high from canonical schema** | medium |
| Security | low without many exceptions | **high with principal/policy separation** | medium |
| Backpressure/lifecycle | one giant policy surface | **shared generation lifecycle, lane-local mailbox budgets, global/per-principal admission** | duplicated |
| Hot-path performance | poor predictability; everything pays | **DIRECT internals; compiled boundary path** | highest locally |
| Evolvability | namespace/schema sprawl | **owned/versioned contracts** | core edits per verb |
| Cognitive load | deceptively low, then implicit | **moderate and explicit** | high across channels |

**HIGH recommendation:** apply the boundary law first, then use the contract-driven intent
plane only for INTENT interactions. It retains one addressable public domain surface for
plugins, CLI, agents, and palette/registered-product-keybinding projections while keeping
same-owner code typed and keeping facilities, streams, facts, and contributions honest.

### Settled decisions

1. The normative interaction law selects DIRECT, SCOPED FACILITY, INTENT, EVENT,
   RESOURCE/STREAM/TASK, or CONTRIBUTION before this kernel is considered.
2. Same-owner host code uses typed DIRECT application services; intent providers adapt to
   those same services.
3. The scoped-facility allowlist is exactly settings read, plugin-private storage, and log.
4. Intents are finite unicast request/reply; there is no broadcast intent mode.
5. Names carry `.v1` from first release.
6. JSON Schema 2020-12 is canonical at load time; input and output are separate.
7. Stable `PluginID` owns plugin namespaces; duplicate identity/namespace fails closed.
8. Structured `options.target.providerID` is the only explicit addressing form.
9. Resolution is deterministic; no chooser inside the kernel.
10. `uses` designates; capability grants authorize; provider consent selects who receives
   the request.
11. Caller authority never transfers to providers.
12. No automatic retry/fallback after start.
13. Events, streams/tasks/resources, and contributions retain separate semantics.
14. Every provider invocation is asynchronous, admitted globally and by its selected
    execution lane, and executed outside the caller's inline stack. Nested calls retain
    generation-level cycle detection.
15. Reload is staged and atomically generation-swapped.
16. One canonical contract generates runtime types, SDK types, schemas, docs, and MCP.
17. Discovery is policy-filtered per principal/surface.
18. Core intent audiences are exactly the two profiles in the normative boundary law;
    built-in app UI has no generic intent principal.
19. The bus is runtime-independent; it does not import JavaScriptCore.

The runtime choice (in-process JSC, QuickJS, XPC/helper process) is intentionally outside
this ADR. The provider adapter makes it changeable without changing contracts.

---

## Fitness functions and falsification

The design is not accepted because its types compile. It is accepted when these observable
properties hold:

### Contract and security

- Every interaction inventory row matches the six-mechanism boundary law.
- A new top-level plugin-runtime surface or core intent fails until it has an exact
  classification and audience entry.
- Built-in app/UI source cannot create a generic app intent principal or route ordinary
  same-owner work through the dispatcher.
- The closed scoped-facility allowlist remains exactly settings, plugin-private storage,
  and log.
- Duplicate plugin ID or namespace is rejected before JavaScript evaluation.
- A core/open contract cannot be redefined by a provider.
- Input and output schema violations return exact JSON paths.
- Same-major breaking schema changes fail compatibility checks.
- Plugin invocation requires both exact `uses` and the required grant/scope.
- Explicit targeting cannot bypass provider eligibility, export, consent, or audience.
- Provider code cannot use caller authority.
- `intents.list()` never exposes a contract hidden from that principal.
- Concurrent calls with the same idempotency key execute once and join one result.
- Reusing a retained key with changed input/target returns
  `tenon.idempotency-conflict`; reload, reconnect, and default changes do not move it to a
  second provider.

### Resolution and lifecycle

- Zero/one/multiple-provider cases produce deterministic results.
- A broken staging generation leaves the active generation serving.
- A successful reload swaps atomically; new calls use the new generation and old leases
  drain.
- Disable/uninstall settles every queued/in-flight request exactly once.
- A late provider reply cannot settle twice.
- Stale defaults/consents invalidate when provider or policy fingerprints change.

### Concurrency and failure

- Handler invocation never occurs inline across plugin contexts.
- Per-caller FIFO holds within each lane; independent lanes demonstrate forward progress
  while another lane is suspended; principal fairness holds within every lane.
- A wait cycle is rejected before deadlock.
- Mailbox/global overload stays memory-bounded and returns `tenon.overloaded`.
- Cancelling started work settles the caller logically but retains its global/per-principal
  admission until physical completion; an independent lane is admitted after that completion.
- Cancel/deadline before start proves `notStarted`.
- Crash/cancel/deadline after start returns `unknown`; no implicit retry occurs.
- Invalid provider output cannot reach a caller.
- A slow plugin cannot block UI rendering or another plugin's executor.
- Thread-identity assertions prove every VM/context create/use/callback/destroy action stays
  on its pinned thread; Promise/process-callback stress still settles asynchronously.
- Every change to a session's filtered MCP tool set advances its projection revision,
  invalidates stale cursors, and emits `tools/list_changed`.

### Performance and product outcome

- Release benchmarks meet or revise the explicit overhead targets with preserved safety
  gates.
- Large payload tests switch to handles rather than growing repeated copies.
- One typed operation implementation is reached from built-in UI by DIRECT call and from
  every authorized public principal by its intent provider adapter, without semantic
  duplication.
- `terminal.run.v1` is invoked successfully from plugin, CLI, and agent adapters with the
  same request ID/error/audit semantics.
- After each migration slice, exhaustive search finds no remaining legacy path for that
  action.

Falsification criteria:

- If two engineers applying the ordered boundary law classify one interaction
  differently, the law is ambiguous and must be revised before implementation.
- If a supposedly finite operation needs multiple replies or an unbounded lifetime, it is
  not an intent.
- If an internal same-owner operation needs policy, ecosystem compatibility, independent
  lifecycle, or public discovery, it is not DIRECT.
- If a scoped facility needs another provider, another principal, arbitrary host
  authority, or external discovery, it is an intent.
- If policy needs to inspect provider-specific code to authorize a call, the contract is
  under-specified.
- If a safe reload requires exposing two active generations to new resolution, the lease
  model is wrong.
- If the JSC adapter cannot keep all JS work off `MainActor`, it must move behind a helper
  process/runtime that can.
- If the sealed fast path cannot meet the performance target with compiled validation, the
  implementation is wrong; removing validation is not the remedy.

---

## Stress test

| scenario | expected behavior |
| --- | --- |
| Providers and calls grow 10× | O(1) lookup, compiled validators, closed bounded lane sets, and cached projections preserve bounded work |
| Team doubles | Contract ownership and generated artifacts prevent teams from redefining or hand-copying APIs |
| Plugin reload contains a syntax error | Staging fails; last good generation remains active |
| Plugin loops forever | Dedicated executor protects UI/other plugins; request deadline expires, but hard termination needs runtime isolation |
| Agent floods a provider | Principal quota/backpressure rejects excess while interactive capacity remains |
| Provider crashes after a file write | Caller receives `outcome: unknown`; no fallback or automatic retry |
| Two concurrent keyed writes race across a default change | One atomic claim pins one provider; the calls join one result |
| Two editors implement `file.open.v1` | Trusted/user default wins; otherwise explicit ambiguity, never surprise selection |
| Provider adds a required field | Compatibility gate requires `.v2`; v1 remains callable |
| Malicious plugin declares `terminal.run.v1` | Reserved owner/provider policy rejects the claim before activation |

---

## Residual risks and honest limits

1. **HIGH — in-process JavaScriptCore is not a hard isolation boundary.** A dedicated
   executor protects responsiveness, but a CPU loop cannot be safely preempted and the
   plugin shares the host address space. Production-grade untrusted plugins require a
   runtime with interrupts/memory limits or an XPC/helper-process boundary.
2. **MEDIUM — coarse capability grants remain broad.** Contract, argument, network-host,
   caller-scope, and interactive-consent checks are implemented, but a granted capability
   is not an OS sandbox and cannot constrain arbitrary in-process JavaScript execution.
3. **MEDIUM — schema governance can become bureaucracy.** One owner, generated artifacts,
   compatibility automation, and few broad core contracts keep the cost proportional.
4. **MEDIUM — performance targets lack a durable release receipt.** Queue and payload
   bounds are implemented and mutation-tested; the p95 targets above still require a
   recorded Release-build benchmark on supported hardware.
5. **MEDIUM — plugin↔plugin calls create real ecosystem coupling.** Versions, ownership,
   deprecation metadata, and conformance tests reduce it; they cannot make public contracts
   free.
6. **LOW — chooser UX may become desirable later.** It remains an adapter over explicit
   ambiguity, so adding it does not change kernel resolution.

Resolved implementation prerequisites retained in the tests: stable installation-backed
`PluginID`, duplicate/namespace rejection, staged hot reload, atomic generation swap,
leases and bounded drain, declared caller uses/providers, policy confirmation, and closed
execution lanes.

### Readiness verdict

**HIGH:** the original proposal was suitable for research but not production
implementation because its core contracts contradicted each other and omitted identity,
lifecycle, outcome, and backpressure semantics.

**HIGH:** the intent kernel and its plugin, palette, CLI, and agent adapters are implemented.
The former handwritten finite-capability and command paths are deleted and architecture
fitness tests hold the closed inventories.

**MEDIUM:** the interaction model is ready for continued use, not for executing
untrusted plugins as if sandboxed. Production readiness still requires a hard runtime
isolation/termination decision and recorded release-performance evidence. A green unit test
suite alone does not answer either question.

---

## Sources

Primary sources:

- [Android intents and intent filters](https://developer.android.com/guide/components/intents-filters)
  — explicit/implicit resolution, exported declarations, filter matching, and hijacking
  constraints.
- [Paul Kinlan's Web Intents post-mortem](https://paul.kinlan.me/what-happened-to-web-intents/)
  — over-broad verb space, lifecycle/UX failure, discovery, and provider-selection lessons.
- [D-Bus API design guidelines](https://dbus.freedesktop.org/doc/dbus-api-design.html)
  — versioned names, exactly-one reply, method/signal separation, errors, and extensibility.
- [MCP 2025-11-25 tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
  and [schema](https://modelcontextprotocol.io/specification/2025-11-25/schema) — discovery,
  input/output schemas, structured results, pagination, and effect annotations.
- [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
  — capability/version negotiation, operation, shutdown, and timeouts.
- [MCP progress](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress),
  [cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation),
  and [experimental tasks](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
  — adapter lifecycle and durable-work boundaries.
- [JSON Schema 2020-12](https://json-schema.org/specification) — canonical dialect and
  object validation behavior.
- [Apple App Intents](https://developer.apple.com/documentation/appintents)
  — typed declarations and compiler-generated discovery metadata.
- [Apple `JSVirtualMachine`](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine)
  and the installed SDK's `JavaScriptCore/JSVirtualMachine.h` / `JSContextRef.h`
  — VM isolation, serialization, and initialization-thread/run-loop ownership.
- [VS Code commands](https://code.visualstudio.com/api/extension-guides/command)
  — one command registry serving UI, keybindings, and extension callers.
- [Fuchsia component organization](https://fuchsia.dev/fuchsia-src/get-started/learn/components/organizing-components)
  — explicitly routed capabilities and no ambient authority.
- [OpenTelemetry messaging spans](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
  — propagation/correlation across producer and consumer boundaries.

Repository evidence:

- [`VISION.md`](../VISION.md) — product contract and changeable plugin architecture.
- [`research-plugin-runtimes.md`](research-plugin-runtimes.md) — runtime, permission,
  capability, sandbox, and AI-writability research.
- [`design-plugin-host-capabilities.md`](design-plugin-host-capabilities.md) — current
  single-gate capability design.
- `PluginRuntime.swift` — one-context-per-plugin adapters, provider handlers, scoped
  facilities, contributions, resources, and runtime teardown.
- `PluginHost.swift` — runtime identity, staged activation, generation swap, and reload
  lifecycle.
- `PluginManifest.swift` — stable identity, permission, intent-use/provision, and
  contribution declaration boundary.
