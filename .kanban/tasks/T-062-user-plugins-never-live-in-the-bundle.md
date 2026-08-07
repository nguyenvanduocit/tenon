# T-062: A user-authored plugin never lives inside the app bundle
> Root cause of a real user incident (02:07): T-061's authoring flow hands the agent
> `host.pluginsRoot`, which for an installed app is
> `/Applications/Tenon.app/Contents/Resources/plugins`. The agent wrote
> `git-auto-update.js` there, which **broke the app's code signature** (`codesign -v`
> → "a sealed resource is missing or invalid") and the app failed on restart. Any
> reinstall also silently deletes such a plugin, since `install.sh` replaces the whole
> bundle. Writable user content must never live in a sealed, replaceable bundle.
- **priority**: critical
- **effort**: M

## Owner / files (agent lock)
**ALL LOCKS RELEASED 2026-08-04 13:1x — these files are FREE.**

Held first by session 1d3e1340 (Aug 1, 08:3x–09:20, then silent), taken over and
finished by session 1d6e81a8 (Aug 4, 12:5x–13:1x):
- Sources/TenonCore/PluginHost.swift
- Sources/TenonCore/PluginManifest.swift (discovery across roots only)
- Sources/TenonCore/PluginInventory.swift (NEW)
- Sources/TenonApp/AppStatePaths.swift
- Sources/TenonApp/TenonApp.swift (composition wiring only)
- Sources/TenonApp/AutomationAuthoring.swift
- Tests/TenonCoreTests/PluginInventoryTests.swift (NEW)
- Tests/TenonAppStateTests/AppStatePathsTests.swift
- Tests/TenonAppStateTests/AutomationAuthoringTests.swift
- docs/design-automations.md

## Evidence of the incident (measured, not inferred)
- `/Applications/Tenon.app/Contents/Resources/plugins/git-auto-update.js` existed,
  authored by the agent through T-061's flow.
- `codesign -v /Applications/Tenon.app` → **"a sealed resource is missing or
  invalid"**, i.e. the bundle's seal was broken by the write.
- `~/Library/Application Support/Tenon/plugins/` holds `clock/{main.js,manifest.json}`
  etc. — an **orphaned legacy inventory** that today's `AppStatePaths.resolve` never
  reads (it resolves to the bundle, or to `TENON_PLUGINS_DIR`). Real plugin state
  lives in `state/plugins/` (`.installations.json`, `.storage.json`).
- The incident file was moved out of the bundle to that orphaned directory at 02:1x to
  stop the damage; it therefore loads nowhere until this task lands. Not deleted.

## Rung walk (recorded before code)
Not an interaction-boundary change at all — no plugin→host call is added, no intent,
no `tenon` member. This is host-internal inventory and trust plumbing:
- **Where plugins are found**: `PluginLoader.discover` gains an ordered list of roots.
  Downstream already works from full entry URLs, so nothing else learns there is more
  than one root (same shape as T-047, where packaging stayed inside the loader).
- **What they are trusted with**: `PluginHostAuthorization.grantsStandingConsent` is
  ALREADY `(PluginInstallationKey, PluginManifest) async -> Bool`, i.e. per plugin.
  So trust needs no new signature — it moves onto the inventory the plugin came from.
  The bundled inventory keeps `.bundledInventory`; the user inventory is untrusted, so
  an AI-authored plugin prompts for consent like any third-party plugin (T-033/T-050:
  standing consent is earned by installation and is host-owned).

## Decisions
- **Two inventories, ordered, bundled first.** `PluginInventory { root, authorization,
  isWritable }`. Duplicate ids resolve by the existing identity rules; a user plugin
  cannot shadow a bundled one by reusing its id.
- **The user inventory is `~/Library/Application Support/Tenon/user-plugins/`** — a
  deliberately NEW name. Reusing the legacy `…/Tenon/plugins/` would resurrect five
  stale copies of bundled plugins (clock, browser, core-commands, file-explorer, git,
  frozen at Jul 24) as duplicate-id conflicts on the user's next launch.
- **`PluginHost.init(pluginsRoot:…)` stays** as a convenience wrapping one inventory.
  ~40 existing tests construct a host that way; changing them all on a shared tree
  would break every peer's suite for no behavioural gain.
- **`AutomationAuthoring` is handed the writable root, never the bundle** — this is
  the line that caused the incident.
