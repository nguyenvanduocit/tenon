# T-163: The intent law learns from Linux, Android, and Orca
> Record the comparative intent-design research (Linux/Unix syscalls, Android Intents, Orca) as a research doc, derive the governing principle, and evaluate all 51 core intents against it in a dated report.
- **priority**: medium
- **effort**: M

## Criteria
- [x] `docs/research-intent-design-principles.md` records the three-system study with primary-source citations and the derived principle (legible boundary law), positioned as non-normative research alongside `research-plugin-runtimes.md`
- [x] `docs/reports/2026-08-14-core-intent-catalog-evaluation.md` evaluates every core intent in `CoreIntentCatalog.swift` against the principle's five clauses, with per-intent verdicts and named findings (F1–F5)
- [x] Findings that are actionable became follow-up kanban tasks: T-164 (clipboard.write binding), T-165 (CLI socket skew evidence), T-166 (error-code ABI sentence); F3 is principle-framing on the already-filed T-159
- [x] `docs/README.md` index gained rows for both documents

Done 2026-08-14 (session `main`). Files lock released.
