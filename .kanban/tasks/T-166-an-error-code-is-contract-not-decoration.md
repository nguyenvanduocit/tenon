# T-166: An error code is contract, not decoration
> State in the intent-bus law that the condition→error-code mapping of a shipped contract is frozen, not only the declared error list.
- **priority**: low
- **effort**: XS

From `docs/research-intent-design-principles.md` (clause 5). The incident behind "WE DO NOT
BREAK USERSPACE" (LKML 2012-12-23) was an error code changing `EINVAL`→`ENOENT` for an
existing condition — callers branch on failure shapes. `design-intent-bus.md`'s same-major
evolution table governs the declared error *list* (adding a declared domain error is
allowed) but does not state that re-mapping which error an existing condition returns is a
breaking change. Verify it is genuinely unstated, then add the sentence to the same-major
rules with a decision-log line.

## Criteria
- [x] Confirm `design-intent-bus.md` does not already state the mapping rule
- [x] One added sentence in the same-major evolution rules naming condition→code re-mapping as breaking (→ `.v2`)
- [x] Decision-log entry citing the source incident

## Receipt — 2026-08-14

The same-major table previously froze schema acceptance, output shape, effects, authority,
idempotency, and confirmation semantics, but not the condition-to-error-code mapping. The
law now states that re-mapping an existing condition to another code is breaking and requires
`.v2`; the settled-decision list records the LKML 2012-12-23 `EINVAL`→`ENOENT` incident that
motivated the rule.
