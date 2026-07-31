# T-047: Single-file automation scripts — a lone .js with an embedded manifest header
> `~/.../plugins/report.automation.js` with a leading `/* tenon-manifest {...} */` block is
> discovered, validated, and run exactly like a directory plugin — one file to write an
> automation. Follow-up to T-046, which ships the schedule/event machinery.
- **priority**: medium
- **effort**: M

## Why
T-046 makes an automation a plugin (manifest + main.js dir). The manifest is load-bearing —
permissions and `intents.uses` must be declared before evaluation — so "just a JS file"
still needs a declaration; embedding it as a leading comment block keeps declare-before-eval
while collapsing the packaging to one file.

## Design sketch (validate against PluginLoader/PluginHost identity rules before coding)
- `PluginLoader.discover` additionally returns top-level `*.js` files in the plugins root;
  a synthesized record parses the embedded JSON header through the SAME `PluginManifest`
  decoder (one validation path), entrypoint = the file itself, `directoryName` analog = the
  file name (identity rules: reserved/duplicate/prefix/id-change all apply unchanged).
- A malformed header should fail like any malformed manifest — note the pre-existing
  batch-fail behavior of `prepareAllManifests` (one bad manifest kills the whole reload);
  if that gets fixed, it gets fixed for directories and files together, not here.
- `PluginWatcher` must watch the file for hot reload the way it watches directories.
- `ShippedPluginsTests`/`PluginHostTests` fixtures grow a single-file case.

## Criteria
- [ ] A single `.js` file with a valid embedded manifest loads, activates, hot-reloads, and
  retires exactly like a directory plugin (same principal, same policy, same surface).
- [ ] A file with a missing/malformed header is reported as a load failure with a
  suggestion-bearing diagnostic; identity rules (duplicate id, id change, prefix overlap)
  hold across the mixed directory+file namespace.
- [ ] Docs: design-automations.md single-file section moves from "future" to "shipped";
  README runtime notes updated.
