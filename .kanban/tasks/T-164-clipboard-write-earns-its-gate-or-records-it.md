# T-164: clipboard.write.v1 earns its gate or records the decision
> The only external-effect write in the core catalog with neither a capability binding nor an inherent user interaction; decide whether that is a gap or an undocumented decision.
- **priority**: medium
- **effort**: S

Found by `docs/reports/2026-08-14-core-intent-catalog-evaluation.md` (finding F2).
Mechanics (HIGH): `CoreIntentCatalog.swift:959-979` passes no `bindings:`, default is `[]`
(`:2262`), so zero `CapabilityRequirement`s are generated
(`IntentDispatchRule.swift:215-216`). Paste hijacking is a real attack class. The `ui.*`
intents also carry no binding, but there the interaction is the mediation — the person sees
the dialog; nothing is visible when a clipboard write lands.

## Criteria
- [x] Establish whether manifest declaration + install-time standing consent was a deliberate gate (git log / PRD decision logs) or an omission — the catalog/design had no binding, while `PRT-FR-020` and the capability PRD already make manifest permissions the standing policy boundary; the missing clipboard permission was an omission.
- [x] Add the dedicated `clipboard.write` capability binding and record the decision in `docs/prds/plugin-runtime.prd.md`. The permission is reviewed at installation/enablement and remains standing; `confirmation: never` avoids repeated prompts for trusted bundled plugins.
- [x] Add catalog and host-policy fitness assertions so an unmediated external plugin write cannot silently ship without a capability.

Receipt (2026-08-14): `CoreIntentCatalogTests` focused assertion passed; clipboard host-grant
assertion passed; `FileExplorerPluginTests` 3/0 and `ShippedPluginsTests` 4/0 passed. The first
combined catalog/host run found and was corrected for the existing browser external-write cases;
the final focused runs passed.
