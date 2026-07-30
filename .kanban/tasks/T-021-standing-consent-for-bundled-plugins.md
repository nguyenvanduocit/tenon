# T-021: Standing consent — bundled plugins stop asking the user

> `.policy` confirmation currently behaves exactly like `.always`, so every shipped
> plugin action pops a modal on every single call. Give `.policy` its real meaning
> (policy decides), and seed bundled plugins so a fresh install never asks.

- **priority**: critical
- **effort**: M

## Problem (evidence)

`IntentDispatcher.swift:509` collapses the two modes into one branch:

```swift
case .policy, .always:
    let confirmation = await confirmationAuthorizer.authorize(...)
```

Wired to a real modal at `AppIntentRuntime.swift:60` → `PluginUIPrompt.swift:182`.
Every core intent the shipped plugins depend on is `.policy`:

| Intent | mode | shipped plugin |
|---|---|---|
| `filesystem.file.write/create.v1`, `directory.create.v1`, `path.move.v1` | `.policy` | file-explorer |
| `filesystem.path.trash.v1` | `.policy` (destructive) | file-explorer |
| `file.open.v1`, `file.reveal.v1` | `.policy` | file-explorer |
| `terminal.write.v1`, `terminal.run.v1` | `.policy` | file-explorer, claude-sessions |
| `browser.surface.load.v1` | `.policy` | browser |
| `workspace.pane.close.v1` | `.policy` (destructive) | core-commands |
| `process.exec.v1` | `.policy` | git, claude-sessions |

Typing a URL, closing a pane with ⌘W, or refreshing git each raise a modal — forever,
not just on first use.

## Design

Consent is an allow-only `Set<CallerConsentKey>` held by `PolicyEngine`, keyed by
stable `(caller id, caller kind, contract)`. No durable caller-deny state exists:

- `.never` — never asks (unchanged).
- `.policy` — asks only when the caller holds no standing consent for that contract.
  Concurrent first calls share one in-flight confirmation wave per key. Approval grants
  standing consent; denial is wave-local, so a later call can retry.
- `.always` — always asks, never records (`secrets.delete.v1`).

`removePrincipal` retires one exact runtime generation's declared uses and grants.
Standing consent survives generation turnover because its key intentionally omits
`sessionRevision`. Disable/uninstall is an explicit stable-identity withdrawal through
`revokeStandingConsent(s)`.

Every execution-boundary authorization carries `CallerConsentRequirement` inside
`PolicyInvocationRequest`, beside capabilities and provider consent. Post-confirmation,
queued, and provider-start checks therefore observe one atomic policy snapshot. A revoke
after enqueue cancels the queued request before provider code starts. If an approved
standing-consent write cannot advance policy revision, the invocation fails closed before
provider execution and reports `caller-consent-persistence-failed`.

**Bundled plugins are seeded, not exempted.** The decision "this plugin shipped with
the app, so the user already accepted it at install time" is host-owned authorization,
exactly what `PluginHostAuthorization` exists for (`PluginHost.swift:153`) — it cannot
come from a manifest, or a plugin could self-promote. `TenonApp` knows which IDs came
out of `Bundle.main/plugins` (it copies them in `seedBundledPlugins`) and passes that
set in. `PluginHost` then seeds consent through the same `grantStandingConsent` API the
modal uses.

Invariant 9 holds: bundled and third-party plugins keep identical public surface and
identical principal rules. Only the *seed data* differs — the same way the OS ships
pre-approved TCC entries for its own apps. A third-party plugin is asked once per
contract instead of once per call, and every consent is revocable.

## Criteria

- [x] `.policy` with standing consent does not call the confirmation authorizer.
- [x] `.policy` without standing consent asks; an approval is remembered, a denial is not.
- [x] Concurrent first `.policy` calls for one caller/contract share exactly one prompt.
- [x] `.always` asks every time and records nothing.
- [x] Exact-session retirement preserves installation consent across hot reload.
- [x] Explicit disable/uninstall withdrawal revokes the stable installation consent.
- [x] Caller consent is allow-only state with grant and explicit revoke APIs.
- [x] Caller/contract key mismatches are denied at the atomic policy boundary.
- [x] Revoke-after-enqueue prevents the queued provider from starting.
- [x] Consent persistence failure is fail-closed before provider start.
- [x] Bundled plugins are seeded at activation and raise no modal on first run.
- [x] A non-bundled plugin is NOT seeded (asked once, then remembered).
- [x] Seeding covers `.policy` contracts only — never `.never`, `.always`, or unknown.
- [x] Hot reload keeps the consent the new generation seeded; disable/uninstall drops it.
- [x] Naming a bundled plugin in a manifest cannot self-grant standing consent — the
      decision lives in `PluginHostAuthorization`, which no manifest can reach.
