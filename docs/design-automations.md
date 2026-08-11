# Automations: manifest schedules firing plugin JavaScript

**Status:** accepted, shipped (T-046) · **Date:** 2026-07-31
**Classification authority:** `docs/architecture-interaction-boundaries.md` (the law
selected every mechanism below; this document records the walk, not a new rule).

## The unit of automation is plugin JavaScript

The studied prior art (Orca's Automations, `references/orca/`) fixes its unit of work
as *one prompt string pasted into one TUI-agent PTY on a schedule*, guarded by at most
one shell precheck whose output is discarded. Everything conditional, sequential, or
data-dependent must be folded into the prompt text. Completion is inferred by
heuristics; the stored timezone is never consulted; desktop and headless dispatch are
two divergent implementations.

Tenon inverts the unit. An automation **is a plugin**: ordinary JavaScript in the
ordinary plugin runtime, with the exact public `tenon` surface, the plugin principal,
manifest-declared permissions and intents, JavaScriptCore isolation, and hot reload.
Conditionals, chaining, retries, and data flow are plain JavaScript; actions are the
declared intents that already exist (`process.exec.v1`, `terminal.run.v1`,
`workspace.*`, `network.fetch.v1`, `ui.toast.v1`, …). Orca's whole feature reduces to
one expressible script; scripts Orca cannot express at all — pipe a command's output
into a decision, fan out over workspaces, post different results to different surfaces
— are the same few lines.

The host adds only what resident JavaScript cannot own: **durable wall-clock
scheduling** that survives hot reload and fires without a plugin keeping its own timer
armed (`tenon.timers.every` exists, but dies with its generation, drifts across
reloads, and cannot say "09:00 local").

## Mechanism walk (ordered decision law)

| Piece | Rung | Why |
|---|---|---|
| `automation.schedules` manifest block | **CONTRIBUTION** | declarative registration the plugin owns; host owns validation/reconciliation — the `settings` schema class |
| schedule firing | **EVENT** `automation.fired` | a fact on a host-owned channel; no reply, no result, publisher never awaits observers; delivered owner-scoped through the existing targeted `PluginHost.emit(event:payload:to:)` |
| the automation's actions | existing **INTENT**s | unchanged one-policy path: manifest `uses`, capability grants, consent (T-021/T-033) apply exactly as for any plugin |
| due computation (`AutomationScheduler`) | same-owner **DIRECT** | host-native typed state; time is a parameter everywhere, `Date()` enters only at `AppComposition`'s tick edge (the T-029 pattern) |

**Zero new `tenon` members.** The public runtime inventory, the surface pin, and the
global-scope closure pin are untouched. A plugin observes firings with the
`tenon.events.on` it already has.

## Manifest grammar

```json
"automation": {
  "schedules": [
    { "id": "tick", "every": "1m" },
    { "id": "morning", "daily": "09:00", "grace": "2h" }
  ]
}
```

Validation is fail-closed at manifest decode (`AutomationScheduleSpec` /
`PluginAutomationManifest`, strict unknown-field rejection — the palette-block
precedent):

- exactly one of `every` | `daily` per schedule;
- `every`: `"<positive integer><s|m|h|d>"`, minimum `1m`, maximum `7d`. Sub-minute
  cadence is deliberately inexpressible — that is `tenon.timers.every` (RESOURCE);
  a schedule is a wall-clock automation, not a tick source;
- `daily`: zero-padded 24-hour `"HH:mm"`, resolved against the machine's calendar at
  computation time. **Deliberately no stored timezone**: Orca stores one and then
  evaluates everything in host-local time anyway; dead metadata that promises what the
  code does not do is worse than honestly documented local time;
- `grace`: optional duration (`1m`...`7d`), default one interval for `every`, `6h` for
  `daily` — how stale a missed occurrence may be and still fire;
- ≤ 8 schedules per plugin; ids unique per plugin, 1...64 bytes.

## Firing semantics

- The scheduler holds `nextDue` per (plugin, schedule). A tick at `now` fires every
  schedule with `nextDue ≤ now` — **at most the latest missed occurrence**, and only
  when it is within `grace`; staler misses skip silently and the schedule re-arms from
  `now`. A double tick at one instant fires nothing twice (Orca's idempotent-run rule,
  kept without its persistence machinery).
- Payload: `{ scheduleId, scheduledFor: ISO-8601, late: Bool, trigger }`. `late` is
  set when the firing ran more than 2 minutes behind its instant. `trigger` is
  `"scheduled"` from the tick loop and `"manual"` from the Automation Canvas view's Run Now
  (T-060) — one event, one emit site, distinguishable only by this value.
- Reconcile rides `PluginHost.onPluginLifecycleChanged` — load, hot reload,
  enable/disable, uninstall. An unchanged spec keeps its phase across reloads; a
  changed spec recomputes from reconcile time; only loaded, enabled plugins schedule.
  `PluginSnapshot.automationSchedules` participates in the snapshot's Equatable
  exactly so schedule edits trip the lifecycle callback.
- A firing addressed to a retired/disabled session drops silently in the targeted
  emit — no callback can enter a destroyed context (invariant 10).
- The tick edge (`AppComposition.startAutomationScheduling`) runs every 30 s with 5 s
  tolerance; cadence bounds firing latency, never firing count.

## What an automation does not get

Naming a schedule grants nothing. The firing carries no authority; whatever the
script then does passes the same manifest declaration, capability, policy, and consent
checks as any plugin call (invariants 5, 9). A user-authored automation that wants
`process.exec.v1` declares the permission and the use, and prompts under the same
consent rules as any third-party plugin — standing consent stays host-owned (T-033).

## Worked example — Orca's "daily repo audit", but inspectable

```json
{
  "id": "dev.example.daily-audit",
  "name": "daily-audit",
  "version": "1",
  "permissions": ["process.exec"],
  "intents": { "uses": ["process.exec.v1", "ui.toast.v1"], "provides": [] },
  "automation": { "schedules": [ { "id": "morning", "daily": "09:00" } ] }
}
```

```js
tenon.events.on("automation.fired", async function (e) {
  var result = await tenon.intents.send("process.exec.v1", {
    command: "/usr/bin/git",
    arguments: ["status", "--short"],
    workingDirectory: "/path/to/repo"
  });
  if (!result.ok) { return; }
  var out = result.value.standardOutput;
  var dirty = out.kind === "inline" && out.text.trim() !== "";
  if (!dirty) { return; }                            // condition — plain JS
  await tenon.intents.send("ui.toast.v1", {          // different action per result
    message: "daily-audit: worktree dirty since " + e.scheduledFor,
    kind: "warning"
  });
});
```

The precheck-output-into-prompt plumbing Orca lacks is the `out.text` variable.

## Orchestration: the dynamic-workflow shape (added 2026-07-31, after T-040/T-044)

Claude Code's *dynamic workflows* write an orchestration script — `agent()`,
`parallel()`, `pipeline()`, loops — and drive a fleet of subagents. Tenon's automation
reaches the same shape **by composition, with zero new machinery**, because the
automation is already real async JavaScript over the intent catalog:

| Workflow primitive | Tenon primitive | Since |
|---|---|---|
| orchestration script | the automation's plugin JS | T-046 |
| trigger | `automation.fired` schedule / any EVENT / palette intent | T-046 |
| `agent()` — spawn + await result | `terminal.open.v1` → `terminal.wait.v1` (`command-finished`, `{scope:{paneID}}`) → `terminal.scrollback.read.v1` pages | T-040 + T-009 + T-044 |
| headless `agent()` with structured output | `process.exec.v1` (e.g. `claude -p … --output-format json`) → parse stdout | pre-existing |
| `parallel()` | `Promise.all` — the runtime holds up to **256** in-flight outbound intents per generation (`PluginRuntime.swift:101,983`) | T-046 runtime |
| `pipeline()` / loops / conditionals / retry | plain JavaScript | — |
| supervision (the part Claude Code does not have) | every pane agent is a real PTY pane: attention signals (T-029), scrollback evidence, human can take over mid-run | VISION |

`agent()` **ships as the platform function `tenon.agents.run`** (T-048, user-directed:
automation scripts are AI-authored, the platform provides the functions). It is
JavaScript composition inside the caller's own generation — caller principal, no new
bridge, no new authority; the runtime-surface pin gained exactly one member:

```js
tenon.events.on("automation.fired", async function () {
  // fleet: three reviewers in three visible, supervised panes
  var results = await Promise.all([
    tenon.agents.run({ command: "claude", arguments: ["-p", "review src/a for correctness"] }),
    tenon.agents.run({ command: "claude", arguments: ["-p", "review src/a for security"] }),
    tenon.agents.run({ command: "claude", arguments: ["-p", "review src/a for tests"] })
  ]);
  var findings = results
    .filter(function (r) { return r.ok; })
    .map(function (r) { return r.value.transcript; });
  // aggregate, decide, act — plain JavaScript
});
```

`tenon.agents.run({ command, arguments?, workingDirectory?, timeoutMs? }, sender =
tenon.intents)` → `{ ok: true, value: { paneID, transcript } }` or
`{ ok: false, error, paneID? }`. Semantics, each mutation-proven in `AgentsRunTests`:

- **arguments are POSIX-single-quoted per token** — a prompt containing `'`, `$()`,
  or backticks can never become shell syntax in the user's PTY;
- opens via `terminal.open.v1`, then arms `terminal.wait.v1` (`command-finished`,
  `{scope:{paneID}}`) immediately — the wait snapshots its completion baseline when
  issued (`TerminalIntentProvider.swift:405,428`: no latch), and in a real pane the
  command starts strictly later (T-031 lazy materialization), so arming right after
  open closes the race in practice; a contract-level client-held baseline remains a
  recorded T-048 follow-up;
- per-call wait caps at the contract's 55 s; the loop is bounded by `timeoutMs`
  (default 10 min) and fails typed (`dev.tenon.agents.timeout`) without reading;
- pages the transcript via `terminal.scrollback.read.v1` cursor-chained; a resize
  mid-walk (`invalidated`) restarts the walk once clean, twice fails typed
  (`dev.tenon.agents.scrollback-unstable`);
- the optional trailing `sender` is the one sender shape every sending function uses.
  Passing a handler's `call` scopes the run to that invocation's pane, caps the whole run
  at that intent's deadline instead of `timeoutMs`, and cancels it with the invoking
  command; omitting it keeps the run's own budget under the ambient scope. Anything that
  is neither `tenon.intents` nor a handler's `call` is a `TypeError`.

Manifest for such an automation declares exactly what it uses — `terminal.write`
permission plus `uses: ["terminal.open.v1","terminal.wait.v1","terminal.scrollback.read.v1"]`
— and the one-policy path applies per underlying call, like every plugin. The
rejected packaging (a broker plugin providing `agent.run` as a plugin-owned intent)
would have executed under the broker's grants — authority laundering — and is
recorded in T-048.

## The operations surface (T-060, moved to Canvas)

Automation has a host-native Canvas control center. It is operational workspace content,
alongside Changes, rather than a settings form: a person can keep what runs next,
what needs attention, and the exact delivery evidence visible next to the terminals they
supervise. Settings ▸ Automation contains configuration only. Its global **Enable scheduled
automations** preference is persisted, defaults on when an older preferences document lacks
the field, and pauses scheduled delivery without disabling or unloading the plugins that
declared schedules. An explicit Run Now remains a user-directed manual firing.

Opening the pane from an empty host-native Canvas target is same-owner **DIRECT** workspace
placement. Its discoverable launcher/palette entry is plugin-owned presentation metadata
(a **CONTRIBUTION**); accepting that user row invokes the finite
`dev.tenon.core-commands.automation.open.v1` **INTENT**, whose provider delegates through
the existing `workspace.tab.create.v1` INTENT adapter. There is no new core intent and no
new public `tenon` member.

- **Situation summary**: active schedule count, the next eligible event, schedules needing
  attention, and an honest `delivered/attempted` ratio over the bounded recent-evidence
  buffer. Delivered means only that a live plugin generation accepted `automation.fired`;
  the host never calls that business success.
- **Schedule navigator**: every declaration of an enabled plugin remains visible, including
  declarations owned by a plugin that is unloaded or failed — that is an anomaly a person
  still has to see. A disabled plugin is different: the person removed it from the product,
  so its schedules leave the pane entirely and return intact, pause preference included,
  when the plugin is enabled again. Search and `All / Attention / Paused` filters narrow a
  stable `(pluginID, scheduleID)` list. Selecting a row opens one inspector instead of
  repeating all metadata in a flat log.
- **Inspector**: cadence, live next-due instant, grace, plugin identity, exact schedule id,
  availability reason, and the selected schedule's bounded delivery activity. This is read
  DIRECT from `PluginHost`, `AutomationScheduler`, and `AutomationRunHistory` state (same
  owner, invariant 6). Zero new `tenon` members; the plugin boundary is not involved in
  display.
- **Run Now**: mints a manual firing (`AutomationScheduler.manualFiring`) and
  delivers it through `PluginHost.automationFired`, the same single emit site the
  tick loop uses; the plugin sees the ordinary `automation.fired` with
  `trigger: "manual"`. A manual run never shifts the schedule's phase — `nextDue`
  is untouched.
- **Pause / Resume one schedule**: a host-owned preference keyed by `(pluginID, scheduleID)`.
  While paused, due occurrences advance without delivery, so resume never replays skipped
  work. The manifest declaration remains visible and manual Run Now remains available.
  The preference survives hot reload, temporary plugin disable, and app relaunch; it grants
  no plugin authority. Owner-scoped policy epochs invalidate an in-flight batch only for the
  changed schedule; global enablement changes still invalidate the remainder of the batch.
- **Run history**: a bounded, newest-first buffer (`AutomationRunHistory`, capacity
  128, invariant 10) recorded at the one place firings are delivered, so history
  cannot disagree with delivery. Each row carries exactly the facts the plugin
  received — schedule, scheduled instant, trigger, lateness — plus the host-side
  delivery outcome (a live, subscribed generation took the event, or it dropped).
  Reconcile never touches it: recent evidence survives hot reloads of the plugin it
  describes. UI copy says `Recent` rather than claiming evicted records are still part of a
  whole-session total. Selecting a row places the owning plugin's own registered shared view
  as ordinary workspace content, through the same typed store call
  `workspace.content.open.v1` adapts — the run is host evidence of delivery, and the panel
  beside it is the only surface that knows what the run did. A plugin whose views are all
  per-pane has no shared panel to lead to, so its rows stay evidence and draw no control.
  That navigation is the whole of it: a deep link into a per-plugin log surface still waits
  on such a surface existing.

  This is also the only moment such a panel appears. A firing places nothing — the schedule
  runs while a person is in the middle of something else, and a pane that arrives unasked
  costs more attention than the finding is usually worth. A script with something a human
  must clear says so in one status-bar line and waits to be visited.

## Recorded non-goals (follow-ups)

- **Cross-restart catch-up**: `nextDue` is in-memory; a schedule missed while the app
  was not running does not fire on launch. Needs a small persisted last-fired map.
- **Unattended terminal scope**: `terminal.run.v1` targets the invocation scope's
  visible terminal; a headless firing wants an explicit pane/tab designation story
  (adjacent: T-040).

## A worked example: `examples/fleet-review`

`examples/fleet-review/` is the supervised-fleet story in about eighty lines: one
palette command puts three reviewers on the same change, each in its own visible pane,
waits for all of them, reads each transcript back, and publishes a one-line verdict.

It lives in `examples/` rather than `plugins/` deliberately — a demo that runs an agent CLI
does not belong in every user's palette by default. Copy the directory into `plugins/`
to try it.

Two things in it are worth copying into your own automation:

- **`arguments` is an array, never a joined string.** `tenon.agents.run` POSIX-quotes each
  token itself, so a prompt containing `'` or `$(...)` cannot become shell syntax in the
  user's PTY.
- **The command declares `confirmation: "never"`.** It performs nothing itself; every
  external effect happens through `terminal.open.v1`, which is already `policy`-gated. A
  confirmation here would ask the human four times for one click, which trains them to
  click through the one that matters.

`FleetReviewExampleTests` loads this exact directory through a real `PluginHost` and runs
the command, so the example cannot rot unnoticed.

## Single-file automations (shipped, T-047)

An automation does not need a directory. A lone `.js` file in the plugins root, opening with
a manifest header, is discovered, validated, activated, hot-reloaded and retired exactly like
a directory plugin:

```js
/* tenon-manifest
{
  "id": "dev.example.nightly",
  "name": "nightly",
  "version": "1",
  "permissions": [],
  "intents": { "uses": [] },
  "automation": { "schedules": [{ "id": "nightly", "daily": "02:00" }] }
}
*/
tenon.events.on("automation.fired", async function () {
  // ...
});
```

The header is not a shortcut around declaring things. A manifest is load-bearing —
permissions and `intents.uses` are read *before* any JavaScript is evaluated — so embedding
it as a leading comment keeps declare-before-eval while collapsing the packaging to one
file. Both shapes end at the same `PluginManifest` decoder, so a single-file plugin is held
to exactly the same rules, and identity (duplicate id, reserved prefixes) applies across the
mixed namespace.

Two rules worth knowing:

- **The header must open the file.** Code above it would run before the plugin had declared
  what it may do, and a file with two headers has no answer to which one is the declaration.
- **A `.js` file with no header is not a plugin, and not an error either.** A scratch script
  left in the plugins folder is skipped; a file that *does* claim to be a plugin and gets the
  header wrong fails loudly, with a diagnostic naming the file and what to fix.

## Where an authored plugin lives (T-062)

Tenon reads plugins from **two inventories, ordered**:

1. the app bundle's own `Contents/Resources/plugins` — sealed and replaceable;
2. `~/Library/Application Support/Tenon/user-plugins` — writable and durable.

The split is not organisational, it is forced by what the two directories are. The
bundle is code-signed: a file added to it invalidates the signature, and installing a
new build replaces the bundle and deletes the addition. So **authoring is always sent
to the user inventory** (`PluginHost.writableInventoryRoot`), and the bundle is
reported as not writable rather than merely discouraged.

Trust follows the inventory, not the file's location on its own: a bundled plugin was
accepted when the user installed Tenon and keeps its standing consent; a plugin the
user or an agent wrote is untrusted and is asked, exactly like any third-party plugin
(T-033, T-050). That is what stops "put the file in the right folder" from being a way
to grant authority. The consequence is deliberate: an authored automation that uses a
`.policy` intent prompts on its first firing, and an unattended firing with nobody at
the window expires on T-050's bound instead of running.

Both inventories are watched, so a user plugin hot-reloads exactly like a bundled one,
and the earlier inventory wins any identity clash — a user plugin cannot displace a
bundled one by reusing its id.

**A clash costs the plugin that arrived late, never the host.** Reusing a bundled id,
reusing a bundled *directory name*, overlapping a bundled namespace, claiming the
reserved `dev.tenon.core` prefix, naming a contract that does not exist — each of these
refuses that one plugin, records a diagnostic against its directory, and leaves every
other plugin loading normally. Only a clash *inside the app's own inventory* still stops
the load, because that one ships with the build and a clash there is a build error.

The asymmetry is the whole point. Everything in the user inventory is writable by a
person or an agent who is mid-experiment, and Tenon's ability to start must not depend
on them getting it right. Before this rule an identity clash threw out of `loadAll`, so
Tenon started with *no* plugins; a duplicate directory name did worse and trapped the
process, since the reload index is keyed by that name and was built assuming it was
unique.

## Creating one with an agent (T-061)

Automation Canvas ▸ **Create with AI…** opens a fresh terminal tab whose shell
starts in the writable user inventory and types one command: `claude` with a
host-authored guide as a single POSIX-quoted argument (`AutomationAuthoring`, pure and
pinned headless).
The guide teaches exactly what this document specifies — the `/* tenon-manifest`
opener, cadence syntax and bounds, the `automation.fired` payload, the real writable
path plus why `Tenon.app` is never it, `tenon-cli intent list`/`describe` for
discovery — and ends with
the T-060 verification loop: save, watch the schedule appear, press Run Now, read the
run's outcome, expect the consent prompt on the first privileged call.

The host grants nothing here. The pane holds ordinary shell authority; the script the
agent writes earns its authority the ordinary way (manifest declaration, one policy
path, consent). The button is the same typed services `terminal.open.v1` adapts,
called DIRECT as the host's own gesture — the flow adds no intent, no capability, and
no `tenon` member.
