# T-072: Resolving a handler is a question you can ask

> `resolveAndHold` decides *and* commits in one step, so nothing can find out who would
> serve a contract without also taking the right to run them. That is why
> `ambiguousProvider` throws where a person should have been asked, and why built-in UI
> cannot branch on the handler somebody chose.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)

**Released 2026-08-06 16:0x by session `cbf0f2c6`. All FREE**: `ProviderRegistry.swift`,
`IntentDispatcher.swift`, NEW `PluginOpenHandlerCandidacy.swift`,
`ProviderRegistryTests.swift`, NEW `AgentConsentScopeTests.swift`,
NEW `PluginOpenHandlerCandidacyTests.swift`.

The `palette` → `user` rename moved out to [T-073](T-073-the-principal-is-a-person-not-a-widget.md):
450 references across 58 files, and the tree had 12 files edited by another session inside
six minutes. A half-applied rename of a public audience takes everyone down.

## Why this first

Android separates `resolveActivity` (ask) from `startActivity` (run); Tenon fuses them.
Splitting them is what makes the rest possible:

- the host can ask **who would serve this** without holding authority to run a plugin —
  resolution is policy over host-owned state, and no plugin code executes;
- a trusted-default answer is served by the host's own typed implementation with no bus
  traffic at all;
- a plugin answer becomes an ordinary dispatch with `explicitTarget` naming that provider;
- two eligible handlers become a **chooser** instead of `ProviderResolutionError.ambiguousProvider`,
  and the person's answer is written through the `setConfiguredDefault` that already exists.

## Criteria

- [x] A query-only resolution returns the decision — `ProviderResolutionDecision` names the
      provider and why it won (explicit target, the person's configured default, the
      trusted default, a sole eligible one) or reports `.needsChoice` with sorted
      candidates, `.targetUnavailable`, or `.noProvider`.
- [x] The query holds nothing: `resolutionDecision(_:)` reserves no generation and takes no
      lease, asserted against the registry snapshot's selection and lease counts.
- [x] The query and the dispatch cannot disagree. `eligibleProviders(for:)` and `decide(...)`
      are the one rule; `resolveAndHold` switches on the same decision, and a test walks
      every outcome asserting the two paths agree.
- [x] Eligibility still filters on active lifecycle, health, and export — a quarantined
      chosen handler falls back to the built-in one.
- [x] An agent re-asks every time for a delegable contract.
      **The rule changed shape once measured**: `.policy` turned out to mean *standing
      consent keyed on `(caller, contract)`*, so one approval would let an agent open
      addresses silently forever — the actual injection risk. Narrowing by `external:` was
      wrong: that flag covers `terminal.write`, `process.exec`, and `network.fetch`, and
      confirming those every time makes an agent unusable rather than safer. The rule is
      keyed on the **contract class** instead: `IntentDispatcher.effectiveConfirmation`
      promotes `.policy` to `.always` only for an `open`-class contract asked by the `agent`
      audience — where the danger is the payload rather than the kind of operation.
- [x] `swift test` green — **1183 / 0** with the whole tree, including another session's
      concurrent work.

## Mutation proofs

- Deleting the configured-default rank from `decide(...)` reddens
  `testAskingWhoWouldServeReportsWhyAndHoldsNothing` **and** the pre-existing
  `testResolutionOrderIsExplicitConfiguredTrustedUniqueThenAmbiguous` — which is the
  evidence that the query and the dispatch really do share one rule rather than two that
  happen to agree. Restore verified byte-identical with `cmp`.

## Also landed here

`PluginOpenHandlerCandidacy` (+ 5 tests): declaring a delegable contract is an offer, not a
binding. Today a plugin binding an unapproved `open` contract throws
`openIntentNotApproved` and `PluginHost` marks the whole plugin failed — so the shipped
browser would go dark the moment it offered to handle addresses. Candidacy is product
state, not kernel state, so the kernel keeps its strict rule and the host simply does not
offer the binding until the approval exists; approval then re-stages through the reload
path that already exists. The host adoption belongs to whoever lands the approval surface.
