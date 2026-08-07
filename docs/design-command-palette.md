# Design — Command Palette

**Status:** complete · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Goal

Tenon has one fuzzy find-and-run surface opened with `⌘⇧P`. It presents authorized
plugin-owned intents, ranks them locally, collects any required user input, and invokes the
selected intent through the production dispatcher.

The palette is a presentation adapter, not a second command system. Its rows, keybindings,
CLI exposure, and agent exposure derive from canonical intent contracts.

## Boundary classification

| Concern | Classification |
|---|---|
| plugin declares an action contract and palette metadata | CONTRIBUTION/control-plane declaration in `manifest.intents.provides` |
| user selects a row | INTENT invocation as a `palette` principal |
| ranking, fuzzy matching, frecency, selection movement | DIRECT pure core logic |
| overlay rendering and focus | DIRECT SwiftUI shell logic |
| invocation completion/failure | canonical INTENT result |
| long-lived query-as-you-type source | future RESOURCE/CONTRIBUTION design, not a held intent |

Core intents are not directly exposed to the palette. A bundled or third-party plugin
provides a plugin-owned intent with palette metadata; its handler may call declared core
intents under that plugin's principal.

## Naming and trigger

**Name:** Command Palette.
**Trigger:** `⌘⇧P`.

`⌘K` remains the terminal's clear-scrollback gesture. `Esc` closes the palette;
pressing `⌘⇧P` again toggles it shut.

## UX contract

```text
┌───────────────────────────────────────────────┐
│ 🔎  split rig|                                  │
├───────────────────────────────────────────────┤
│ PANE                                           │
│ ⤢  Split Right                        ⌘D       │
│ ⤢  Split Down                         ⇧⌘D      │
│ GIT                                            │
│ ⎇  Git: Commit             stage and commit   │
├───────────────────────────────────────────────┤
│ ↵ Run                                         │
└───────────────────────────────────────────────┘
```

A row contains icon, highlighted title match, optional subtitle/category, and optional
keybinding hint. The overlay is centered in the upper third, bounded in width/height, and
uses native Tenon theme tokens.

Required states:

- **empty query:** most recent/frequent authorized rows;
- **no result:** a clear empty message;
- **loading:** only for a future bounded dynamic source;
- **provider unavailable/error:** row or section explains the condition while the rest of
  the palette remains usable.

Keyboard:

- `↑` / `↓` changes selection;
- `Enter` invokes;
- `Esc` closes;
- `⌘1…9` may select a visible row;
- secondary actions are separate plugin-owned intents rather than closures embedded in a
  result object.

Modes MAY filter the same projection (`>` actions, `:` panes, `?` help). They MUST NOT
create another invocation registry.

## Canonical declaration

A palette row is static presentation metadata on a plugin-owned intent:

```json
{
  "id": "dev.tenon.core-commands",
  "name": "Core Commands",
  "version": "1.0.0",
  "intents": {
    "uses": ["workspace.pane.split.v1"],
    "provides": [
      {
        "name": "dev.tenon.core-commands.pane.split-right.v1",
        "title": "Split Right",
        "description": "Split the focused pane to the right.",
        "audiences": ["user", "plugin"],
        "effects": {
          "kind": "write",
          "idempotency": "none",
          "confirmation": "never",
          "external": false
        },
        "inputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "outputSchema": {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false
        },
        "palette": {
          "category": "Pane",
          "icon": "rectangle.split.2x1",
          "keywords": ["pane", "split", "right"],
          "key": "cmd+d",
          "when": "hasActivePane"
        }
      }
    ]
  }
}
```

`palette.launcher: true` includes the row in ordinary “open something” launchers.
`palette.fillsPane: true` is the narrower declarative promise that the intent can occupy a
pane supplied in invocation scope. Empty spatial-grid launchers project only rows carrying
both flags. The host reserves the exact clicked region and scopes the selected intent to
that pane; New Tab, Split, and other structural actions therefore remain available in the
ordinary launcher but are absent from this fill-only context. If a provider fails or
returns without filling the reserved pane, the host removes the untouched reservation and
keeps the launcher open with an error.

