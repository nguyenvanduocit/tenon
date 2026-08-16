# Tenon codebase refactor plan

**Reviewed:** 2026-08-14  
**Branch:** `main` (`f861371`, 11 commits ahead of `origin/main`)  
**Scope:** the live Swift host, intent kernel, plugin runtimes, AppKit/SwiftUI shell, tests, CI, manifests, PRDs, and the current shared worktree  
**Purpose:** resume the interrupted whole-codebase review from pane `FDA8C3FB-35DF-4E19-BA94-654E3238BA66`

## Executive result

Tenon is ready for an evidence-led sequence of bounded refactors, not a rewrite. The current
tree has already paid down several of the earlier audit's runtime defects: event delivery is
mailbox-based and non-blocking, CLI connection permits span the physical request lifetime,
the app declares one window, plugin modal focus/accessibility semantics are native-aware, and
plugin stream processes use process-group ownership. Those are closed items and must not be
reopened as generic cleanup.

Three concerns still deserve priority:

1. **T-091 remains a critical liveness gate.** The original 11 GB main-thread hang was measured,
   but the current sizing correction is explicitly not a proven fix and the live Agent Lens
   reproduction is still missing.
2. **JavaScriptCore is isolation, not a hard sandbox.** A synchronous or memory-exhausting
   plugin evaluation still runs inside the app process. This is a product/security boundary,
   not a class-extraction opportunity.
3. **The largest coordinators are now the main change-risk hotspots.** `CoreIntentCatalog.swift`
   (2,830 lines), `PluginHost.swift` (2,553), `PluginRuntime.swift` (2,136), and
   `IntentDispatcher.swift` (2,098) should be decomposed behind characterization tests while
   their semantic entry points remain stable.

No new public `tenon` path, intent, audience, or capability is proposed by this plan.

## Evidence and review limits

The GitNexus index was rebuilt successfully on the live tree on 2026-08-14:

- 36,355 nodes, 320,410 relationships, 300 execution flows;
- current commit `f861371`, index status up to date;
- 91,535 Swift source lines;
- 65 source files over 400 lines;
- 15 files containing `@unchecked Sendable`, 19 lock-bearing files, 40 actor-bearing files,
  74 `@MainActor` files, and 51 files containing `Task {`.

The planned parallel review workers lost their remote streams before returning results. The
findings below therefore come from the live source, the repository's prior architecture audit,
the current Kanban/PRD decision records, literal call-site sweeps, and a local focused test run.
This is a limitation on independent reviewer diversity, not evidence that an unreturned lane
was clean.

Verification performed:

- `npx gitnexus analyze` — successful;
- `xcodebuild -list -project Tenon.xcodeproj` — successful;
- `xcodebuild test -scheme Tenon -only-testing:TenonCoreTests` — exit 0, 531.827 seconds;
- `xcodebuild test -scheme TenonCore` — not applicable: that standalone scheme has no test action;
- `git diff --check` — clean at the time of inspection.

The worktree is shared and dirty with other sessions. Their files were not reverted, staged, or
rewritten. The report itself is the only intentional file added by this continuation.

## Findings that survive the current tree

### MAJOR — T-091 has measured harm but no live proof of convergence

**Evidence:** `.kanban/board.md:189`; `.kanban/tasks/T-091-a-pane-never-spins-the-update-loop.md`;
`Sources/TenonApp/Canvas/SpatialCanvasNSView.swift`; `Sources/TenonApp/AgentLensView.swift:479-482`.

The original incident reached 11.0 GB with the main thread stuck in one run-loop observer. The
canvas sizing change removed a measured fitting-size path and has focused tests, but the task
explicitly records that it is not a proven resolution. Ten synthetic reproductions failed, and
the untried difference is a live Agent Lens session in a real running app. A refactor that moves
layout, hosting, or Agent Lens ownership before this is characterized can erase the only useful
measurement seam.

**Plan:** keep T-091 outside broad decomposition. Build a reproducible live-app fixture with an
Agent Lens session, capture update-turn count, memory footprint, and run-loop stall evidence, and
add a bounded regression that fails on a non-convergent update sequence. Treat the existing
sizing tests as a guard for the shipped correction, not as closure of the incident.

**Confidence:** HIGH. **Fix lane:** must be a release/architecture gate for the affected UI path.

### MAJOR — JavaScriptCore remains an in-process trust boundary

**Evidence:** `Sources/TenonCore/PluginRuntime.swift:197-214,301-369,537-609`;
`docs/reports/2026-08-07-system-and-documentation-review.md:49-70`;
`docs/prds/plugin-runtime.prd.md:27-33,180-186`.

Pinned JavaScript threads, bounded callback mailboxes, task ledgers, and the whole-shutdown
deadline bound bridge traffic and lifecycle waiting. They cannot preempt a synchronous JavaScript
loop or enforce a heap limit inside the app process. The runtime is therefore suitable for the
current trusted/developer-trusted deployment assumption, but must not be described as a hard
sandbox for arbitrary third-party code.

