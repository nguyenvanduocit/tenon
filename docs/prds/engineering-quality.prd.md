# PRD — Engineering quality, evidence routing, and maintainable native delivery

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-015` |
| Lifecycle | `partial`; quality system ships, full native-interaction evidence strategy remains planned |
| Owner | engineering |
| Reviewers | feature engineers, test/CI, native UI, accessibility, localization, release, operations |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-023, T-043, T-074, T-082, T-090, T-094, T-095, T-114, T-117, T-118, T-128 |
| Normative sources | [`tdd.md`](../tdd.md), [`development.md`](../development.md), [`operations.md`](../operations.md), [`designs.md`](../designs.md), [`domains.md`](../domains.md), [`TenonUITests README`](../../Tests/TenonUITests/README.md) |
| Acceptance specification | [`engineering-quality.feature`](engineering-quality.feature) |

## 1. Executive summary

### Problem

Green tests can lie when their directory is not run, their expectation derives from the code under
test, a sleep measures machine load, a headless shape test is presented as pixel evidence, or a mock
never crosses the native adapter that was broken. Build scripts can duplicate dependency and module
caches until the checkout consumes gigabytes. Large coordinator files and unaudited domain tags make
changes miss hidden edges. Accessibility, localization, visual layout, real PTY/WebKit behavior, and
window-level gesture routing each need different evidence; pushing everything into XCUITest would be
slow and flaky, while testing none of it loses the actual product.

### Proposed outcome

Every behavior is routed to the lowest test layer that can prove its rule, then receives the smallest
real adapter receipt needed for changed native boundaries. Pure domain/policy/layout rules run fast
headless. Hosted AppKit/SwiftUI tests prove hit-testing, responder, menu, drag, and projection seams.
Real-service integration proves PTY/Ghostty/WebKit/filesystem/runtime boundaries. A small black-box
XCUITest suite proves launch, accessibility, shortcuts, focus, menus, and gestures through the built
app. Visual and accessibility review provide distinct evidence rather than borrowing each other's
claims.

Build/test manifests agree, warnings fail CI, verification receipts state commands/worktree/results
instead of frozen counts, flaky waits follow facts/deadlines, and mutation proves critical tests can
turn red. One shared build cache is pruned safely. Controlled product-domain tags provide a starting
set, followed by mandatory symbol-edge search. Coordinators split by responsibility without changing
behavior. Quality should accelerate trusted iteration: fast paths run first, GUI/manual layers stay
small and purposeful, and ceremony must buy a named failure signal.

### Why now

T-023, T-043, T-074, T-082, T-094, and T-095 shipped concrete remediations. T-090 remains a detailed
research/spike backlog for the final native UI testing decision matrix, Accessibility audit,
visual-regression choice, GUI runner contract, and feature-author routing guide. This PRD records both
the shipped quality bar and that honest remaining gap.

## 2. Discovery record

| Evidence | Source | Confidence | What it establishes |
|---|---|---|---|
| test architecture | [`tdd.md`](../tdd.md), Package/project manifests | high | functional core, shell adapters, exact runner coverage |
| commands/receipts | [`development.md`](../development.md), [`operations.md`](../operations.md) | high | build/test paths, runner constraints, release evidence |
| native UI contract | [`designs.md`](../designs.md), UI test README, hosted/XCUITest sources | high | pixels/accessibility/gesture evidence requirements |
| domain ontology | [`domains.md`](../domains.md), `DomainTagFitnessTests` | high | controlled vocabulary, coverage ratchet, retrieval limit |
| completed tasks | T-023/T-043/T-074/T-082/T-094/T-095 | high | cache, runner, flake, tags, accessibility/localization, decomposition shipped |
| remaining task | T-090 | high | spikes/decision matrix not complete and must stay planned |
| system audit | 2026-08-07 review report | medium/high | historical 1,379-test/build receipt and structural-risk snapshot, not a current count |

### Context and assumptions

| Question | Answer |
|---|---|
| Core problem? | Produce evidence that would fail for the real regression, at sustainable speed, while keeping the code understandable. |
| Primary users? | feature engineers and AI agents changing Tenon, reviewers, and release operators |
| Success? | no unreachable tests, deterministic failures, small native receipts, current docs, clean builds, fast local loop |
| Fixed constraints? | Swift 6 warnings-as-errors, macOS GUI requirements, real native interaction where applicable, mandatory design/domain docs |
| Unknown? | final snapshot/accessibility/test-plan/GUI-CI tooling choices from T-090 spikes |

## 3. Goals, measures, scope, and bounds

- `ENQ-G-001` — Every requirement has a reachable evidence seam that can turn red.
- `ENQ-G-002` — Fast headless feedback remains the default while real adapters are not skipped.
- `ENQ-G-003` — Native pixels, accessibility, interaction wiring, and performance have distinct receipts.
- `ENQ-G-004` — Build/cache/test operations remain reproducible, bounded, and documented.
- `ENQ-G-005` — Product-domain ownership and coordinator boundaries reduce context omissions.
- `ENQ-G-006` — Quality ceremony stays proportional to the failure it can detect.

Targets: every `Tests/` directory reachable by `swift test` or explicitly justified Xcode-only;
Package/project scheme agreement; zero Swift/Xcode warnings; zero fixed sleeps where a fact exists;
critical regressions mutation-proven; small XCUITest set with stronger postconditions than existence;
all `Sources/` files tagged, >400-line MARKs tagged, untagged budget never raised; two steady-state
build trees plus one dependency checkout; no copied durable test count; accessibility and localization
for user-facing/AppKit strings; visual review for layout-sensitive changes.

In scope: test-first flow, layer routing, manifests/runners, mocks/real services, native UI and visual
evidence, accessibility/localization, determinism/flake policy, CI artifacts, build cache, warnings,
verification receipts, domain tags, coordinator decomposition, and planned T-090 research. Non-goals:
100% line coverage, putting every rule in XCUITest, snapshotting every pixel, accepting retries as a
flake fix, tests gated by production accessibility IDs, or splitting code solely to hit a line count.

## 4. Developer experience

A feature begins with a failing pure/boundary test where possible, gains the minimum implementation,
then wires the native shell and proves the smallest changed adapter path. `swift build` and
`swift test` are the fast default. Hosted app-state tests run native views/events without full app
launch. Integration and XCUITest run through Xcode when real GPU/PTY/WindowServer/Accessibility are
required. Visual inspection and accessibility-tree inspection are explicit separate steps.

Fixtures use temporary roots and deterministic state. Waits observe facts or bounded deadlines, not
assumed turn counts. Failure artifacts keep `.xcresult`, screenshots, accessibility hierarchy, logs,
environment, and relevant snapshots as applicable. Build scripts share `.build` paths and skip cache
pruning while another build owns the tree.

Before source edits, domain tags narrow the starting set; every touched symbol is then searched
source-wide because Swift intra-module visibility hides edges. Large/multi-domain coordinators split
along product responsibility while behavior tests remain unchanged.

## 5. Requirements

### Functional requirements

| ID | Requirement | Delivery | Acceptance |
|---|---|---|---|
| `ENQ-FR-001` | Feature delivery **MUST** follow red → minimal green → shell wiring → smallest valid smoke/adapter receipt, confirming the red failed for the intended reason. | shipped process | `@req-enq-fr-001` |
| `ENQ-FR-002` | Domain, policy, schema, layout, and state-machine rules **MUST** live in typed headlessly testable core/services; native shell code **MUST** contain projection/adapters rather than duplicate rules. | shipped | `@req-enq-fr-002` |
| `ENQ-FR-003` | Each rule **MUST** use the lowest-cost layer that can prove it, plus a hosted/integration/black-box receipt when the changed boundary cannot be proved below it. | shipped/partial guide | `@req-enq-fr-003` |
| `ENQ-FR-004` | `Package.swift`, `project.yml`, generated scheme, documentation, and test directories **MUST** agree on target membership and runner coverage. | shipped | `@req-enq-fr-004` |
| `ENQ-FR-005` | Every directory under `Tests/` **MUST** be reached by `swift test` or have an explicit Xcode-only reason and command; unreachable files **MUST NOT** count as evidence. | shipped | `@req-enq-fr-005` |
| `ENQ-FR-006` | Fast verification **MUST** run `swift build` and all three headless suites through `swift test`; special filters **MUST NOT** replace the complete bar before handoff. | shipped process | `@req-enq-fr-006` |
| `ENQ-FR-007` | A changed SwiftUI/AppKit adapter **MUST** have the smallest hosted test that proves hit testing, target/action, responder, focus, menu, drag, projection, or lifecycle behavior the core cannot. | shipped/continuous | `@req-enq-fr-007` |
| `ENQ-FR-008` | XCUITest **MUST** remain a deliberately small black-box built-app suite for launch/accessibility/shortcut/focus/menu/gesture wiring and **MUST** assert a meaningful postcondition beyond element existence. | shipped/continuous | `@req-enq-fr-008` |
| `ENQ-FR-009` | Layout/appearance changes **MUST** include controlled real native rendering in relevant width/theme/contrast/text conditions; tree shape or source inspection **MUST NOT** be called pixel evidence. | partial/continuous | `@req-enq-fr-009` |
| `ENQ-FR-010` | Accessibility changes **MUST** inspect labels, values, actions, hierarchy, focus/traversal, modality, and VoiceOver meaning; screenshots **MUST NOT** substitute for the accessibility tree. | shipped/continuous | `@req-enq-fr-010` |
| `ENQ-FR-011` | Ghostty/PTY, WebKit, FSEvents, plugin JavaScript, persistence/relaunch, and OS-dialog claims **MUST** use a real-service integration receipt where stubs cannot prove the boundary. | shipped/continuous | `@req-enq-fr-011` |
| `ENQ-FR-012` | Performance/hitch/launch claims **MUST** use signpost/benchmark/Instruments evidence and **MUST NOT** be inferred from a correctness E2E passing. | partial/continuous | `@req-enq-fr-012` |
| `ENQ-FR-013` | Manual/exploratory verification **MUST** name the exact truth automation cannot establish, setup, observable result, and retained artifact; “verify manually” **MUST NOT** be unbounded escape. | partial/continuous | `@req-enq-fr-013` |
| `ENQ-FR-014` | Tests **MUST** isolate workspace, preferences/state root, plugin inventory, fixtures, clock/random state, and stub/real-service choice; cleanup **MUST** be provable after failure. | shipped/continuous | `@req-enq-fr-014` |
| `ENQ-FR-015` | Asynchronous tests **MUST** wait on a state predicate/event with a finite deadline; fixed sleep or turn count **MUST NOT** represent correctness when a fact is observable. | shipped | `@req-enq-fr-015` |
| `ENQ-FR-016` | Critical tests **MUST** demonstrate they fail under the named behavior mutation; a green baseline or tautological expectation is not sufficient evidence. | shipped practice | `@req-enq-fr-016` |
| `ENQ-FR-017` | A suspected flaky gate **MUST** be repeated under representative load and repaired at its nondeterministic seam; retries **MAY** diagnose but **MUST NOT** turn a flaky failure green. | shipped/continuous | `@req-enq-fr-017` |
| `ENQ-FR-018` | GUI/integration failure handling **MUST** retain applicable result bundle, activity, screenshot, accessibility hierarchy, logs, launch environment, and state snapshot. | planned/partial CI | `@req-enq-fr-018` |
| `ENQ-FR-019` | Build/test/release receipts **MUST** state worktree/commit, exact command/destination, exit code, failures, and exclusions; durable docs **MUST NOT** freeze a test count. | shipped | `@req-enq-fr-019` |
| `ENQ-FR-020` | Steady-state build storage **MUST** use only shared SwiftPM `.build/<triple>` and `.build/xcode` trees with one shared dependency checkout/repository cache. | shipped | `@req-enq-fr-020` |
| `ENQ-FR-021` | Xcode/SwiftPM/install scripts **MUST** use the same cloned-package/cache paths; install **MUST NOT** create a private CLI dependency graph. | shipped | `@req-enq-fr-021` |
| `ENQ-FR-022` | Development/install cache pruning **MUST** remove only regenerable duplicate/intermediate data, be idempotent, preserve products/incremental inputs, and skip when another build owns the tree. | shipped | `@req-enq-fr-022` |
| `ENQ-FR-023` | CI and supported local builds **MUST** treat Swift/Xcode compiler warnings as errors while separately documenting unavoidable vendored linker warnings. | shipped | `@req-enq-fr-023` |
| `ENQ-FR-024` | Every `Sources/` file **MUST** carry one or two declared product-domain tags above imports; more than two **MUST** trigger split review. | shipped | `@req-enq-fr-024` |
| `ENQ-FR-025` | Every `// MARK:` section in a source file over 400 lines **MUST** carry its domain tag on the MARK line. | shipped | `@req-enq-fr-025` |
| `ENQ-FR-026` | `docs/domains.md` **MUST** be the only domain vocabulary; every domain **MUST** use slug syntax, state Excludes, and match at least one source file. | shipped | `@req-enq-fr-026` |
| `ENQ-FR-027` | Domain retrieval **MUST** start with tag search then search every touched symbol source-wide; tag results **MUST NOT** be represented as complete dependency coverage. | shipped process | `@req-enq-fr-027` |
| `ENQ-FR-028` | Domain fitness **MUST** fail empty scans, undeclared/unused/invalid tags, missing large-file MARK tags, and untagged count above the ratchet; the budget **MUST** only decrease. | shipped | `@req-enq-fr-028` |
| `ENQ-FR-029` | A coordinator spanning several product responsibilities **MUST** be decomposed along domain/typed-phase boundaries while preserving behavior and keeping source/package public API no broader. | shipped/continuous | `@req-enq-fr-029` |
| `ENQ-FR-030` | Shared product behavior **MUST** have one bounded typed implementation rather than parallel parsers/process runners/event gates/projections with diverging limits. | shipped/continuous | `@req-enq-fr-030` |
| `ENQ-FR-031` | User-visible state **MUST** remain understandable without color, icon-only controls **MUST** have localized labels/help, decorative symbols **MUST** be hidden, and machine IDs **MUST NOT** be spoken. | shipped/continuous | `@req-enq-fr-031` |
| `ENQ-FR-032` | The package **MUST** declare a base language and String Catalog; AppKit/SwiftUI accessibility labels, spoken states, menu titles, and user-visible diagnostics **MUST** use localization rather than raw literals. | shipped/continuous | `@req-enq-fr-032` |
| `ENQ-FR-033` | Animation and transition behavior **MUST** respect Reduce Motion while preserving state/focus/outcome. | shipped/continuous | `@req-enq-fr-033` |
| `ENQ-FR-034` | The native-testing strategy **MUST** complete representative hosted, black-box, accessibility-audit, and visual spikes; compare tools/runners with measured cost/flake/diagnostics; and publish the feature-author routing/runner/artifact contract. | planned (T-090) | `@req-enq-fr-034` |
| `ENQ-FR-035` | A distributed artifact **MUST** be signed with one Developer ID identity covering the app, every embedded framework, and the bundled CLI, signed innermost-first; `--deep` **MUST NOT** be used to sign, and remains valid only for verification. | shipped (T-114) | `@req-enq-fr-035` |
| `ENQ-FR-036` | A distribution build **MUST** enable the Hardened Runtime and **MUST** grant `com.apple.security.cs.allow-jit` and no wider exception; `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `disable-library-validation`, `allow-dyld-environment-variables`, and `get-task-allow` **MUST** be absent. | shipped (T-114) | `@req-enq-fr-036` |
| `ENQ-FR-037` | The local install path **MUST** stay ad-hoc and unhardened and **MUST NOT** require a certificate, because Library Validation refuses this app's embedded frameworks under an ad-hoc signature. | shipped (T-114) | `@req-enq-fr-037` |
| `ENQ-FR-038` | Release packaging **MUST** produce a universal artifact, notarize and staple it, and verify a copy extracted back out of the published archive rather than the bundle verified in place. | shipped (T-114) | `@req-enq-fr-038` |
| `ENQ-FR-039` | Distribution metadata — version, checksum, bundle identifier, minimum macOS — **MUST** be derived from the built artifact rather than transcribed into a cask or release note by hand. | shipped (T-114) | `@req-enq-fr-039` |
| `ENQ-FR-040` | Every input the generated project declares **MUST** be produced by setup from a tracked or checksummed source, and setup **MUST** produce it even when the downloaded artifact is already installed and verified; an input that exists only on a developer's machine **MUST NOT** be a build requirement. | shipped (T-117) | `@req-enq-fr-040` |
| `ENQ-FR-041` | The repository root **MUST** hold exactly one executable, a dispatcher that lists every verb with a one-line description read out of the scripts themselves; a script a person types **MUST** live at `scripts/<verb>.sh` and declare its own name, description and group, and a script only another script calls **MUST** live under `scripts/internal/`. | shipped (T-128) | `@req-enq-fr-041` |
| `ENQ-FR-042` | Exactly one path in the repository **MUST** create a GitHub release, and it **MUST** run where the signing identity already lives; a second automated road **MUST NOT** exist, including as a dry-run or disabled remnant. | shipped (T-128) | `@req-enq-fr-042` |
| `ENQ-FR-043` | No operator-facing document, script comment, or workflow step **MUST** name a script path that does not exist; the rule **MUST** be asserted rather than reviewed, because a moved script leaves no compile error behind. | shipped (T-128) | `@req-enq-fr-043` |

### Non-functional requirements

| ID | Category | Requirement | Delivery | Acceptance |
|---|---|---|---|---|
| `ENQ-NFR-001` | speed | The headless red/green loop **MUST** stay fast enough for normal per-edit use; slower hosted/GUI/performance/manual evidence **MUST** be scoped to changed boundaries. | shipped/continuous | `@req-enq-nfr-001` |
| `ENQ-NFR-002` | determinism | Identical fixtures and facts **MUST** yield identical assertions independent of machine load, event coalescing, ordering accidents, or locale. | shipped/continuous | `@req-enq-nfr-002` |
| `ENQ-NFR-003` | diagnostic quality | A failure **MUST** identify the broken rule, actual/expected observable state, layer/environment, and retained evidence rather than time out ambiguously. | partial/continuous | `@req-enq-nfr-003` |
| `ENQ-NFR-004` | maintainability | Tests **MUST** assert public/domain behavior independently of implementation constants and avoid coupling to unstable SwiftUI internals without unique signal. | shipped practice | `@req-enq-nfr-004` |
| `ENQ-NFR-005` | coverage honesty | Evidence status **MUST** distinguish shape, hosted interaction, black-box wiring, visual pixels, accessibility, real-service, performance, and manual truths. | shipped/continuous | `@req-enq-nfr-005` |
| `ENQ-NFR-006` | resource hygiene | Test/app processes, PTYs, WebViews, watchers, temporary roots, build locks, result bundles, and caches **MUST** be bounded and cleaned without deleting another run's state. | shipped/continuous | `@req-enq-nfr-006` |
| `ENQ-NFR-007` | CI reliability | Presubmit/headless, hosted integration, nightly GUI/stress, performance, and manual-release responsibilities **MUST** be explicit; GUI runners require logged-in WindowServer and automation access. | partial | `@req-enq-nfr-007` |
| `ENQ-NFR-008` | accessibility/localization | Quality gates **MUST** include non-color meaning, focus/modality, spoken content, input parity, base language, and localized AppKit seams. | shipped/continuous | `@req-enq-nfr-008` |
| `ENQ-NFR-009` | documentation accuracy | Commands, target inventories, paths, design metrics, and implementation status **MUST** be checked against current manifests/source; stale prose **MUST NOT** be accepted as evidence. | shipped/continuous | `@req-enq-nfr-009` |
| `ENQ-NFR-010` | change safety | Refactors **MUST** preserve behavior receipts and independently search symbol edges; unrelated dirty worktree changes **MUST** remain untouched. | shipped process | `@req-enq-nfr-010` |
| `ENQ-NFR-011` | developer velocity | A quality step **MUST** remain only when it catches a named class of failure at proportionate cost; redundant or vacuous ceremony **MUST** be removed. | continuous | `@req-enq-nfr-011` |
| `ENQ-NFR-012` | reproducibility | Verification commands and environments **MUST** be rerunnable from generated project and SwiftPM paths with captured tool/OS/destination where results depend on them. | partial/continuous | `@req-enq-nfr-012` |
| `ENQ-NFR-013` | credential hygiene | Signing and notarization credentials **MUST** be read from a stored keychain profile rather than repository files, command arguments, or logged environment; a shared runner **MUST** import the identity into a keychain it creates for the job and destroys afterwards. | shipped (T-114) | `@req-enq-nfr-013` |

## 6. Acceptance and delivery

[`engineering-quality.feature`](engineering-quality.feature) maps all 56 requirements. Evidence is
the quality system itself: tests that reach each runner, mutation receipts, deterministic waits,
source fitness gates, cache scripts, localization/catalog artifacts, hosted/XCUITest suites, CI
configuration, and the pending T-090 spikes.

| Requirements | Evidence | State |
|---|---|---|
| 001…019 | TDD/runner docs, repaired target manifests, headless/hosted/integration/UI suites, flake mutations | shipped/continuous; artifact contract partial |
| 020…023 | shared build paths/pruner/scripts/CI warnings policy | shipped |
| 024…030 | domain vocabulary/fitness, decomposed coordinators and typed phases | shipped/continuous |
| 031…033 | design system, accessibility/localization/remediation and UI tests | shipped/continuous |
| 034 and NFR-003/005/007/012 | T-090 research/spikes/decision matrix/GUI artifact contract | planned/partial |
| 035…039 and NFR-013 | entitlements file and its fitness test, `release-sign.sh`/`release.sh`/`make-cask.sh`, `publish.sh` as the one road to a GitHub release, [`releasing.md`](../releasing.md) | shipped (T-114), proved end to end including a real notarization submission; the second release path a workflow used to run was deleted in T-128 after run 31418387621 showed it had never once worked |
| 040 and NFR-012 | `scripts/internal/ghostty.terminfo`, `install_terminfo`/`terminfo_entry_body` in `setup-ghostty.sh`, their tests in `setup-ghostty.test.sh` | shipped (T-117); the generated project's last machine-local input became reproducible, which is what had been failing CI and would have failed the first tagged release |
| 040 and NFR-012 | `scripts/internal/setup-xcodegen.sh` + `scripts/internal/setup-xcodegen.test.sh`, the generator call sites in `install.sh`/`release.sh`/`macos-ci.yml`, `project.yml`'s pinned version | shipped (T-118); the generator itself was the remaining unpinned build input, and `brew install` had already moved it out from under the committed project |
| 041…043 and NFR-009 | `tenon`, the five `scripts/*.sh` verbs and their `# tenon:` metadata, `scripts/internal/`, `scripts/publish.sh` as the only caller of `gh release create`, and `ScriptSurfaceFitnessTests` | shipped (T-128); the script layer had fourteen executables with no rule saying which were typed, and two of them published the same tag |

Risks are testing mocks instead of boundaries, flaky XCUITest sprawl, pixel snapshots tied to OS/font
noise, inaccessible test-only selectors, vacuous assertions, stale manifests, over-tagging, and
refactors that change behavior under cover of file moves. Lowest-valid-layer routing, narrow adapter
receipts, semantic identifiers, mutation, current manifests, two-step domain retrieval, and behavior-
preserving decompositions mitigate them.

Decisions: `swift test` is the headless bar; exclusions must earn a documented reason; test counts
do not belong in durable docs; facts beat sleeps; retries diagnose only; pixels/accessibility/
performance are separate truths; domain tags narrow but never complete retrieval; cache pruning must
respect concurrent agents; accessibility/localization are architecture quality; T-090 remains
planned rather than being implied by existing UI tests.

## 7. Verification receipts and change history

| Date | Evidence | Result |
|---|---|---|
| T-023 | measured build storage | duplicate 7.0 GiB tree reduced to shared ~3.8 GiB state; pruner idempotent/concurrency-safe |
| T-043/T-074/T-082 | runner/mutation/flake/domain receipts | dead test directory repaired; timing rules made fact-based; five domain-gate mutations fired |
| 2026-08-07 | system audit | historical build and 1,379-test receipt green; not a current frozen count |
| 2026-08-09 | documentation audit | current quality sources/tasks mapped; T-090 remains pending |
| 2026-08-10 (T-114) | `swift test` after adding `AppSigningFitnessTests` | 1872 / 0; four assertions red first against a missing entitlements file, then green |
| 2026-08-10 (T-114) | ad-hoc + `--options runtime` on the real bundle | app fails in dyld: embedded frameworks rejected, "mapping process and mapped file (non-platform) have different Team IDs". Hardened Runtime and ad-hoc are mutually exclusive here; the local install path stays unhardened (ENQ-FR-037) |
| 2026-08-10 (T-114) | Developer ID signature, `release-sign.sh`, then `TENON_VIEW_SNAPSHOT` over the bundled Kanban plugin | `flags=0x10000(runtime)`, `allow-jit` attached, plugin JavaScript rendered byte-identical to the unhardened control |
| 2026-08-10 (T-114) | one probe binary signed twice, differing only in the runtime flag | `libproc` results identical (638 pids; 419 readable; 219 EPERM; 635 paths) — closes PRD-016's signed-app feasibility question |
| 2026-08-10 (T-114) | first real notarization submission, `9599ec16-d60a-4e7a-b6ad-d43bbfe981ef` | `status: Accepted` for the universal 0.1.0 archive; ticket stapled; a copy extracted back out of the published zip assessed `accepted / source=Notarized Developer ID`. Nothing in the entitlement set or signing shape had to change to pass |
| 2026-08-10 (T-114) | `CODE_SIGNING_REQUIRED=NO` Release build | no `codesign` step runs at all, so `ENABLE_HARDENED_RUNTIME` has no effect and the `flags=0x2(adhoc)` present comes from the linker; the signing script, not the build setting, is the authority for a distributed artifact |
| 2026-08-11 (T-120) | `ENQ-FR-017` — the four `TabStripReorderTests` gestures that failed four of five CI runs, repaired at their seam rather than rerun | not a flake and not load: `NSWindow.sendEvent` dispatches only for a window on the window server's on-screen list, and a runner with no display session never puts one there. Measured off that list — `windowNumber` assigned, `event.window` resolving, the frame view hit-testing to `TabStripSurface.SurfaceView`, `mouseDown:` never called. Holding every window in the file off that list reproduces exactly the four CI failures and leaves the other twelve green; routing the press through the window's own hit test makes all seventeen pass in both states, and `testAPressLandsOnTheChipInAWindowTheServerNeverPutOnScreen` keeps the runner's condition asserted on every machine |
| 2026-08-11 (T-117) | shipped `Resources/terminfo` compared against `src/terminfo/ghostty.zig` at the pinned tag | capability sets equal at 268 each, none missing and none extra — the untracked directory really did hold the pinned Ghostty's entry, so committing it as source text preserved rather than guessed at the entry |
| 2026-08-11 (T-117) | `tic -x` over the decompiled source | reproduces `67/ghostty` and `78/xterm-ghostty` byte-identically, so compiling at setup time is lossless and the committed text is the shipped artifact in reviewable form |
| 2026-08-11 (T-117) | clean room: whole tree copied without `Resources/`, `GhosttyKit.xcframework` or the synced header, then `setup-ghosttykit.sh` + `xcodegen generate` | both succeed and the compiled terminfo is byte-identical to the copy shipped in 0.1.0 — the sequence that had failed on every CI run since 2026-08-07 |
| 2026-08-11 (T-117) | `setup-ghosttykit.sh` run against a tree whose GhosttyKit is installed and verified | prints "already set up and verified" and still rebuilds the missing terminfo, which is the case the early return had been hiding |
| 2026-08-11 (T-118) | the 2.46.0 the runner had poured, run over the unchanged spec | 21-line project diff: targets reordered, plus an Embed Frameworks phase copying `TenonIntentCore.framework`. `otool -L` on the shipped 0.1.0 binary and on `TenonCore` names only TenonCore, OrderedCollections and JSONSchema — nothing loads that framework, so the newer generator would ship a fourth one and change the artifact Apple notarized. The pin stayed at 2.45.4 on that evidence rather than on age |
| 2026-08-11 (T-118) | `setup-xcodegen.sh` from a tree with no `.build/tools`, then the CI sequence | installs 2.45.4 against its recorded checksum, and `xcodegen generate` + `git diff --exit-code -- Tenon.xcodeproj` passes — the check that had failed since the generator moved |
| 2026-08-11 (T-118) | mutation: pinned checksum replaced with zeros | `setup-xcodegen.test.sh` turns red naming both digests, and green again when restored — the pin is asserted against the published release rather than trusted |
| 2026-08-11 (T-128) | `swift test --filter 'ScriptSurfaceFitnessTests\|testInstallChannelsKeepSingletonAndDurableStateIsolationClosed'`, written before the fixes | 5 executed, 6 failures across all four new cases: the root held **zero** executables (not one), `scripts/icon.sh` had no `# tenon:` line so `./tenon` printed it under "other" with an empty description, `.github/workflows/release.yml` and `scripts/publish.sh` both matched `gh release create`, and 37 stale script paths were named across 13 documents, workflows and script comments. The same filter after the fixes: 5 executed, 0 failures |
| 2026-08-11 (T-128) | `.github/workflows/macos-ci.yml` read against the tree | six steps named four scripts that no longer existed (`scripts/setup-xcodegen.sh`, `scripts/setup-ghosttykit.sh`, `scripts/test-setup-ghosttykit.sh`, `scripts/test-setup-xcodegen.sh`), so CI would have failed on the next push for the rename rather than for any change under review. `ENQ-FR-043` exists because that class of breakage is invisible to the compiler and to review |
| 2026-08-11 (T-128) | `scripts/internal/setup-ghostty.test.sh` and `scripts/internal/setup-xcodegen.test.sh` from their new home | "setup-ghostty integrity tests passed" rc=0; "setup-xcodegen pin tests passed" rc=0 |
| 2026-08-11 (T-128) | `./tenon` and `./tenon nosuchverb` | usage lists five verbs under `everyday`/`release`/`upkeep`, each with the description read out of its own script, exit 0; an unknown verb prints the same list to stderr and exits 2 |
| 2026-08-11 (T-128) | run `31418387621` (tag v0.1.0), recorded in the task file by the session that read it; not re-read before the deletion | died importing the certificate with `CERTIFICATE_P12:` and `CERTIFICATE_PASSWORD:` empty in its own env dump — `secrets.MACOS_CERTIFICATE_P12` was never set, so the CI road had never produced a release and the shipped 0.1.0 came off the local one. The deleted workflow remains recoverable from git history |

Initial canonical PRD created 2026-08-09.
