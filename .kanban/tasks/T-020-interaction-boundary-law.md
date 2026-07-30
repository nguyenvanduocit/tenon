# T-020: Interaction boundary law
> Make every Tenon interaction use one deterministic, machine-enforced classification.
- **priority**: critical
- **effort**: XL

## Criteria
- [x] One normative decision law classifies direct calls, intents, events, resources, contributions, scoped facilities, pure utilities, and control-plane operations. — `docs/architecture-interaction-boundaries.md` (accepted, normative); `design-intent-bus.md:228-254` defers to it correctly.
- [x] Every existing Swift, plugin-runtime, shipped-plugin, CLI, and documentation surface is inventoried and reconciled. — audit at `.kanban/reports/t020-boundary-audit.md`; one residual hole (plugin `globalThis` scope, Finding 1) reported with a verbatim patch design.
- [x] Internal app code has no generic app intent principal or dispatcher shortcut. — `InteractionBoundaryFitnessTests.swift:6-56` (kinds pinned, dispatcher + principal-construction allowlists).
- [x] Shipped plugins use manifest-declared intents and the closed runtime surface only. — static fitness `ShippedPluginsTests.swift:50,:75` + independent sweep of all 9 plugins (audit report, PASS table).
- [ ] Architecture fitness tests reject undeclared surfaces, stale request paths, and audience drift. — PARTIAL: stale paths (`CLIIntentBusBoundaryTests.swift:5`) and audience drift (`CoreIntentCatalogTests.swift:538`) covered; undeclared `tenon.*` covered (`PluginBuiltinsTests.swift:86`); **`globalThis` scope is NOT closed — `console` is live in plugin scope and no test would notice** (audit Finding 1, patch design included).
- [x] Intent providers and CLI contracts agree with their schemas. — `AppIntentRuntime.validateBindingInventory` (`AppIntentRuntime.swift:298-315`) + strict CLI parser (`CLIAction.swift:125-138`) + `CoreIntentCatalogTests.swift:91`.
- [ ] Swift 6 warnings-as-errors build and the full test suite pass. — `swift build` exit 0 measured by this slice at 23:49; between 23:49–00:10 no clean suite window existed (five attempts, each red on T-027's or T-016's live mid-edit files — full attempt log in the audit report). Note: warnings-as-errors is not actually configured in `Package.swift` (see report side note). Re-run when the tree quiets.
- [ ] An independent verifier approves the integrated result.

## Owner / files (agent lock)
- RELEASED 2026-07-31 00:1x by Orca worker `task_78e0ddf7a663` — slice complete (Evidence
  re-verification + repo-wide audit at `.kanban/reports/t020-boundary-audit.md`). No file
  is claimed by this task now. `docs/design-intent-bus.md` was verified correct and NOT
  edited. Prior root-team session `019f9576` locks were stale and are superseded.
- Remaining open work for a next slice: audit Finding 1 (plugin `globalThis` scope closure
  — patch design in the report), Finding 2 (CLAUDE.md stale test names), warnings-as-errors
  decision, and the independent-verifier pass.

## Evidence — re-verified 2026-07-30 23:5x by Orca worker task_78e0ddf7a663
All three original defects were resolved by commit `8620bc3` and nobody had re-checked
since; per-item proof in `.kanban/reports/t020-boundary-audit.md` Part 1:
- `docs/design-intent-bus.md:228-254` now states the full ordered ladder including the
  same-owner DIRECT ownership test and defers exact definitions to the normative law.
- `poc/Sources/TenonApp/AppIntentRuntime.swift:19-24` is `palettePrincipal` (`.palette`),
  a lawful public-adapter principal with a production caller
  (`PaletteIntentInvoker.swift:77`); no generic app kind can exist
  (`InteractionBoundaryFitnessTests.swift:6-15`).
- `poc/Sources/TenonApp/CLICommandExecutor.swift:18-78` is a thin control-plane adapter
  (ping/app.focus direct; list/describe/send via the kernel); the legacy duplicate verbs
  are fitness-pinned out (`CLIIntentBusBoundaryTests.swift:5-80`).