The empty-grid launcher is not pointer-only. `Option-Return` on the spatial canvas opens
the nearest valid empty region, and VoiceOver exposes one “Fill empty region” custom action
per distinct available region. These routes reuse the same fill-only projection, exact
reservation, scoped invocation, and rollback behavior as right-click.

Runtime code binds only the implementation:

```js
tenon.intents.handle(
  "dev.tenon.core-commands.pane.split-right.v1",
  async (_input, call) => call.send(
    "workspace.pane.split.v1",
    { axis: "vertical" }
  )
);
```

The host validates the contract and presentation metadata before evaluating JavaScript.
The plugin MUST declare every nested intent in `intents.uses`. Provider code uses
`call.send`, which preserves causal scope by default and authorizes any explicit retarget
under the provider plugin's own grants.

There is no runtime command-registration or command-execution API. Static declaration makes
the palette, keybinding index, CLI/agent projections, policy, and documentation available
before the provider is activated.

## Projection and invocation

```text
ContractCatalog + ProviderRegistry + Policy
                    │
                    ▼
       palette-principal projection
                    │
                    ▼
   PaletteIntentIndex (pure rank/filter)
                    │ user selection
                    ▼
             IntentDispatcher
```

A row is visible only when:

1. the contract is plugin-owned;
2. its audiences include `palette`;
3. it carries valid palette metadata;
4. policy allows discovery for the palette principal;
5. its `when` predicate is true;
6. the provider is active, or the product intentionally shows it as unavailable with a
   reason.

Selection dispatches the canonical name and collected input. The palette does not retain a
JavaScript closure or invoke a plugin runtime directly.

## Ranking core

The current pure ranking vocabulary may keep implementation names such as `CommandIndex`;
those types are internal projections, not a public command protocol. Each row ID is the
canonical intent name.

Deterministic ranking:

- empty query: frecency descending, title ascending;
- typed query: fuzzy score descending, frecency only as a tie-breaker, title ascending;
- title match outranks keyword-only match;
- `when` filtering happens before ranking;
- positions MUST NOT churn from frecency while the user is typing.

Frecency uses an injected clock and persisted host-owned state. A missing/retired intent ID
is harmless historical data and is omitted from the projection.

The fuzzy matcher remains pure and bounded. For the expected hundreds—not millions—of
palette entries, local O(number-of-rows × query-length) ranking is preferable to remote or
plugin callbacks on every keystroke.

## Input collection

Zero-input intents invoke immediately.

For non-empty schemas, the palette MAY render host-owned native input collection when the
schema can be represented safely. Collection is an adapter concern; it does not alter the
contract. An input the palette cannot collect is excluded from the palette projection with
an explainable reason.

The palette MUST validate constructed input through the same canonical schema used by all
other adapters. It MUST NOT create palette-only defaults that change intent semantics.

## Built-in actions

Bundled `dev.tenon.core-commands` is a normal plugin. It provides plugin-owned, palette-facing
intents and uses canonical core intents for workspace/terminal work.

Examples:

- New Tab → `workspace.tab.create.v1`;
- Split Right/Down → `workspace.pane.split.v1`;
- Close Pane → `workspace.pane.close.v1`;
- Next/Previous Tab → `workspace.tab.next.v1` / `workspace.tab.previous.v1`;
- Focus Next Pane → `workspace.pane.focus-next.v1`;
- Switch Workspace → `workspace.select.v1`;
- plugin-specific “Open …” actions are owned by that plugin, not by core-commands.

Disabling one plugin removes only its contracts and rows. The palette shell remains valid
when the projection is empty.

Built-in SwiftUI menu/buttons may call the same typed workspace use cases DIRECT because
they share the host semantic owner. This does not authorize a direct plugin or palette
path; the public palette adapter always dispatches the intent.

## Keybindings

An optional `palette.key` is declarative metadata on the same intent. The host compiles a
keybinding index from the authorized projection.

The closed shell reservation set is exactly `cmd+shift+p`, `cmd+,`, `cmd+q`, `cmd+h`,
`cmd+option+h`, and `cmd+m`. Product bindings such as tab and pane operations come only
from manifest intent presentations.

Conflict policy is deterministic:

1. malformed keys are rejected with a typed diagnostic;
2. a key in the closed shell reservation set is rejected;
3. when plugin intents request the same canonical chord, the lexicographically smallest
   `(pluginID, intentID)` wins, independent of plugin discovery or load order;
