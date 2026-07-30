# T-019: Manifest-owned product keybindings

> A plugin-owned intent may declare `intents.provides[].palette.key`. The host parses and
> resolves that contribution once, projects the assigned chord into both the palette and
> SwiftUI Commands, and invokes the exact intent through the palette principal.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
T-020 session 019f9576 — ACTIVE

Coordination: preserve T-021's standing-consent changes in `PluginHost.swift` and
`TenonApp.swift`. Focused Ghostty/editor gestures remain typed DIRECT controls at their
current responder/view boundaries.

Claimed files:
- `poc/Sources/TenonCore/KeyChord.swift` — NEW (parse / normalise / display)
- `poc/Sources/TenonCore/KeyBindingIndex.swift` — NEW (aggregate + conflict rules)
- `poc/Sources/TenonCore/PluginManifest.swift` — canonical `palette.key`
- `poc/Sources/TenonCore/CommandIndex.swift` + `CommandAggregation.swift`
- `poc/Sources/TenonCore/PluginHost.swift` — transactional binding projection
- `poc/Sources/TenonApp/TenonApp.swift` — dynamic SwiftUI Commands
- `poc/Sources/TenonApp/PaletteOverlay.swift` + shared palette invocation helper
- `poc/Tests/TenonCoreTests/KeyChordTests.swift` — NEW
- `poc/Tests/TenonCoreTests/KeyBindingIndexTests.swift` — NEW
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
- [ ] `KeyChord.parse` handles `cmd+shift+p`, `ctrl+alt+k`, `⌘⇧P`, `cmd+1`, `f5`, `cmd+]`;
      rejects modifier-only, multiple-key, unknown, and bare-printable input
- [ ] `KeyChord.display` renders macOS glyph order (⌃⌥⇧⌘ then the key)
- [ ] `KeyBindingIndex` is pure, deterministic under shuffled input, and emits typed diagnostics
- [ ] manifest `palette.key` reaches `PluginIntentPresentation`; `CommandIndex` carries only
      the assigned `KeyChord`
- [ ] active host lifecycle changes rebuild bindings transactionally and deduplicate logs
- [ ] shipped `core-commands` receives ⌘T, ⌘D, ⇧⌘D, ⌘W, tab-navigation, and pane-focus
      bindings; the genuinely shell-owned ⌘⇧P contribution is rejected as reserved
- [ ] SwiftUI Commands invoke the exact current plugin-owned intent through the shared
      palette helper with a fresh host-minted gesture and action-time assignment check
- [ ] `TenonApp` has no static workspace product keybindings or direct workspace mutations
      in its Commands scene
- [ ] the palette shows `key.display`; losing intents remain palette-only
- [ ] architecture fitness locks the manifest-only contribution and DIRECT focused controls
- [ ] focused tests, full suite, and build pass in Swift 6 with warnings as errors

## Supersession audit

Session 0c434576 paused after the T-020 boundary note and produced no new keybinding files
or task/source writes after 10:44. Ownership moved to T-020 on 2026-07-25 before
implementation began.
