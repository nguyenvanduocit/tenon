# Open handlers

**Status:** accepted; partially implemented (T-071) · **Reviewed:** 2026-08-06

## Decision

A person chooses which handler opens a thing, and every caller honours that choice —
including Tenon's own built-in UI. Clicking a link in Agent Lens opens it in the system
browser or in Tenon's browser pane because that is what the person picked, not because of
where the click happened.

The model is the one Android settled on: a **published action**, **handlers that declare
they serve it**, **an approval the person grants**, **a chooser when more than one
qualifies**, and **a remembered default** that any caller resolves through. Tenon already
has most of it, built and dormant.

This is not a browser feature. `plugins/browser` is the first planned alternative handler,
and nothing in the mechanism knows that.

## What Tenon already has

| Android | Tenon | State |
|---|---|---|
| `ACTION_VIEW` implicit intent | an `open`-class core contract | `file.open.v1` and `url.open.v1` |
| `<intent-filter>` | a plugin's `intents.provides` entry binding the open contract | works; `validatePluginBindings` gates it on approval |
| `android:exported` | `bindings[intentID].isExported` | works |
| system resolver | `ProviderRegistry.resolveAndHold` | works |
| "Always" / "Just once" | `configuredDefaults` + `setConfiguredDefault(_:for:)` | **built and tested; no product surface calls it** |
| chooser dialog | `ProviderResolutionError.ambiguousProvider` | throws where it should ask |
| the grant | `approvedOpenIntentIDs` | wired to `{ _, _ in [] }` in `TenonApp.swift` |
| built-in host entry point | typed application service | **missing; no public host principal is added** |

`resolveAndHold` already ranks explicit target → **`configuredDefaults`** → `trustedDefault`
→ the single eligible provider. The person's choice already outranks the built-in handler.
The kernel has been ready for this longer than the question has been asked.

## The host entry point

Handler choice lives behind the resolver, while built-in SwiftUI and its application
services are one semantic owner. The normative boundary law therefore forbids minting a
generic app or UI intent principal just to reuse a public adapter. Built-in UI calls one
typed opening service DIRECT; public intent provider adapters call that same service, so
the domain operation exists once without inventing a second public caller class.

Being bundled changes nothing for `dev.tenon.browser`: invariant 9 and
`docs/architecture-interaction-boundaries.md` ("two plugins always have different semantic
owners, including bundled plugins") give it the same boundary a third-party plugin gets.
The gap is the typed host service and its chooser/default policy, not a caller identity.
The public audiences remain exactly `plugin`, `cli`, and `agent` for core open contracts.

## What lands

1. **`url.open.v1`**, an `open` core contract taking one bounded absolute `http(s)` address.
   Its **trusted default** is the host's existing `NSWorkspace` opener in
   `SystemIntentProvider`, so removing every plugin leaves today's behaviour exactly intact.
   It arrives with its inventory, audience, policy, fitness test, and source-owned catalog
   in one reviewed change, as `docs/design-intent-bus.md` requires.
2. **One typed host service** for opening. Built-in UI calls it DIRECT; intent provider
   adapters call the same service. The service applies the selected open-handler policy
   without self-sending through a synthetic host principal. Agent Lens' `.systemAction`
   fallback is then removed, so exactly one thing happens when a person clicks a link.
3. **`dev.tenon.browser` provides `url.open.v1`.** Its current
   `dev.tenon.browser.open.v1` declares an empty `inputSchema` and can only open its home
   page; serving an address is new, and loads it with `browser.surface.load.v1` into the
   surface it already owns.
4. **Approval and chooser.** `approvedOpenIntentIDs` becomes real state a person grants in
   Settings. Where two handlers qualify, `ambiguousProvider` presents a chooser whose
   "always" answer calls the `setConfiguredDefault` that already exists.

Adding the next openable kind — a diff, an image, an address in a terminal — is then one
contract plus one trusted default. Approval, chooser, defaults, and revocation are shared;
built-in UI still enters through the typed application service. That is the test this
design has to pass, and the reason it is built once instead of per-surface.

## Fail-closed rules

- A handler the person never approved is never selected, and a revoked approval drops the
  configured default with it — `ProviderRegistry` already clears `configuredDefaults`
  entries when a provider is retired.
- An unloaded, unhealthy, or quarantined handler falls back to the trusted default rather
  than dropping the click. `resolveAndHold` already filters on `lifecycle == .active` and
  `isHealthy`.
- A handler that fails or times out surfaces as a visible failure on the gesture, never as
  silence.
- No implicit data filtering. Tenon resolves handlers per exact contract; it does not adopt
  Android's scheme/MIME matching, which would put input parsing inside provider selection.
  A new openable kind is a new contract with its own schema — the property that keeps every
  intent's input exactly typed.

## Verification

- A fitness test pins every `open` contract to the normative programmatic audience and
  prevents a built-in app/UI principal from entering the closed inventory.
- A fitness test pins that built-in UI reaches the opener through the typed service, and
  that no built-in view opens an address directly — `NSWorkspace` stays confined to
  `SystemIntentProvider`.
- Headless: approval gating, chooser selection, remembered default, revocation, trusted
  default fallback on an unhealthy handler, and exact preservation of the closed public
  audience inventory.
