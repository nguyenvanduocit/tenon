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

## Owner / files (agent lock)
session 247281cf — **DONE 12:1x, LOCKS RELEASED.** NEW
`TenonCore/PluginManifestHeader.swift`, NEW
`Tests/TenonCoreTests/{PluginManifestHeaderTests,SingleFilePluginTests}.swift`,
`PluginManifest.swift` (loader), `PluginRuntime.swift` (one line: entrypoint),
`docs/design-automations.md`.

## Criteria
- [x] A single `.js` file with a valid embedded manifest loads, activates and hot-reloads
      exactly like a directory plugin — `SingleFilePluginTests` mixes both packagings in one
      plugins root and requires that nothing tells them apart but the layout
- [x] A malformed header fails loudly with a diagnostic naming the file, and identity rules
      hold across the mixed namespace — a duplicate id collides whether the claimants are
      files, directories, or one of each
- [x] Docs — `design-automations.md` gains a shipped single-file section with the two rules
      that are easy to get wrong

## What shipped

`PluginManifestHeader` finds the JSON; `PluginManifest` still validates it. **One decoder,
deliberately** — a second, more forgiving path is how two plugins with identical declarations
end up with different authority.

`PluginLoader` gained the only place that knows a plugin's shape: `isSingleFilePlugin`,
`entrypoint(for:)`, and a `discover` that returns both. Everything downstream — identity,
policy, activation, retirement — works from the manifest and the entrypoint and never learns
how they were packaged. `PluginRuntime` changed by one line.

**A header must open the file.** Code above it would run before the plugin declared what it
may do, and a file with two headers has no answer to which is the declaration.

**A `.js` file with no header is skipped, not failed.** It never claimed to be a plugin, and
one scratch script must not take a reload down for every real plugin beside it. That
distinction is what `hasHeader` exists for, and `testAPlainScriptBesideAPluginIsIgnored`
pins it.

## Mutation proofs

| # | Mutation | Test red |
|---|---|---|
| M35 | a header may appear anywhere, not just at the top | `testAHeaderThatDoesNotStartTheFileIsNotAHeader` |
| M36 | an unterminated header returns nil instead of failing | `testAClaimedHeaderThatIsBrokenThrows` |
| M37 | header size unbounded | `testTheHeaderIsBounded` |
| M38 | discovery ignores `.js` files | `testASingleFileLoadsAndActivates…` (+2) |
| M39 | entrypoint always appends `main.js` | 3 tests |
| M40 | every `.js` counts as a plugin, header or not | `testAPlainScriptBesideAPluginIsIgnored` |

⚠️ M38's first attempt reddened nothing, and the mutation was real — it was placed after the
directory branch, where it did not change what a `.js` file resolves to. Re-placed at the top
of the filter it reddens three tests. Recording it because "the mutation ran and nothing
failed" and "the mutation did not do what I thought" look identical in the output, and only
the second was true.

## Evidence
`swift build` exit 0 under warnings-as-errors; full `swift test` **896 / 0** (884 before).
