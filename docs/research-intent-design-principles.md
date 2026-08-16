# Research: what Linux, Android, and Orca teach about intent design

**Date:** 2026-08-14

**Status:** research, non-normative. `architecture-interaction-boundaries.md` remains the
law for mechanism selection and `design-intent-bus.md` the kernel specification. This
document records the external evidence that the law's shape is independently confirmed,
derives the one principle that evidence supports, and names the deltas the study surfaced.
`design-intent-bus.md` already studied Android, D-Bus, Web Intents, MCP, App Intents,
VS Code, and Fuchsia before the kernel was designed; this study adds the two bodies it did
not cover — Linux/Unix boundary discipline and the Orca checkout under `references/orca` —
and the dated Android hardening timeline with primary sources.

**Confidence labels:** `HIGH` means a fetched primary source or a `file:line` in a tree on
this machine. `MEDIUM` means consistent secondary sources or static analysis that could
miss dynamic cases.

**Companion:** [`reports/2026-08-14-core-intent-catalog-evaluation.md`](reports/2026-08-14-core-intent-catalog-evaluation.md)
evaluates all 51 core intents against the principle derived here.

## Research question

Three mature systems solved "one party asks another to do something across a trust
boundary" at scale: Unix/Linux (52 years), Android Intents (17 years), and Orca (a current
competitor whose CLI surface Tenon already surveyed). What do their trajectories agree on,
and does the agreement confirm or correct Tenon's intent law?

## Conclusion — the legible boundary principle

**HIGH:** All three systems, under different pressures, converge on the same end state and
none ever moved in the opposite direction:

> **Pay the boundary cost exactly where trust changes owner — and at that boundary,
> nothing crosses except a pre-declared, bounded, typed value in a closed vocabulary,
> refused when not understood, and never re-meant after it ships. In exchange, inside
> each boundary is absolute freedom.**

