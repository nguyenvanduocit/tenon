# T-078: A DIRECT gate that can say no, and a latency budget that can be falsified

> Step 4 of the ordered decision law is self-ratifying, and falsification criterion #7 is
> unfalsifiable. Two mechanical fitness gates fix both.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)

Released — session `fdb5e373`, 2026-08-07 12:3x. `docs/architecture-interaction-boundaries.md`,
`poc/Tests/TenonCoreTests/DirectInventoryGateTests.swift`, and
`poc/Tests/TenonIntentCoreTests/IntentKernelLatencyBudgetTests.swift` are FREE.
No `Sources/` file was touched.

## Classification

This change adds no interaction: no `Sources/` file, no `tenon` member, no intent, event,
contribution, or resource. It is a fitness-function plus decision-record change, which the
law's own **Required fitness functions** and **Change protocol** sections call for. No step
of the ordered decision law is reached. It creates and relies on no core-plugin exception;
both gates constrain host Swift and every caller principal equally.

## The two deficits, measured

**DIRECT drift.** Parsed with the rule the new test uses (`Current DIRECT inventory:` to
`### SCOPED FACILITY`, one block per column-0 `- `, continuation lines indented two spaces,
whitespace collapsed):

| | entries | characters |
|---|---|---|
| HEAD `fcac70d` | 11 | 3,363 |
| working tree | 17 | 10,788 |

The public plugin surface moved about one intent over the same span. Growth of 1.55x in
entries and 3.21x in characters is therefore ambient, not reviewed. The dominant drift mode
is growth *inside* an existing entry: `launcher surfaces and tab-context placement
(T-039, AIO-8)` went 1,571 → 2,727 characters and absorbed an entire further DIRECT
behaviour under an unchanged heading. A count-only gate is blind to that, which is why the
gate pins a per-entry length map as well as the count.

**Unfalsifiable budget.** `rg -c budget docs/architecture-interaction-boundaries.md` → 1
(the word appears once, in falsification criterion #7, with no number).
`rg 'XCTMetric|self\.measure' poc/Tests/` → 0. The criterion cannot fail.

## Criteria
- [x] `#### Adding a DIRECT entry` records the measurement, the labelled-clause rule, the
      `PluginViewModal` refutation, and the grandfathering statement.
- [x] `### The kernel latency budget` states one parseable ceiling sentence and the honest
      measurement record, resolving power, and instrument caveat.
- [x] Falsification criterion #7 gains the mechanical budget as a second, independently
      sufficient trigger without losing the user-visible-regression disjunct.
- [x] `## Change protocol` item 8 and three `## Required fitness functions` bullets.
- [x] `DirectInventoryGateTests` pins entry count **and** per-entry length, and requires a
      labelled justification clause on every added or enlarged entry.
- [x] `IntentKernelLatencyBudgetTests` reads the ceiling out of the law document and
      measures the CPU ratio of one `IntentDispatcher.send` against the same actor method
      called DIRECT.
- [x] Five mutation proofs recorded below.

## Mutation proofs

Both standing gates are green on arrival by construction, so mutation is the only evidence
that they have teeth. All five were run and their output recorded.

1. Delete the `This inventory has 17 entries` sentence → `XCTUnwrap failed: expected non-nil
   value of type "Int"`. This is the red the doc edit turns green.
2. Append `- a new host convenience;` → count 18 vs 17, unpinned lead phrase, and
   *"a new host convenience is a new entry and carries no justification clause"*.
3. Grow `pane activity/attention state (T-029)` by ~230 characters after its lead phrase,
   leaving the lead unchanged → *"was 510, now 743 characters"* **and** *"grew from 510 to
   743 characters and carries no justification clause"*. This is the proof that matters:
   it is the drift mode a count-only gate misses, and it is how `launcher surfaces and
   tab-context placement` actually grew 1,571 → 2,727.
4. Lower the documented ceiling to `10×` → *"costs 401.1× the CPU ... over the documented
   ceiling of 10×. Worst sample 474.8×; direct 801 ns/call, intent 304931 ns/call"*.
5. Return `value + 1` from `DirectEchoService` → the denominator-shape test fails on
   `integer(8)` vs `integer(7)`.

Every mutation was reverted by its exact inverse edit and confirmed byte-identical with
`cmp` against a pre-mutation copy — never with `git checkout`, which on this shared tree
would destroy peer work.

## Result

`swift build` clean. `swift test` **1313 executed, 0 failures**, 76.2 s — including the two
suites T-074 records as timing-flaky. The four new tests cost 0.51 s.

The measured ratio is **~409×**, not the 25–36× the design anticipated; the ceiling is 700×,
not 60×. The design's figure was not reproducible here and its numbers were re-derived from
scratch, as its own pre-work step required.
