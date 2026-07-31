# T-049: A plugin can observe facts but cannot publish one
> `tenon.events.on` exists; there is no `emit`. Plugin→plugin facts are forced through an
> intent, which has the wrong cardinality and inverts the dependency.

- **priority**: medium
- **effort**: M
- **from**: T-042's review, which found this to be the one two-way gap the existing rungs do
  not cover. That review is the classification; this task is the implementation.

## Owner / files (agent lock)
session 247281cf — **DONE 11:5x, LOCKS RELEASED.** NEW `TenonCore/PluginEventManifest.swift`,
NEW `Tests/TenonCoreTests/PluginPublishedEventTests.swift`, `PluginManifest.swift`,
`PluginRuntime.swift`, `PluginRuntimeModels.swift`, `PluginRuntimeBridge.swift`,
`PluginRuntimeBootstrap.swift`, `PluginHost.swift`, `PluginBuiltinsTests.swift` (pin),
`plugins/kanban/**`, boundary doc, `CLAUDE.md`.

## Why this is real, not theoretical

The kanban plugin (T-041) watches `.kanban/` and re-parses when the board changes. Nothing
else can learn that the board changed. Today's only route is for the interested plugin to
declare an intent and kanban to send it, which is wrong twice over:

- **Cardinality.** A fact has 0..n observers; an intent has exactly one provider and fails
  when it is absent. So a publisher with no listener would start reporting errors.
- **Direction of dependency.** The publisher would have to name its consumers, which is
  backwards — the whole point of a fact is that the producer does not know who is listening.

## Classification, settled by T-042

**EVENT.** It is a fact that already happened, on a channel the publishing plugin owns,
whose producer exists whether or not anyone observes it. This is a missing *member* on an
existing rung, not a new rung: `events.on` is already the observation half.

## What the spec has to answer before code

- **Naming and ownership.** A plugin publishes only under its own namespace, so a plugin
  cannot forge `automation.fired` or any host event. The host emit path is the single
  authority on which name a given principal may publish.
- **Audience.** Who may observe. Declared in the manifest, like every other authority in
  this system — not open by default, and not decided at emit time by the publisher.
- **Bounds** (invariant 10). Payload size, and what happens when a subscriber is slow or a
  plugin publishes in a loop. An event with no backpressure story is a queue with no bound.
- **Teardown.** A retired generation publishes nothing and receives nothing; subscriptions
  die with the generation that made them, like every other resource the runtime owns.
- **Policy path** (invariant 5). Publishing is authority. It goes through the same
  fail-closed checks as everything else — naming a channel must not grant the right to
  publish on it.
- **One emit site.** T-046 established that `automation.fired` is delivered through the
  existing targeted emit and never broadcast, which is what stops plugins forging it. A
  plugin-published event must land on that same path rather than beside it.

## Criteria
- [x] Public surface designed and pinned: one new member on `tenon.events`, with the
      surface and `globalThis` closure tests updated in the same change (invariant 1)
- [x] Manifest declares what a plugin may publish and who may observe; an undeclared publish
      is refused fail-closed, with a blocked/allowed pair asserting it
- [x] A plugin cannot publish a host-owned event name, asserted
- [x] Payload bounded; a publisher that floods is bounded rather than unbounded, asserted
- [x] Retiring a generation stops both publication and delivery, asserted against a real
      runtime the way existing retirement tests are
- [x] Delivery goes through the single existing emit site, not a second path
- [x] kanban publishes "board changed" and a fixture plugin observes it — end to end through
      a real `PluginHost`, since that is the case that motivated this
- [x] `docs/architecture-interaction-boundaries.md` EVENT inventory updated in-change
- [x] `swift build` exit 0 + full `swift test` green, with RED-first and mutation evidence

## Notes
- The reason this is not folded into T-042: that task's job was to decide, and it decided
  the mechanism already exists. Implementing a new public member is a separate change with
  its own fitness tests, and mixing the two would have made the decision unreviewable.


## What shipped

`tenon.events.emit(name, payload)`. A plugin declares in its manifest what it may publish
and what it observes; neither side names the other.

**Forgery is unavailable, not refused.** Only the LOCAL channel name crosses from the
runtime. The host adds the owning prefix from the identity it already holds, so a plugin
cannot publish `automation.fired` or another plugin's channel — there is no way to say a
full name. A local name containing the separator is refused at manifest decode, so the
attempt never reaches a runtime either.

**The publisher learns nothing about who listened.** No reply, no count. A fact with no
observers is delivered nowhere and succeeds, which is exactly what keeps a publisher
independent of its consumers — the inverted dependency T-042 rejected.

**Bounds.** 32 channels per plugin, 128 characters per name, no whitespace or control
characters, no duplicates, validated on decode. In flight, a plugin publishing in a loop is
capped at the same limit as its outbound intents and the overflow is dropped with a log — a
fact nobody can deliver is not worth unbounded memory.

**One delivery site.** Fan-out goes through the same targeted `emit` every other event
uses, so a retired or disabled session drops there rather than needing a second rule.

kanban is the first publisher, and only when the board's bytes actually changed — a watch
firing on an unrelated file in `.kanban/` says nothing.

## 🐞 Two of my tests passed for the wrong reason

M30 (drop the runtime's publisher gate) and M31 (fan-out ignores the observer's
declaration) both reddened **nothing**.

- **M30**: the rule is checked in two places — the runtime, for a useful error to the plugin
  author, and the host, which is the authority. Removing either alone leaves the other. M33
  removed both and the test went red, so the test covers the *rule*; it simply cannot say
  which gate enforced it. That is defence in depth working as intended, and worth recording
  rather than mistaking for coverage.
- **M31**: the real problem. My "an undeclared observer hears nothing" test had an observer
  whose JavaScript never subscribed at all, so delivery was refused by the runtime's
  existing `handles(event:)` check and my gate was never reached. Replaced with an observer
  that genuinely subscribes and genuinely has not declared — now only the fan-out check
  stands between them, and M31 reddens it.

## Evidence
RED first on the surface pin — adding a member turned
`testRuntimeExportsOnlyTheClassifiedPublicSurface` red before the pin was updated, which is
invariant 1's fence doing its job. Mutations M30–M33 as above. `swift build` exit 0 under
warnings-as-errors, full `swift test` **882 / 0** (876 before).