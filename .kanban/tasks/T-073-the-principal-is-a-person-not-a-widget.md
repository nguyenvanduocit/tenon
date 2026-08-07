# T-073: The principal is a person, not a widget

> `IntentAudience.palette` is named after one control while four surfaces already use it —
> the palette, the title-bar `+`, a tab right-click, and a right-click on empty grid. The
> next surface that wants it (a file path clicked in Agent Lens prose) looks like it needs
> a new principal, and it does not. It needs the existing one to be called what it is.

- **priority**: medium
- **effort**: M — mechanical, but 450 references across 58 files

## Why this is a design fix, not a tidy-up

The whole open-handler argument stalled on "which principal does built-in UI use", and
produced two candidate answers: mint a sixth `ui` principal, or route everything through a
typed host service. The first adds a concept; the second leaves a gap when the chosen
handler is a plugin.

Both exist because the principal that already means *a person did this, now, in this
window* is named after a widget. Rename it and the question dissolves: a palette pick, a
launcher pick, a rebindable product keybinding, and a click on a rendered path are four
**surfaces** of one principal, not four principals. No authority is added — one misleading
name is removed.

## What it does not change

Discoverability. The manifest already carries a separate `palette` **presentation** block
(`category`, `icon`, `keywords`, `launcher`, `fillsPane`) that says how a command appears in
the command list. Only the audience is renamed; the presentation block keeps its name and
its meaning, because that one really is about the palette.

## Criteria

- [x] `IntentAudience.palette` → `.user` and `IntentPrincipal.Kind.palette` → `.user`, with
      `audience` still computed from `kind` so spoofing stays structurally impossible.
- [x] Every plugin manifest declaring `"audiences": [..., "palette"]` says `"user"` — seven
      shipped plugins plus `examples/fleet-review`. Greenfield: no shim, no alias.
- [x] `AppIntentRuntime.palettePrincipal` → `userPrincipal`, id `palette:tenon` → `user:tenon`.
      `PaletteIntentInvoker` keeps its name: it really is the palette/launcher row invoker.
- [x] `PluginIntentProvision.allowedAudiences` and the fitness test pinning the audience
      inventory updated in the same change.
- [x] `docs/architecture-interaction-boundaries.md` principal section rewritten
      affirmatively — the new name stated and explained, no "formerly palette" residue.
      `plugin-author-guide.md`, `design-command-palette.md`, `design-intent-bus.md` follow.
- [x] `swift test` green — **1196 / 0**.

## What the rename cost, exactly

22 files in the first sweep, then one real break. `FleetReviewExampleTests` went red with a
bare `CancellationError()` — it loads `examples/fleet-review` from disk through the real
`PluginHost`, and the sweep had globbed `plugins/*/manifest.json` only. The plugin's
`"palette"` audience no longer existed, so it failed to load and the fixture's materialiser
was cancelled. **A deterministic failure, not a flake** — it failed 1/1 in isolation, which
is how it was told apart from the two genuinely timing-flaky suites in
[T-074](T-074-kanban-coalescing-test-is-timing-flaky.md). The fix was a repo-wide sweep for
`"audiences"[^]]*"palette"`, which also caught three docs.

The lesson worth keeping: a manifest outside `plugins/` is still a manifest. Any future
sweep over plugin declarations searches the repo, not the plugins directory.