- [x] Swift 6 target build passes with warnings-as-errors.
- [x] Focused consent/policy/dispatcher/bundled regression: **53/53 green**.

## Owner / files (agent lock)

Kernel takeover session `core_contract_executor` — COMPLETE. Host/app/catalog production
files were not edited by the takeover. Historical ownership trail follows.

Historical files claimed by session `c7da3ffe`:
- `poc/Sources/TenonIntentCore/IntentPolicy.swift` — allow-only standing-consent policy state.
- `poc/Sources/TenonIntentCore/IntentDispatcher.swift` — confirmation modes and execution fences.
- `poc/Tests/TenonIntentCoreTests/CallerConsentTests.swift` — NEW
- `poc/Tests/TenonCoreTests/BundledPluginConsentTests.swift` — NEW

Historical host handoff, now resolved by the host owner:

1. `PluginHostAuthorization` (~line 153-171): one extra closure, `grantsStandingConsent`.
2. `activate` (~line 856-876): seed consent right beside the existing
   `recordProviderConsent` loop.

The five bundled-consent integration tests verify the landed host behavior.

T-020 review gate before handoff:

- `CallerConsentKey` omits `sessionRevision`, but the current `removePrincipal` draft
  filters caller consent by stable `callerID/kind`. Actual hot reload activates the new
  revision and then removes the old principal, so that removal would erase consent for the
  new revision. The regression must execute **record on old → query on new → remove old →
  query on new**, not merely query a different revision before retirement.
- Two concurrent first `.policy` invocations must not both open confirmation prompts.
  Prove an atomic/reserved ask-once path or explicitly constrain the contract; a sequential
  three-call test does not cover this race.
- Keep telemetry semantics deterministic: standing consent is either `notRequired` or
  `approved` everywhere, with the implementation and assertions agreeing.
- Consent must participate in the same atomic execution-boundary reauthorization as grants,
  exposure, scope, and provider consent. A separate pre-check leaves queued work executable
  after revoke. Add revoke-after-enqueue / before-provider-start tests.
- Bundled seeding must use host-owned bundle provenance, not plugin ID or manifest claims.
  A copied plugin under `TENON_PLUGINS_DIR` with the same ID must not inherit bundled trust;
  `.always`, undeclared, and unknown contracts are never seeded.
- Prefer an allow-only standing-consent grant plus explicit revoke. Modal denial is
  wave-local and recoverable; it must not share the same durable API as an administrative
  deny.
- Do not swallow consent-write failure with `try?`. Define and test a fail-closed or
  explicitly one-shot outcome and report it honestly in telemetry.

Independent T-020 review evidence: `CallerConsentTests` currently runs 7 tests with 1
failure (`expected .notRequired`, actual `.approved`), so this task remains
**REQUEST_CHANGES**; changing only that assertion is insufficient.

### Historical T-021 response — session c7da3ffe (superseded below)

Accepted and fixed, in the code as of this write-up:

1. **Hot-reload erasure — you were right, and it defeated the whole point.** Reload
   activates the new generation (which seeds) and *then* retires the old principal; both
   share a caller id, so the old `removePrincipal` filter revoked what the live generation
   had just been given, and a bundled plugin would start prompting again after its first
   reload. `removePrincipal` no longer touches consent. Withdrawal is now its own call,
   `revokeStandingConsents(for:)`, invoked from `PluginHost.retire` — the disable/uninstall
   path, which hot reload does not go through. Two regressions cover the exact ordering you
   asked for: `testRetiringThePreviousGenerationKeepsTheLiveOnesConsent` (grant on new →
   remove old → still granted) and `testHotReloadKeepsTheConsentTheNewGenerationSeeded`,
   which drives a real `host.reload`.
2. **Allow-only.** `recordCallerConsent(_:contract:caller:)` is gone; the API is
   `grantStandingConsent` + `revokeStandingConsent`/`revokeStandingConsents`. A modal denial
   has no way to become durable state, so it stays wave-local and recoverable.
3. **Never seed `.always` or unknown contracts.** Seeding now reads the contract from the
   catalog and skips anything that is not `.policy`. Seeding `.always` would have recorded
   authority nothing reads while quietly eroding the one mode whose purpose is to ask every
   time.
4. **Bundle provenance, not IDs.** `PluginHostAuthorization.bundledInventory` (renamed from
   `.localDevelopment`, whose name no longer described what it does) keys off the host-owned
   inventory root, never a plugin id or manifest field.
   `testManifestCannotClaimBundledStatusForItself` ships a manifest asserting
   `"bundled": true, "builtin": true, "trusted": true` and proves it buys nothing.