**Plan:** make the trust posture explicit in user-facing operations docs and installation policy.
For hard isolation, design a supervised helper process with a bounded IPC protocol, per-generation
identity, OS resource limits, kill-and-reap teardown, and failure projection back into the existing
plugin generation model. Do not add a second plugin API or bypass the existing manifest/policy
inventory to implement it.

**Confidence:** HIGH. **Fix lane:** should be a separate security architecture project before
arbitrary untrusted plugins are enabled.

### MAJOR — `PluginHost` is still the lifecycle/contribution/event coordinator hotspot

**Evidence:** `Sources/TenonCore/PluginHost.swift:1-19,371-380,1542-1646,1877-1982,2448-2470`;
`docs/domains.md:36-38`; current file size 2,553 lines.

The façade owns identity, load/reload staging, provider activation, settings/storage, event
routing, view instances, watcher teardown, diagnostics, and contribution projection. The two
domain tags are valid, but the size and co-change surface make lifecycle ordering difficult to
audit. Splitting it by line count would be wrong: the atomic generation commit and one semantic
owner must remain intact.

**Plan:** retain `PluginHost` as a thin façade and extract typed, same-owner collaborators in
this order: (1) inventory and generation staging, (2) settings/storage administration,
(3) event routing, (4) view/contribution projection, and (5) watcher/retirement coordination.
Each slice keeps the existing host method as the only semantic entry, lands characterization and
failure-path tests first, and records its domain tags. Run the impact check before every symbol
move and keep the task's owner-file lock current.

**Confidence:** HIGH. **Fix lane:** should-fix, after liveness/security characterization.

### MAJOR — `IntentDispatcher.send` is a large transaction script, not a reason to add commands

**Evidence:** `Sources/TenonIntentCore/IntentDispatcher.swift:312-360` and the continuation of
its admission/authorization/invocation/settlement paths through the current file (2,098 lines);
`docs/architecture-interaction-boundaries.md` decision law and `docs/design-intent-bus.md`.

The dispatcher correctly remains the single semantic entry point for finite cross-owner
requests. Its physical implementation still combines deadline calculation, admission,
causality, consent, idempotency, provider selection, invocation, and settlement. That makes
terminal paths hard to review and tempts future contributors to introduce handwritten helpers
outside the canonical intent catalog.

**Plan:** introduce internal typed phases—admission, authorization, invocation, settlement—and
move only invariant-bearing state into focused collaborators. Keep one public `send`, one
canonical `IntentResult`, the existing policy gates, and the existing intent inventory. Add
phase-level tests for cancellation, deadline expiry, consent races, idempotency replay/conflict,
provider failure, and retirement before moving code.

**Confidence:** HIGH. **Fix lane:** should-fix.

### MAJOR — `PluginRuntime` needs resource-focused seams before further bundled ports

**Evidence:** `Sources/TenonCore/PluginRuntime.swift:197-263,638-787,1162-1210,1450-1775`;
`Sources/TenonBundledPlugins/BundledPluginRuntime.swift:244-432`; current file size 2,136 lines.

The JavaScript backend owns bridge installation, callbacks, view instances, palette state,
timers, process streams, watchers, storage, event publication, and shutdown. T-167's S1/S2 work
correctly separates host-to-plugin delivery from plugin-to-host publication and makes compiled
settings/storage live, but it also increases the importance of keeping the two backends' resource
and lifecycle semantics aligned.

**Plan:** characterize each resource's ownership and retirement receipt first. Extract internal
resource ledgers/handlers only where they own an invariant; do not create a public typed plugin
API. Then finish T-167's remaining seams in dependency order: view callback routing and instance
state, exact path semantics, generation/instance timers and watchers, structured actions, bounded
activation, and fail-soft per-plugin loading. Port bundled plugins only after their required seam
is green, flipping each manifest and deleting its `main.js` in the same change.

**Confidence:** HIGH. **Fix lane:** should-fix; T-167 remains the active implementation track.

### MINOR — `CoreIntentCatalog` is huge but is the canonical inventory

**Evidence:** `Sources/TenonCore/CoreIntentCatalog.swift:1` and current 2,830-line size;
`docs/architecture-interaction-boundaries.md` closed-inventory rules;
`Tests/TenonCoreTests/CoreIntentCatalogTests.swift` catalog and schema fitness coverage.

The catalog combines declarations, schemas, dispatch rules, exposure, and capability bindings.
It is a real hotspot, but blindly splitting it risks duplicating the canonical inventory or
weakening the exact closed-schema tests. This is a changeability issue, not a license to add
another command layer.

**Plan:** first measure compile/index cost and group definitions by existing semantic inventory
sections. Extract only pure tables or validators with no second source of truth. Require the
normative inventory, source inventory, architecture fitness test, and superseded-path deletion
in one reviewed change for any public addition.

