# Tenon system and documentation review

**Reviewed:** 2026-08-07
**Scope:** live workspace, Swift host/runtime, CLI transport, plugin boundary, shipped plugins, CI/install path, and project documentation
**Status:** local actionable findings remediated; two structural runtime risks remain and require an isolation redesign

## Executive summary

The repository is substantially healthier than at the start of this review. Startup work no
longer blocks the UI actor, the CLI singleton and client transport are hardened, plugin trust
is explicit, diff rendering and network classification are bounded, public interaction
inventory matches the normative boundary law, and the primary SwiftUI accessibility and
cancellation defects are fixed.

The staged-write blocker was resolved by deleting the stateful cursor protocol. The canonical
`filesystem.file.write.v1` contract is now one bounded, atomic, finite request/reply. A large
write must not return until a separately inventoried RESOURCE protocol exists.

The current tree builds and the complete Swift package suite passes: **1,379 tests, 0
failures**.

This is not an unconditional security sign-off. JavaScriptCore still executes trusted plugin
code in the app process, and the legacy `tenon.process.stream` implementation still owns a
Foundation `Process` leader rather than a race-free POSIX process group. Both require a
structural replacement, described below.

## Remediation status

| Area | Status | Result |
|---|---|---|
| Xcode/Swift integration | Fixed | Package access is supplied to Xcode; CI selects the required toolchain and treats Swift/Xcode warnings as errors. |
| Startup and actor isolation | Fixed | Filesystem discovery, hook setup, manifest parsing, persistence preload, and kernel preparation run off `MainActor`. |
| Diff resource bounds | Fixed | File and git reads are capped; pathological Myers inputs fail safely; projection runs off-main and stale generations cannot publish. |
| Stateful file-write cursor | Fixed by deletion | `filesystem.file.write.v1` accepts bounded inline content only and atomically replaces the target in one call. |
| Public interaction inventory | Fixed | Runtime paths, `tenon.events.emit`, audiences, `url.open.v1`, source inventory, docs, and fitness tests agree. |
| CLI singleton security | Fixed | Stable advisory claim, private owner-checked directory/socket, no-follow/type/mode checks, stale recovery, and bind/listen activation retry. |
| CLI availability | Fixed | A finite concurrent worker pool isolates slow readers; socket responses are written off the main thread with read/write timeouts. |
| CLI dependency boundary | Fixed | Wire protocol and action parsing live in `TenonIntentCore`; the shipped CLI no longer links the host core. |
| Plugin provenance | Fixed | New untrusted plugins start disabled; trust-class transitions rotate installation identity and do not inherit consent. |
| Plugin async ownership | Fixed | Generation-owned host operations use a bounded task ledger and are cancelled and joined during shutdown; log delivery is bounded. |
| Network endpoint policy | Fixed | IPv4/IPv6 special-use, mapped, compatible, NAT64, benchmark, documentation, ULA, link-local, multicast, and transition ranges fail closed. |
| SwiftUI interaction/accessibility | Fixed | Palette and prompt rows are native buttons; selection traits and Reduce Motion are respected. |
| Image and web preview lifecycle | Fixed | Decode results are identity/cancellation guarded; web reload is path-gated; local HTML blocks remote subresources. |
| Agent Markdown | Fixed | Block parsing is cached in view state and performed off-main for each source revision. |
| Hook/socket races | Fixed | Agent hook listener state uses synchronized descriptor exchange; mailbox regression tests release barriers before assertions. |
| Ghostty supply chain | Fixed | Archive, library, header, and resource hashes are pinned; extraction is validated and install staging rolls back safely. |
| Documentation | Updated | Architecture law, CLI/intent/plugin/open-handler designs, operations, author guide, migration guide, README indexes, and TDD status describe the current system. |

## Remaining structural risks

### High — JavaScriptCore is not a hard sandbox

`PluginRuntime` uses one JavaScriptCore VM/context per plugin on a pinned thread, with bounded
mailboxes and runtime-owned asynchronous work. Those controls bound bridge traffic, not CPU or
heap inside a JavaScript evaluation. Apple's public JavaScriptCore API used by this project
does not provide a reliable per-context hard CPU and memory limit.

A complete fix requires executing plugins in a supervised helper process with OS resource
limits, a kill deadline, a bounded IPC protocol, and generation-scoped teardown. Until then,
only trusted/developer-trusted plugin code should be enabled; “plugin isolation” must not be
documented as a security sandbox.

### High — `tenon.process.stream` teardown is leader-scoped

The finite `process.exec.v1` provider already uses POSIX process-group ownership. The
plugin-private streaming resource still launches through Foundation `Process`; terminating
its leader can leave descendants alive. Calling `setpgid` after `Process.run()` is racy and
was deliberately not presented as a fix.

The replacement should launch with `posix_spawnattr_setpgroup` (or move streaming execution
to a supervised helper), retain the group identity as the resource, terminate TERM→KILL on
cancel/reload, drain bounded output, and join the group before generation retirement.

## Documentation status

The documentation set now has a usable entry point and separates normative architecture from
design notes and operations:

- `docs/architecture-interaction-boundaries.md` is normative for every public interaction.
- `docs/README.md` indexes architecture, product designs, plugin material, and operations.
- `docs/plugin-author-guide.md` and `docs/plugin-migration-v0.2.md` describe the current
  public plugin contract and migration path.
- `docs/operations.md` covers installation, state roots, plugin trust, CLI channels, and
  recovery.
- `docs/design-open-handlers.md`, `docs/design-cli.md`, and
  `docs/design-intent-bus.md` match the closed audience and provider-resolution model.
- README, VISION, TDD, command-palette, editor, agent-lens, and built-in-plugin docs were
  reconciled with shipped behavior.

The two runtime risks above are intentionally documented as limitations, not hidden behind
the word “sandbox.”

## Verification

- Full Swift package suite: **1,379 tests, 0 failures**.
- Architecture interaction fitness: **9 tests, 0 failures**.
- Focused catalog/Kanban/runtime/diff/CLI/consent verification: **94 tests, 0 failures**.
- Channel/state regression verification: **31 tests, 0 failures**.
- Xcode build and clean/incremental package builds passed during this remediation.
- Ghostty setup checksum/extraction tests and shell syntax checks passed.
- `git diff --check` passes.

The linker still prints two existing missing-debug-symbol warnings from Ghostty's vendored
static archive; they do not fail compilation or tests and are not Swift diagnostics.

## Merge recommendation

**Do not claim hard plugin sandboxing or process-tree containment in the current release.**
For a trusted-plugin deployment, the tree is test-green and the local blockers from this review
are remediated. For arbitrary third-party plugin execution, complete the helper-process and
POSIX process-group work first.