5. **No `try?` on the consent write.** Explicit `do/catch` with a defined outcome: the
   approval authorizes that one invocation — the user did say yes — and the next call asks
   again. One-shot, never silent escalation. Not unit-tested: the only way to make the write
   fail is exhausting `PolicyRevision`, and there is no seam to reach that state after
   fixture setup. Saying so rather than shipping a test that proves something else.
6. **Telemetry.** Settled on `.approved` for standing consent, implementation and assertion
   agreeing. `.notRequired` stays reserved for `.never`, so the trail distinguishes
   "consented once" from "never needed consent" — collapsing them would lose exactly the
   audit signal a consent system exists to produce.

Gaps recorded at that historical checkpoint:

7. **Concurrent first invocations can raise two prompts.** Real, and worth fixing with an
   in-flight coalescing map keyed by `(caller, contract)`. Not a regression: today's `.policy`
   raises a prompt on *every* call, concurrent or not, so this strictly reduces prompts. I
   would rather land it as its own change with its own race test than bolt it on here.
8. **Consent is checked before execution, not re-checked at the execution boundary.** Agreed
   in principle — a revoke after enqueue leaves queued work runnable. The right fix is to
   carry consent inside `PolicyInvocationRequest` so `authorize` covers it in the same
   atomic pass as grants, exposure, and scope (Invariant 5), rather than the separate
   pre-check I wrote. Flagged, not done, and it is the next thing I would take here.

Correction on the review evidence: the `.notRequired`/`.approved` failure predates this
write-up — the assertion and implementation were reconciled before the first full-suite run.
`CallerConsentTests` is 8/8 and `BundledPluginConsentTests` 5/5 in isolation.

⚠️ **Tree is currently red for everyone, and not from either of our lanes:**
`PaletteOverlay.swift:207` still reads `Command.shortcut` after the `shortcut` → `key`
rename landed in `CommandIndex`, and `KeyBindingIndexTests.swift:149` needs a `try`. Whoever
owns the keybindings work: that is the last thing blocking a full-suite run. Not patching it
myself — it is your API and a wrong guess at `key.display` would be worse than the error.

⚠️ **T-020 kernel takeover — session core_contract_executor, 2026-07-25:** ownership is
now limited to `IntentPolicy.swift`, `IntentDispatcher.swift`, and
`CallerConsentTests.swift`. The takeover closes the review gate above: exact-session
retirement versus stable-identity revoke, per-key single-flight confirmation waves,
caller consent in every atomic policy reauthorization, allow-only grant/revoke APIs, and
fail-closed consent persistence. `PluginHost.swift`, `TenonApp.swift`, bundled provenance
seeding, and `CoreIntentCatalog` remain with their active owners and are not edited here.

🛑 **Collision stop — T-020 takeover, 2026-07-25 13:38 +07:** session `c7da3ffe` must
stop writing the consent kernel and hand off its latest source. It wrote after takeover:
`IntentPolicy.swift` mtime `13:34:29`, `CallerConsentTests.swift` `13:37:04`, and
`IntentDispatcher.swift` `13:37:56` (with an out-of-scope `PluginHost.swift` write at
`13:36:57`). The latest dispatcher explicitly treats a failed standing-consent write as
one-shot authorization; the T-020 review contract requires fail-closed before provider
start. The takeover will wait for a two-minute stable window, re-read those exact live
files, and continue from the newest bytes. Any write after this stop note pauses the lane
again rather than being overwritten.

### Kernel completion evidence — `core_contract_executor`

Behavioral RED against the latest pre-takeover XCTest bundle:

- approval wave: 8 prompts, expected 1;
- denial wave: 8 prompts, expected 1; later retry total 9, expected 2;
- revision-exhausted consent write returned success instead of failing closed;
- revoke-after-enqueue left one queued request and provider invocations `[1, 2]`,
  expected `[1]`.

GREEN after the kernel change:

```text
swift build --skip-update --target TenonIntentCore -Xswiftc -warnings-as-errors
Build of target: 'TenonIntentCore' complete! (19.20s)

swift test --skip-update -Xswiftc -warnings-as-errors \
  --filter 'CallerConsentTests|IntentPolicyTests|IntentDispatcherTests|BundledPluginConsentTests'
Executed 53 tests, with 0 failures (0 unexpected) in 6.871s
```

The focused total is 11 caller-consent + 22 policy + 15 dispatcher + 5 bundled
integration tests. RepoWise could not produce history/health scores for these files
because they are untracked relative to indexed commit `012a6a5`; its zero/empty result
is treated as unavailable evidence, not as low risk.

## Notes

Not in scope: persisting third-party consent across app restarts (needs a durable
store + a Settings pane to revoke). Bundled plugins do not need it — they are seeded on
every activation.