- Consequence recorded, not hidden: an AI-authored automation that uses a `.policy`
  intent will prompt on first firing, and an unattended 3am firing will expire on
  T-050's bound rather than run. That is the correct posture (authority is earned, not
  inherited from where a file sits) and it is what the T-061 guide already warns about.

## Found while finishing (session 1d6e81a8, 2026-08-04)

**The second inventory could brick the host, and the doc already claimed it could not.**
`docs/design-automations.md` said "the earlier inventory wins any identity clash — a user
plugin cannot displace a bundled one by reusing its id", and the Decisions above say the
same. The code did not do it. Every identity rule in `validatePluginIdentities` **throws
out of `loadAll`**, so a clash did not cost the late plugin, it cost *every* plugin:
Tenon started with none. Measured, not read (each is a test in `PluginInventoryTests`):

- duplicate plugin id across inventories → `duplicatePluginID` thrown, host loads nothing;
- **duplicate directory *name* across inventories → the process traps.**
  `Swift/NativeDictionary.swift:792: Fatal error: Duplicate values for key: 'clock'` —
  `pluginIDByDirectory` is built with `uniqueKeysWithValues`, and a directory name is
  unique only *within* one root. Dropping a folder called `clock` into the user inventory
  crashed the app. This is the same shape as the reported incident, one rung louder;
- namespace overlap, and claiming the reserved `dev.tenon.core` prefix → thrown, host dead;
- a `provides` entry naming no contract — an ordinary agent typo — → thrown, host dead,
  because manifest *decoding* was the only failure the earlier work made non-fatal.

Not hypothetical: `~/Library/Application Support/Tenon/plugins/` still holds eight stale
copies of bundled plugins from Jul 24. Had the task reused that path as the user
inventory (the Decisions above rejected it for exactly this reason), the first launch
would have hit all eight clashes at once.

**A second single-root leftover, in the composition root.** `AppComposition.init` decides
whether a restored plugin-view pane still has a plugin behind it, and did so by walking
`pluginInventoryRoot` and reading `<entry>/manifest.json` by hand. It therefore knew only
the primary inventory and only the directory packaging: a restored pane belonging to a
user-written plugin (this task) or to a single-file automation (T-047) was silently
dropped at launch as if uninstalled. Replaced by `PluginLoader.discover` +
`loadManifest` — the one owner of "where plugins live and what counts as one". No new
test: the delegation removes a duplicate implementation, and the behaviour it now defers
to is already pinned by the discovery and single-file tests.

**Fix**: `PluginHost.admitByInventoryPrecedence` resolves clashes *before* validation by
yielding to the earlier inventory — first claim on an id, a directory name, or a
namespace wins, and only a **non-primary** plugin can be dropped. Survivors go to
`validatePluginIdentities` untouched, so a clash inside the shipped inventory still
throws: that one is a build error and worth stopping for. Preparation failures follow the
same rule as manifest failures. Each rejection is a named `PluginLoadFailure` with a
diagnostic saying what to rename.

## Criteria
- [x] Discovery returns plugins from every configured inventory, ordered, with the
      bundled one first — pinned headless with a mixed fixture
      (`testDiscoveryReturnsEveryInventoryWithThePrimaryFirst`)
- [x] A plugin from the bundled inventory gets standing consent; an identical plugin
      from the user inventory does NOT — pinned headless (this is the security rule)
      (`testOnlyTheHostControlledInventoryGrantsStandingConsent`)
- [x] `AppStatePaths` exposes a writable user inventory root, creates it if missing,
      and never reports the bundle as writable; `TENON_PLUGINS_DIR` keeps its current
      meaning and its exact-match trust flag — verified live: the app has already
      created `~/Library/Application Support/Tenon/user-plugins/`
- [x] `AutomationAuthoring` receives the writable root; a test proves the prompt can
      never name a path inside an app bundle —
      `testCreateWithAIStartsTheAgentOutsideTheAppBundle` drives the real
      `openAutomationAuthoringPane()` through a composition rooted at a fake
      `Tenon.app` and asserts the pane's spawn directory, which is the exact line
      that caused the incident (mutation M6)
- [x] A clash in the user inventory costs that plugin and nothing else; a clash inside
      the primary inventory still fails the load — 6 tests, mutations M1–M5
- [x] Full `swift test` green — **1006 / 0**