The load-bearing clause is the third one, and it is a mechanical fact before it is a
preference: **a boundary can only govern what it can read by value.** seccomp-bpf cannot
dereference pointers, which is precisely why it can filter `openat2(2)` and cannot filter
`ioctl(2)` — and why Android, ChromeOS, and Google production servers responded to io_uring
(60% of kCTF exploit submissions) by making it unreachable rather than by filtering it
([kernel seccomp docs](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html),
[Google oss-security 2023](https://www.openwall.com/lists/oss-security/2023/06/17/2)).
Every other clause follows: declaration before execution makes the surface enumerable so
policy can exist; the closed vocabulary is what keeps every operation inside the readable
set; refusal of the unknown keeps the set closed over time; boundary immutability is what
lets the interior stay free.

## The five clauses and their evidence

### 1. Place the boundary exactly where trust changes owner

- **HIGH:** ComDroid (MobiSys 2011) found 34 vulnerabilities in 12 of 20 apps and named the
  root cause: "Most of these vulnerabilities stem from the fact that Intents can be used
  for both intra- and inter-application communication" — one mechanism serving two trust
  contexts ([paper](https://people.eecs.berkeley.edu/~daw/papers/intents-mobisys11.pdf)).
  Android finished separating them only at API 34 ("implicit intents are only delivered to
  exported components").
- **HIGH:** The opposite failure — no real boundary at all — is Orca's CLI/agent surface: a
  24-byte bearer token opens all 552 RPC methods
  (`references/orca/src/main/runtime/runtime-rpc.ts:497,1598-1601` @ `346e59c879`), and the
  only modeled principal is a hand-written 259-method mobile allowlist.
- Tenon's founding premise states both refusals at once: boundary cost is paid "exactly
  where the boundary creates isolation, authority, public discovery, provider selection, or
  lifecycle value" (`architecture-interaction-boundaries.md`, "Why not every finite
  operation is an intent").

### 2. Declare before executing

- **HIGH:** Android's intent filter is a manifest expression the system can match, display,
  and police before any app code runs
  ([intents-filters](https://developer.android.com/guide/components/intents-filters));
  OpenBSD's `pledge(2)` has the process "declare which subsystems it will need in the
  future", violations killed with an uncatchable SIGABRT, and narrowing is monotonic —
  revoked promises cannot be re-activated ([man page](https://man.openbsd.org/pledge.2)).
- **HIGH:** When Orca had to open a surface to third parties, it independently converged on
  exactly this: `orca-plugin.json` declares from a closed set of 7 capability kinds, where
  "a typo (or a capability from a newer Orca) fails manifest validation instead of silently
  granting nothing" (`references/orca/src/shared/plugins/plugin-capabilities.ts:10-23`).
  The convergence is the strongest single confirmation in this study: Orca applies Tenon's
  model wherever it faces an untrusted caller, and only there.

### 3. Only bounded, typed values cross — because policy reads values

- **HIGH:** Android's untyped `Bundle` extras produced three distinct defect classes —
  intent redirection via nested serialized intents, deserialization type confusion
  (CVE-2021-0928), and receiver-side `RuntimeException` for missing classes — and every fix
  added type and validation at the boundary, ending with `getParcelableExtra(String,
  Class<T>)` at API 33
  ([intent-redirection](https://developer.android.com/privacy-and-security/risks/intent-redirection),
  [unsafe-deserialization](https://developer.android.com/privacy-and-security/risks/unsafe-deserialization)).
- **HIGH:** A bound that does not fail closed is not a bound: Binder's 1MB transaction
  buffer only became effective when exceeding it threw `TransactionTooLargeException`
  (API 24) instead of logging a warning
  ([parcelables-and-bundles](https://developer.android.com/guide/components/activities/parcelables-and-bundles)).

### 4. Closed vocabulary; refuse what you do not understand

- **HIGH:** `openat(2)` is "possibly the most famous counter-example to the mantra 'don't
  silently accept garbage from userspace'"; `openat2(2)` exists to reject unknown flags and
  version its argument by `sizeof(struct open_how)`
  ([LWN](https://lwn.net/Articles/803237/), [man page](https://man7.org/linux/man-pages/man2/openat2.2.html)).
  Kernel policy for every new syscall: reject unknown flags with `EINVAL`
  ([adding-syscalls](https://www.kernel.org/doc/html/latest/process/adding-syscalls.html)).
- **HIGH:** The alternative to a vocabulary is an escape hatch, and both generations of the
  Linux escape hatch condemned themselves: the kernel's own docs call `ioctl` "a somewhat
  opaque API" and had to publish "Botching up ioctls" ("you'll be stuck with a given ioctl
  essentially forever"); io_uring's fate is §Conclusion above.
- **HIGH:** Plan 9 states why one noun and a closed verb set beats per-operation invention:
  in an object-style model, naming, protection, and access "must be faced anew for every
  class of object" ([Plan 9 paper](https://9p.io/sys/doc/9.html)). Ritchie & Thompson's
  original threefold advantage of "everything is a file" is substitutability, not
  simplicity — late binding achieved by a uniform noun instead of a resolver
  ([CACM 1974](https://people.eecs.berkeley.edu/~brewer/cs262/unix.pdf)).

### 5. The boundary never re-means; the interior stays free

- **HIGH:** "A new system call forms part of the API of the kernel, and has to be supported
  indefinitely" — while `stable-api-nonsense.rst` keeps *internal* interfaces deliberately
  unstable so that a security flaw can be fixed by reworking the interface, which "is
  impossible if you have to support the old interface forever"
  ([stable-api-nonsense](https://www.kernel.org/doc/html/latest/process/stable-api-nonsense.html)).
  The narrow frozen boundary is what buys the free interior; this repository's "nothing is
  grandfathered" rule is the same trade.
- **MEDIUM:** The incident that produced "WE DO NOT BREAK USERSPACE" (LKML 2012-12-23) was
  an error code changing from `EINVAL` to `ENOENT` — the contract includes the shape of
  failure, not only the shape of success. (Secondary sources; the original mail was not
  fetchable.)

## The Android hardening timeline — thirteen years, one direction

**HIGH**, all rows from developer.android.com behavior-changes pages:

| API | Change | Stated reason |
|---|---|---|
| 21 | implicit intents refused for `Service` | "you can't be certain what service will respond" |
| 26 | manifest receivers refused for implicit broadcasts | resource stampede across all registered apps |
| 30 | package visibility filtered by default; `<queries>` required | enumeration is itself a capability |
| 31 | `android:exported` must be declared or the app does not install; `PendingIntent` mutability must be declared | "'exported by accident' is the root of a vulnerability class" |
| 34 | implicit intents delivered only to exported components; mutable `PendingIntent` without a component throws | "prevent malicious apps from intercepting implicit intents" |
| 16 (2025) | intent-redirection hardening on by default | opt out is an explicit API call |

No release ever widened implicit resolution. The direction of thirteen years of patches is
the strongest empirical argument that starting closed — as Tenon's catalog does — is
cheaper than closing later.

## Orca as a natural experiment

`references/orca` @ `346e59c879` (2026-08-12), full report in the session record; counts
verified by grep against that tree. **HIGH** unless noted.

- **Syntax discipline without authority discipline.** 228 canonical commands with a
  spec-table the CLI serializes for agents (`orca agent-context --json`), a vocabulary
  policy enforced by CI ("predictable verbs prevent failed agent guesses",
  `src/cli/vocabulary-policy.ts:3-4`) — and no declaration anywhere of who may call what.
  Discoverability is a product; authority is a bearer token.
- **The convergence.** `PLUGIN_HOST_API_V0` is a separately versioned facade of 13 methods,
  each carrying `capability`, `panel` audience, `mutation` audit, and params *and result*
  schemas, because the raw RPC registry has "no result schemas and evolve[s] at internal
  velocity" (`src/shared/plugins/plugin-host-api.ts:8-10`). Deny-by-default pure gate,
  consent by canonical fingerprint, stale consent indistinguishable from denial. Where the
  caller is untrusted, Orca rebuilt Tenon's model.
- **The cost of no principal.** Worker authority is distributed by injecting a `dcap_`
  token into the worker's PTY preamble (`src/main/runtime/rpc/methods/orchestration.ts:1319-1343`) —
  the credential lives in scrollback (**MEDIUM**: no `dcap_` redaction found). Tenon's
  `agent.ask.v1` is the inverse answer: a typed value returned to the caller, nothing
  written into any terminal.
- **What a version number does not protect.** `RUNTIME_PROTOCOL_VERSION` is 3 after years
  of change, deliberately; the real protection is ~34 named capability strings
  (`<domain>.<feature>.vN`) advertised at handshake plus a cross-version e2e test that runs
  current and last-release builds against each other in both skew directions
  (`docs/reference/remote-wire-compatibility.md`, which also states its own coverage is
  terminal-stream only).
- **Two public paths, measured.** 715 `ipcMain.handle` registrations beside 552 RPC methods
  funnel into one 37,800-line runtime service — the empirical picture of what invariant 6
  ("one typed semantic implementation") prevents.
- **A vocabulary lesson Tenon can take without taking orchestration.** Orca's worker verbs
  separate `stop` (fence + kill), `abandon` (fence, does not claim stopped, keeps
  resources), `release` (clean up after settled), `retain` (durable exception), and report
  terminal-state separately from task status because "a completed Task can still own a live
  terminal". That is attention-state honesty, relevant to the Attention Inbox vocabulary.

## What this study changes

The law needs no correction: every clause above is already load-bearing in
`architecture-interaction-boundaries.md` and `design-intent-bus.md`, several stated more
precisely there than in any surveyed system (the six-condition authorization conjunction,
the no-chooser kernel, versioned names from first release). Three deltas surfaced, each
routed to the board rather than tracked here:

1. **Cross-version skew evidence for the CLI socket** (Orca's capability-advertisement +
   two-way skew test; a protocol number alone protects nothing) — T-165.
2. **State that the condition→error-code mapping is contract**, not only the declared error
   list (the `EINVAL`→`ENOENT` lesson; `design-intent-bus.md`'s same-major table governs
   the list but does not say the mapping is frozen) — T-166.
3. **`clipboard.write.v1` carries no capability binding** — found by the companion
   evaluation, not by this study — T-164.
