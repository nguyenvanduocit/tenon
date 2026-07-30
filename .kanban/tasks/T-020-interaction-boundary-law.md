# T-020: Interaction boundary law
> Make every Tenon interaction use one deterministic, machine-enforced classification.
- **priority**: critical
- **effort**: XL

## Criteria
- [ ] One normative decision law classifies direct calls, intents, events, resources, contributions, scoped facilities, pure utilities, and control-plane operations.
- [ ] Every existing Swift, plugin-runtime, shipped-plugin, CLI, and documentation surface is inventoried and reconciled.
- [ ] Internal app code has no generic app intent principal or dispatcher shortcut.
- [ ] Shipped plugins use manifest-declared intents and the closed runtime surface only.
- [ ] Architecture fitness tests reject undeclared surfaces, stale request paths, and audience drift.
- [ ] Intent providers and CLI contracts agree with their schemas.
- [ ] Swift 6 warnings-as-errors build and the full test suite pass.
- [ ] An independent verifier approves the integrated result.

## Owner / files (agent lock)
- root team session `019f9576-4fe5-7351-a9c1-24f594b604f1`
- architecture/docs/fitness tests: `/root/boundary_docs_executor`
- plugin inventory/state-root split: `/root/plugin_migration_executor`
- CLI provenance and runtime backpressure: `/root/core_contract_executor`
- lifecycle files currently locked: `poc/Sources/TenonCore/PluginHost.swift`,
  `poc/Sources/TenonApp/TenonApp.swift`
- runtime files currently locked after T-019 coordinates: `PluginRuntime.swift`,
  `PluginRuntimeBridge.swift`, `PluginRuntimeBootstrap.swift`, `PathWatcher.swift`
- final verification: pending after current locks release

## Evidence
- `docs/design-intent-bus.md:240-246` currently omits the ownership test and over-classifies finite internal work as intent.
- `poc/Sources/TenonApp/AppIntentRuntime.swift:19-24` defines an app principal with no production caller.
- `poc/Sources/TenonApp/CLICommandExecutor.swift` duplicates catalog-backed workspace/terminal semantics.
