# T-019: Manifest-owned product keybindings

> A plugin-owned intent may declare `intents.provides[].palette.key`. The host parses and
> resolves that contribution once, projects the assigned chord into both the palette and
> SwiftUI Commands, and invokes the exact intent through the palette principal.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
RELEASED 2026-07-31 00:17 by Orca worker task_c3852d32d039 — verification complete, all 11 criteria ticked with mutation evidence (see `## Verification` below). The slice's only tracked edits are `Tests/TenonAppStateTests/PaletteIntentInvokerTests.swift` and `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` (both test strengthenings, uncommitted — coordinator owns commits). No `TenonApp.swift` patch turned out to be needed.

Coordination: preserve T-021's standing-consent changes in `PluginHost.swift` and
`TenonApp.swift`. Focused Ghostty/editor gestures remain typed DIRECT controls at their
current responder/view boundaries.

Claimed files:
- `Sources/TenonCore/KeyChord.swift` — NEW (parse / normalise / display)
- `Sources/TenonCore/KeyBindingIndex.swift` — NEW (aggregate + conflict rules)
- `Sources/TenonCore/PluginManifest.swift` — canonical `palette.key`
- `Sources/TenonCore/CommandIndex.swift` + `CommandAggregation.swift`
- `Sources/TenonCore/PluginHost.swift` — transactional binding projection
- `Sources/TenonApp/TenonApp.swift` — dynamic SwiftUI Commands
- `Sources/TenonApp/PaletteOverlay.swift` + shared palette invocation helper
- `Tests/TenonCoreTests/KeyChordTests.swift` — NEW
- `Tests/TenonCoreTests/KeyBindingIndexTests.swift` — NEW
- manifest, host lifecycle, invocation, and boundary-fitness tests
- shipped plugin manifests that declare product keys

## Design

**One canonical field.** A plugin declares `palette.key: "cmd+shift+g"`. The host parses
that string into a `KeyChord`; every rendered label comes from `KeyChord.display`.

`KeyChord` is a value: modifiers + a key, normalised (`cmd`/`command`/`⌘` are one thing,
order is irrelevant) so two spellings of the same chord collide as they should.

**Conflict rules live in the core**, where they can be asserted without a window:
1. The closed shell-reserved set wins: Command Palette and standard application-menu
   controls. Workspace product chords are owned by manifest intents and are never reserved.
2. Plugin collisions resolve by lexical `(pluginID, intentID)`, independent of load order.
3. Invalid, reserved, and losing contributions produce typed deterministic diagnostics.
4. `PluginHost.publish` computes presentations, assignments, commands, and new diagnostics
   as one transaction. Repeated publication does not repeat an unchanged diagnostic.
5. A command action revalidates the current assignment and current presentation, mints a
   fresh user gesture, and enters the shared dispatcher through the palette principal.

**One execution path.** `TenonApp` keeps the shell-owned Command Palette action. New Tab,
Split, Close, tab navigation, and pane focus are generated from the active
`core-commands` intent bindings. Palette selection and generated SwiftUI Commands share
the same app-side invoker; neither calls `WorkspaceStore` directly.

## Criteria
- [x] `KeyChord.parse` handles `cmd+shift+p`, `ctrl+alt+k`, `⌘⇧P`, `cmd+1`, `f5`, `cmd+]`;
      rejects modifier-only, multiple-key, unknown, and bare-printable input
- [x] `KeyChord.display` renders macOS glyph order (⌃⌥⇧⌘ then the key)
- [x] `KeyBindingIndex` is pure, deterministic under shuffled input, and emits typed diagnostics
- [x] manifest `palette.key` reaches `PluginIntentPresentation`; `CommandIndex` carries only
      the assigned `KeyChord`
- [x] active host lifecycle changes rebuild bindings transactionally and deduplicate logs
- [x] shipped `core-commands` receives ⌘T, ⌘D, ⇧⌘D, ⌘W, tab-navigation, and pane-focus
      bindings; the genuinely shell-owned ⌘⇧P contribution is rejected as reserved
- [x] SwiftUI Commands invoke the exact current plugin-owned intent through the shared
      palette helper with a fresh host-minted gesture and action-time assignment check
- [x] `TenonApp` has no static workspace product keybindings or direct workspace mutations
      in its Commands scene
- [x] the palette shows `key.display`; losing intents remain palette-only
- [x] architecture fitness locks the manifest-only contribution and DIRECT focused controls
- [x] focused tests, full suite, and build pass in Swift 6 with warnings as errors

## Supersession audit

Session 0c434576 paused after the T-020 boundary note and produced no new keybinding files
or task/source writes after 10:44. Ownership moved to T-020 on 2026-07-25 before
implementation began.

## Verification (2026-07-31, Orca worker task_c3852d32d039 / dispatch ctx_91962a8f2893)

The feature was already fully landed by the vanished root-team session; this slice proved
each criterion by mutation instead of trusting the code's existence. Method per criterion:
break the rule in Sources, run the focused test, confirm RED for the stated reason, revert,
confirm the tree byte-identical to HEAD (`git diff --stat HEAD` empty on all 7 touched
source files). One vacuous test was found and fixed; two fitness gaps were locked.

