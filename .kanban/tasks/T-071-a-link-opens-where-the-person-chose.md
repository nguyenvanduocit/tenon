# T-071: A link opens where the person chose

> Tenon ships a browser, but a link clicked in Agent Lens always leaves for the system
> browser. The kernel already ranks a person's configured handler above the built-in one —
> built-in UI is the one caller that cannot ask it.

- **priority**: high
- **effort**: L

Design: `docs/design-open-handlers.md` (accepted). Read it before starting; it settles the
mechanism, the invariant amendment, and why this is built once rather than per-surface.

## Owner / files (agent lock)

Session `cbf0f2c6` released everything it held at 15:4x. **FREE**:
`CoreIntentCatalog.swift`, `SystemIntentProvider.swift`, `CoreIntentCatalogTests.swift`,
`InteractionBoundaryFitnessTests.swift`, `BrowserPluginTests.swift`,
`plugins/browser/manifest.json`, `plugins/browser/main.js`.

Held by the second session: `docs/design-open-handlers.md`, `IntentEnvelope.swift`,
`OpenHandlerAudienceTests.swift`, `AppIntentRuntime.swift`, and the remaining shell wiring.

## Shape

The person picks the handler; every caller resolves through that choice. Modelled on
Android's published action / declared handler / approval / chooser / remembered default,
almost all of which already exists in `TenonIntentCore` and has never been called.

`plugins/browser` is the first alternative handler and the mechanism knows nothing about
browsers.

## Two sessions, one task

Session `cbf0f2c6` built the contract, the trusted default, and the plugin side. A second
session concurrently rewrote `docs/design-open-handlers.md`, `IntentEnvelope.swift`, and
`OpenHandlerAudienceTests.swift` to reach the same product goal **without** a new
principal: built-in UI calls one typed opening service DIRECT and the intent adapters call
that same service. The user confirmed this is intentional, so that is the live design and
the criteria below follow it. The `ui`-principal approach is not part of this task.

## Criteria

- [x] **`url.open.v1`** as an `open` core contract over one bounded `http(s)` address,
      landed with its inventory, execution lane, schema shape, capability map, and the
      catalog inventory count in the same change (41 → 42).
- [x] **Trusted default** is the host's `NSWorkspace` opener —
      `SystemIntentProvider.openAddress`, which refuses anything that is not an absolute
      `http(s)` address with a host, and re-checks the resolved grant before opening, so
      removing every plugin leaves today's behaviour intact.
- [x] **`dev.tenon.browser` can be told where to go.** Its open intent takes an optional
      `url`; the address is parked for the pane that does not exist yet and consumed by the
      first `onOpen`, cleared whether the open succeeds or fails. Optional, so the palette
      entry that supplies no input still opens the home page.
- [ ] **One typed host opener service.** Built-in UI calls it DIRECT; provider adapters
      call the same service. Agent Lens' `.systemAction` fallback is removed so exactly one
      thing happens on a link click. *(second session)*
- [ ] **`dev.tenon.browser` provides `url.open.v1`.** Blocked until approval is real:
      `validatePluginBindings` throws `openIntentNotApproved` for a plugin binding an open
      contract that `approvedOpenIntentIDs` does not list, and `PluginHost` marks the whole
      plugin failed — declaring it today takes the shipped browser dark.
- [x] **Approval is real.** `OpenHandlerApprovals` persists a `(pluginID, intentID)` grant,
      and `TenonApp` hands it to both inventories in place of `{ _, _ in [] }`, scoped
      through `PluginOpenHandlerCandidacy.effectiveApprovals` so a grant for something never
      declared cannot reach the coordinator. **A bundled plugin gets nothing either**:
      shipping with the app is consent to *run* a plugin, not consent to let it see every
      address opened through it. `OpenHandlerOffer` carries the plugin's own name, because
      "let this open your links?" is unanswerable without knowing who "this" is. Revocation
      is immediate, and uninstalling drops every grant so a later plugin claiming the same
      id inherits nothing. 8 tests. *(Settings UI still to build.)*
- [ ] **Chooser and default.** Two qualifying handlers present a chooser instead of
      throwing `ambiguousProvider`; its "always" answer calls the existing
      `ProviderRegistry.setConfiguredDefault`. *(second session)*
- [ ] **Fails closed.** An unloaded, unhealthy, or quarantined handler falls back to the
      trusted default; a failing or slow handler surfaces visibly, never silently.
- [ ] **Extensibility proven, not asserted.** Adding a second openable kind costs one
      contract plus one trusted default. Demonstrate it or state why not.
- [x] `swift test` green — **1172 / 0** with both sessions' work in the tree.

## Open question the live design has not answered

When the person's chosen handler is a **plugin**, the typed host service still has to reach
it. The open contracts' audiences are `{plugin, cli, agent}`, so a `core`-principal caller
is refused by the single audience gate in `IntentPolicy.authorize`, and no principal exists
for built-in UI. Either the service needs an answer for that hop, or a chosen plugin
handler applies only to plugin/CLI/agent callers while an Agent Lens click keeps using the
trusted default — which contradicts this design's own rule that exactly one thing happens
when a person clicks a link. Raised here rather than resolved, because the second session
owns that decision.

## Already verified, do not re-derive

- `ProviderRegistry.resolveAndHold` ranks explicit target → `configuredDefaults` →
  `trustedDefault` → single eligible.
- `ProviderRegistry.setConfiguredDefault(_:for:)` exists and is covered by
  `ProviderRegistryTests`; no product surface calls it.
- `ProviderActivationCoordinator.validatePluginBindings` already admits a plugin binding to
  an `open`, core-owned contract exactly when `approvedOpenIntentIDs` contains it.
- `IntentPolicy.authorize` has a single audience gate driven by the contract's exposure.
- `IntentPrincipal.audience` is computed from `kind`, so audience spoofing is structurally
  impossible — keep it that way.
- `NSWorkspace` appears in `TenonApp` only inside `SystemIntentProvider`.