**Confidence:** HIGH. **Fix lane:** could-fix after runtime correctness.

### MINOR — public Swift package surface needs an explicit support decision

**Evidence:** `Package.swift:4-21`; public declarations in `Sources/TenonCore` and
`Sources/TenonIntentCore`; cross-target `package` access in `Sources/TenonCore/PluginHost.swift:330-369`.

The package products are useful to the app and tests, but it is not yet clear whether the public
Swift symbols are a supported SDK or an implementation detail of one app. Ambiguity increases
refactor cost because a `public` declaration is treated as a compatibility contract even when
the real extension boundary is the manifest-backed JavaScript/plugin contract.

**Plan:** choose one: keep the products internal and reduce cross-target surface to `package`/
`internal`, or document and baseline a supported SemVer API. Do not mix this decision with a
target split or rename.

## Closed findings carried forward as guardrails

These earlier findings were checked against the current tree and are not reopened:

- event publication now validates, enqueues, and returns through bounded generation mailboxes
  (`PluginRuntime.swift:1162-1195`, `PluginHost.swift:1542-1646`);
- CLI permits span read, main-actor dispatch, intent reply, and descriptor close
  (`Sources/TenonApp/CLISocketServer.swift:457-495`);
- the app uses one stable `Window` scene rather than a multi-window singleton composition
  (`Sources/TenonApp/TenonApp.swift:30-39`);
- plugin modal presentation owns focus, modal accessibility, Escape, and a labelled close control
  (`Sources/TenonApp/PluginModalOverlay.swift:35-125`);
- plugin streaming process groups and generation ownership are covered by T-140's current
  receipts; do not regress them while splitting resource code.

## Dependency-aware delivery plan

### Phase 0 — characterize and protect liveness

1. Resume T-091 with a real Agent Lens session and a bounded update-turn/memory receipt.
2. Keep T-092's off-main watchdog and diagnostics export as the incident evidence path.
3. Add focused cancellation/deadline/retirement tests around the current T-167 S1/S2 seams.
4. Do not move `PluginHost`, `PluginRuntime`, `SpatialCanvasNSView`, or `IntentDispatcher` until
   the relevant characterization tests are green.

### Phase 1 — secure and bound runtime ownership

1. Decide the trusted-plugin product posture and document it; no “sandbox” wording until helper
   process isolation exists.
2. Finish T-167 S3–S9 in dependency order, preserving the JS backend as a supported third-party
   boundary.
3. Verify generation retirement cancels every timer, watcher, process stream, pending intent,
   event, and view instance without leaking a child or publishing after retirement.

### Phase 2 — decompose without changing public semantics

1. Split `IntentDispatcher` into internal phases while preserving `send`.
2. Extract `PluginHost` collaborators while preserving atomic candidate publication and one
   generation owner.
3. Extract `PluginRuntime` resource/bridge handlers and keep the two backends contract-tested
   against the same manifests and lifecycle cases.
4. Split large Canvas/AppKit files by lifecycle ownership only after the T-091 receipt exists.

### Phase 3 — API and governance clarity

1. Decide the Swift package support surface and add an API baseline or reduce access.
2. Keep `DomainTagFitnessTests` at zero untagged files and add a split review when a file needs
   more than two product-domain tags.
3. Run `xcodegen generate` and require a zero project diff for every source-only change.

### Phase 4 — native quality and verification

1. Run headless Swift tests, hosted integration tests, and the XCUITest lane in CI; preserve
   result bundles for GUI failures.
2. Add mutation checks for lifecycle and policy boundaries, not only happy-path snapshots.
3. Reconcile native design tokens, accessibility state, and localization only after correctness
   and liveness work; these are important but not substitutes for the Phase 0 gates.

## Definition of done

- T-091 has a live reproduction or a documented, measured falsification that closes the incident;
- no plugin execution can be described as a hard sandbox without a helper-process design and
  kill/reap evidence;
- every runtime resource has one owner, one cancellation path, a finite bound, and a retirement
  test;
- public intent inventory, manifests, source inventory, architecture law, and fitness tests
  agree in the same change;
- `swift test`, the appropriate `xcodebuild test` bundles, app build, and `xcodegen` diff all
  pass;
- decomposition changes preserve one semantic implementation and do not introduce handwritten
  finite capability or command APIs;
- the owning PRD decision log and Kanban task carry dated verification receipts.

## Adversarial conclusion

The strongest case against this plan is that large files are not automatically defects and the
current runtime already has strong bounded queues, typed policy, and extensive tests. That case
wins against a big-bang module rewrite: decomposition is conditional and evidence-gated. It does
not defeat the two real gates—the unresolved live liveness incident and the documented absence of
hard process isolation—or the measured auditability cost of the four coordinators. The safe next
change is therefore a focused T-091 receipt or a narrowly scoped T-167 seam, not cosmetic file
movement.