| # | Criterion | Verdict | Rule | Load-bearing test | Mutation result |
|---|-----------|---------|------|-------------------|-----------------|
| 1 | parse accepts/rejects | **MET** | `KeyChord.swift:35-71,123-144` | `KeyChordTests:28-40` | barePrintable throw removed → RED (`KeyChordTests.swift:33` "did not throw"), reverted |
| 2 | display glyph order | **MET** | `KeyChord.swift:73-78` | `KeyChordTests:14,18` | `allCases` → `reversed()` → RED ("⌥⌃K" ≠ "⌃⌥K", "⌘⇧P" ≠ "⇧⌘P"), reverted |
| 3 | index pure, deterministic, typed diagnostics | **MET** | `KeyBindingIndex.swift:88-135` | `KeyBindingIndexTests:50-88,111-140` (shuffled input) | lexical `<` flipped → RED (winner beta ≠ alpha, `:73,:77,:78`), reverted |
| 4 | `palette.key` → presentation; Command carries assigned chord only | **MET** | `PluginHost.swift:2331` + `:2251-2263`, `CommandAggregation.swift:6-18` | `PluginHostTests:52-66` | `command(assignedKey:)` → `key: nil` → RED (`PluginHostTests.swift:56,:89` nil ≠ "⇧⌘K"), reverted |
| 5 | transactional rebuild + dedup logs | **MET** | `PluginHost.swift:2264-2267,2294-2305` | `PluginHostTests:69-103` | dedupe filter removed → RED (`:78` "3 ≠ 1 — unchanged publishes must not duplicate diagnostics"), reverted |
| 6 | shipped core-commands keys; ⌘⇧P reserved | **MET** | `plugins/core-commands/manifest.json` (7 keys), `KeyBindingIndex.swift:70-83` | `CoreCommandsPluginTests:47-86`, `KeyBindingIndexTests:6-48` | ⌘T added to `shellReserved` → RED (⌘T binding lost + `.reserved` diagnostic + reserved-set pin `:36`), reverted. Note: the shipped manifest no longer contributes ⌘⇧P at all (titles pinned at `CoreCommandsPluginTests:22-37`); the reserved-rejection rule is asserted generically at `KeyBindingIndexTests:6-24`. |
| 7 | Commands via shared helper, fresh gesture, action-time check | **MET after test fix** | `PluginKeyBindingCommands.swift:32-47`, `PaletteIntentInvoker.swift:17-37` | `PaletteIntentInvokerTests:9-146` | **VACUOUS FOUND**: deleting the `expectedBinding` revalidation left the test GREEN — its "stale" path disabled the whole plugin, so the presentation guard masked the rule (the provenance-tests pattern again). Fixed by asserting a moved assignment while the plugin stays enabled (`PaletteIntentInvokerTests:100-113`). Re-run: mutation → RED (`:106`), constant-UUID gesture → RED (`:98`); rule restored → GREEN. |
| 8 | no static product keys / workspace mutations in Commands scene | **MET, lock added** | `TenonApp.swift:62-78` (palette toggle + `PluginKeyBindingCommands` only) | NEW lock `InteractionBoundaryFitnessTests:171-191` (exactly one `.keyboardShortcut(` in the `.commands` slice, no `WorkspaceStore`/`store.`) | Mutation-proof of the new lock is **blocked**: it requires editing `TenonApp.swift`, held by T-027. The check is arithmetic (count == 1) and currently green. |
| 9 | palette shows `key.display`; losers palette-only | **MET, lock added** | `PaletteOverlay.swift:250-254`; loser `Command.key == nil` at `PluginHost.swift:2258` | `PluginHostTests:62-66` (loser nil) + NEW anchor `Text(key.display)` in fitness `:144-148` | accessory block deleted → RED ("missing semantic anchor: Text(key.display)" `:149`), reverted |
| 10 | fitness locks manifest-only contribution + DIRECT focused controls | **MET** | `InteractionBoundaryFitnessTests:96-250` | itself | real bypass mutation (Commands invoking `intentRuntime.send` directly, invoker anchor kept in a comment — it **compiles**, so the violation is expressible) → RED only via `XCTAssertFalse(contains("intentRuntime.send("))` `:170`; `testNativeDispatcherEntryPointsRemainAtCrossOwnerAdapters` stayed green under it, so that assert is the sole guard. Reverted. |
| 11 | build + focused + full suite, Swift 6 | **MET** (totals below) | `Package.swift:118` `.v6` | — | "warnings as errors" is not configured as a compiler flag anywhere in `Package.swift`; measured warning count on the final build recorded below. |

Final totals on the settled tree: `swift build` exit 0 — 0 Swift warnings, the only 2
warnings are the pre-existing GhosttyKit ImGui linker-symbol ones; `swift test` exit 0,
**723 tests / 0 failures** (bar was 659; baseline at claim time was 679 — other live
workers landed more tests during this slice). The two test files above are the only tracked files this
slice leaves modified; all seven mutated source files are byte-identical to HEAD `a8e2b28`.
Shared-tree note: three verification cycles were interrupted by T-016's mid-write compile
errors (`FileDocumentExternalChangeTests.swift`, `FileSlotView.swift`,
`SourceEditorView.swift`); handled by revert-first, wait-for-compile, retry — no foreign
file was touched.