4. every loser remains available in the palette with a conflict diagnostic.

`PluginKeyBindingCommands` registers only accepted `KeyBindingIndex` entries. A registered
product binding and its palette row both call the shared `PaletteIntentInvoker`, which
enters the production dispatcher as the `palette` principal. Neither path holds or calls a
runtime closure.

Focused editor bindings, Ghostty input handling, and palette open/close/navigation remain
DIRECT because they are local focus or shell mechanics. They call their semantic owner
without entering the dispatcher.

## Dynamic results

Search-as-you-type results have multi-result and query-lifetime semantics. They are NOT
modeled as one indefinitely held intent call. The shipped protocol (T-006 phase 4) is
CONTRIBUTION + EVENT, mirroring `tenon.views`:

```js
tenon.palette.registerProvider("files", { title: "Files" });   // CONTRIBUTION registration
tenon.palette.onQuery("files", function (query) {              // EVENT subscription
  // query = { text, revision } — revision is host-owned and monotonic
  tenon.palette.setResults("files", query.revision, [          // CONTRIBUTION publication
    {
      id: "readme",
      title: "Open README.md",
      subtitle: "docs",
      icon: "doc",
      intent: { name: "dev.example.files.open.v1", input: { path: "README.md" } },
      actions: [
        { title: "Reveal in Finder",
          intent: { name: "dev.example.files.reveal.v1", input: { path: "README.md" } } }
      ]
    }
  ]);
});
```

Protocol rules, enforced by `PaletteProviderTests`:

- **Owner and source:** a provider belongs to the registering plugin generation;
  `manifest.intents.provides` must contain every intent a result or action designates.
- **Query revision:** host-owned, monotonic, bumped per keystroke and on palette close.
  A publication for any revision other than the newest one delivered to that generation
  is dropped by the runtime, and the host renders only publications matching the current
  revision — keystroke N+1 cancels keystroke N.
- **Non-blocking:** query delivery is a fire-and-forget owner-scoped EVENT onto the
  plugin's own pinned thread. The static ranked list renders instantly and is never
  delayed or reordered by a provider; provider sections append below it, showing one
  non-selectable "Searching…" row while an answer is in flight.
- **Bounds:** ≤ 8 providers per plugin (a ninth fails the runtime), ≤ 50 results per
  publication, ≤ 8 actions per result, bounded string lengths.
- **Teardown:** hot reload/disable removes the retired generation's providers
  atomically; `PluginHost.accept`'s identity guard drops its late snapshots.

Each executable result points to a canonical plugin-owned intent name plus input;
selection and the ⌘K actions submenu both dispatch through `PaletteIntentInvoker` as the
palette principal.

## Performance and failure

- Contract/policy projection is cached by revision.
- Ranking runs over immutable value snapshots and never calls JavaScript.
- Typing does not dispatch intents.
- Provider activation/reload updates the projection atomically.
- One broken/unavailable provider does not break ranking or invocation of other rows.
- Invocation follows normal deadline, cancellation, admission, and structured error rules.

## Fitness functions

The palette design is accepted only when:

- every executable row resolves to one canonical plugin-owned intent;
- every row's provider declared the contract before JavaScript evaluation;
- palette discovery is policy-filtered and no core intent appears directly;
- selection and keybinding both enter the production dispatcher;
- source search finds no public runtime command registry, retained JS handler, or direct
  palette→plugin invocation path;
- the bundled core-commands plugin uses only manifest-declared intents;
- disabling a plugin atomically removes its rows and bindings;
- deterministic ranking/frecency/`when` tests pass;
- real-app keyboard tests prove `⌘⇧P`, focus, filtering, invocation, and `Esc`;
- Swift 6 build and full tests pass.

Falsification: if a palette action cannot be represented by a canonical contract, the
contract surface is incomplete. If typing requires calling a plugin on every keystroke,
the missing mechanism is a bounded resource, not a command callback API.

## Research base

Raycast, VS Code QuickPick/when clauses, Sublime Goto Anything, JetBrains Search
Everywhere, cmdk, fzf/fzy, and Firefox frecency informed the UX and ranking. They do not
override Tenon's normative interaction law.
