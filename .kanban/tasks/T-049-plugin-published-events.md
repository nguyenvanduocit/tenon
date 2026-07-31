# T-049: A plugin can observe facts but cannot publish one
> `tenon.events.on` exists; there is no `emit`. Plugin→plugin facts are forced through an
> intent, which has the wrong cardinality and inverts the dependency.

- **priority**: medium
- **effort**: M
- **from**: T-042's review, which found this to be the one two-way gap the existing rungs do
  not cover. That review is the classification; this task is the implementation.

## Owner / files (agent lock)
UNCLAIMED.

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
- [ ] Public surface designed and pinned: one new member on `tenon.events`, with the
      surface and `globalThis` closure tests updated in the same change (invariant 1)
- [ ] Manifest declares what a plugin may publish and who may observe; an undeclared publish
      is refused fail-closed, with a blocked/allowed pair asserting it
- [ ] A plugin cannot publish a host-owned event name, asserted
- [ ] Payload bounded; a publisher that floods is bounded rather than unbounded, asserted
- [ ] Retiring a generation stops both publication and delivery, asserted against a real
      runtime the way existing retirement tests are
- [ ] Delivery goes through the single existing emit site, not a second path
- [ ] kanban publishes "board changed" and a fixture plugin observes it — end to end through
      a real `PluginHost`, since that is the case that motivated this
- [ ] `docs/architecture-interaction-boundaries.md` EVENT inventory updated in-change
- [ ] `swift build` exit 0 + full `swift test` green, with RED-first and mutation evidence

## Notes
- The reason this is not folded into T-042: that task's job was to decide, and it decided
  the mechanism already exists. Implementing a new public member is a separate change with
  its own fitness tests, and mixing the two would have made the decision unreviewable.
