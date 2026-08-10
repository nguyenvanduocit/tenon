# PRD — Application preferences and manifest-driven plugin settings

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-004` |
| Lifecycle | `shipped` |
| Owner | workspace-model and plugin-settings domains |
| Reviewers | product, native UI, accessibility, plugin runtime, persistence, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-002 |
| Acceptance specification | [`settings.feature`](settings.feature) |

## 1. Executive summary

### Problem and outcome

Tenon needs app-wide personalization without scattering defaults through view code, and
plugins need configurable behavior without plugin-specific Swift UI. App preferences are a
pure leniently decoded value persisted as one UserDefaults JSON blob. The shell injects
those values into workspace creation, sidebar startup, theme, and automation policy. Plugin
manifests declare scalar settings; one generic native form validates and persists overrides
per installation, then publishes `settings.changed` to the current runtime.

T-002's original “General / Browser / Plugins tabs” UI description is superseded. Current
Settings is a flat macOS source list: General, one entry per plugin declaring settings,
Automation, CLI, and Extensions. Browser settings are simply the browser plugin's manifest
page. This keeps the original product capability while removing a hardcoded browser owner.

### Why now

Settings influences pane defaults, width, accent, sidebar restoration, automation, CLI, and
every bundled/user plugin. A canonical PRD prevents future work from adding a second store,
hardcoded plugin form, or stale Browser tab.

## 2. Discovery record

| Evidence | Confidence | Establishes |
|---|---|---|
| [`AppPreferences.swift`](../../Sources/TenonCore/AppPreferences.swift), [`AppPreferencesStore.swift`](../../Sources/TenonApp/AppPreferencesStore.swift) | high | pure defaults, lenient decode, UserDefaults persistence, theme/schedule revisions |
| [`SettingsView.swift`](../../Sources/TenonApp/SettingsView.swift) | high | current source-list routes and generic controls |
| [`PluginManifest.swift`](../../Sources/TenonCore/PluginManifest.swift), [`PluginHost.swift`](../../Sources/TenonCore/PluginHost.swift) | high | setting schema, validation, lifecycle, event delivery |
| [`SettingsStore.swift`](../../Sources/TenonCore/SettingsStore.swift) | high | per-installation bounded locked atomic persistence |
| preference/settings tests | high | mapping, compatibility, schema, identity, corruption, limits |
| T-002 | medium | original capability and historical visual receipt |

Open evidence gap: the original task still records the redesigned Settings window as
human-visual pending. Source and semantic tests are current; a design change still requires
the normative screenshot/appearance verification in `docs/designs.md`.

## 3. Users and jobs

The primary user personalizes how workspaces open and configures plugins from one native
window. Plugin authors declare typed settings once and read them locally through
`tenon.settings.get`. Operators also inspect versions, permissions, lifecycle errors,
automation delivery policy, and CLI installation status without mixing those operations
into General.

## 4. Goals and measures

- `SET-G-001` — One typed value owns every app preference and compatible default.
- `SET-G-002` — One generic renderer owns every plugin setting control.
- `SET-G-003` — Persistence is installation-scoped, atomic, bounded, and fail-honest.
- `SET-G-004` — Settings navigation follows current product ownership rather than hardcoded
  plugin brands.

Success means workspace creation uses configured content/width, launch honors sidebar
settings, accent updates immediately, an old preference blob loads with new defaults, an
invalid plugin value cannot persist, and a failed write cannot publish optimistic state.

## 5. Scope

### In scope

- Default new tab/split/workspace content and maximum new-pane width.
- Sidebar visible-on-launch/default width and host accent.
- Global automation schedule enable and per-schedule pause persistence.
- General/About, Automation, CLI, manifest plugin pages, and Extensions routes.
- Plugin string/boolean/number/select specs, grouping, defaults, validation, persistence,
  runtime reads, changed event, enable state, permissions, and errors.

### Non-goals

- Terminal color configuration; Ghostty owns terminal cells.
- A hardcoded Browser settings page or any plugin-specific Swift settings UI.
- Operational automation authoring/history (PRD-013), CLI protocol (PRD-007), or plugin
  permission/runtime architecture (PRD-010); Settings only presents their owned controls.
- Secrets in ordinary plugin settings; secret storage has its own facility.

## 6. User experience

Command-comma or the sidebar Settings action opens a `NavigationSplitView`. General controls
new panes, sidebar, appearance, and current version. Each plugin with manifest settings gets
one flat entry. Automation contains global scheduled-delivery policy; CLI installs or
reports the channel-appropriate command; Extensions lists all plugins, enable state,
permissions, unknown permissions, and errors.

Plugin controls are chosen entirely from manifest type. Boolean is Toggle; string and
number commit from text fields; select uses declared options and degrades to a text field
when a malformed spec omits them. Controls show loading/saving state. A failed save restores
the previous value and exposes an error. Removing the selected plugin falls back to General.

## 7. Requirements

### Functional requirements

- `SET-FR-001` — `AppPreferences` MUST be a pure Codable value with explicit defaults.
- `SET-FR-002` — New tab, split, and workspace MUST resolve their independently configured `DefaultPaneContent` through one pure mapping.
- `SET-FR-003` — Files and Browser defaults MUST resolve to bundled plugin views; they MUST NOT create host content cases.
- `SET-FR-004` — New-pane maximum width MUST apply only at creation; changing it MUST NOT resize existing panes.
- `SET-FR-005` — Sidebar visible-on-launch and width MUST initialize shell state; live user resizing MAY diverge until next launch preference use.
- `SET-FR-006` — Accent selection MUST update Tenon chrome immediately and persist; terminal palette MUST remain unchanged.
- `SET-FR-007` — Automation global enabled and per-schedule paused keys MUST persist and advance only their relevant process-local policy revisions.
- `SET-FR-008` — App preferences MUST persist as one JSON blob under `app.preferences` and fall back completely to defaults if the blob is unreadable.
- `SET-FR-009` — Missing fields in an older blob MUST decode to current defaults; an unknown pane-width value MUST degrade to no maximum without failing other fields.
- `SET-FR-010` — Settings navigation MUST contain General, manifest-declared plugin pages, Automation, CLI, and Extensions in one flat source list.
- `SET-FR-011` — General MUST present new-pane defaults/width, sidebar startup/width, host accent, and selectable current app version.
- `SET-FR-012` — Browser configuration MUST be rendered from the browser plugin manifest, not a hardcoded Browser route.
- `SET-FR-013` — A plugin page MUST group specs by first-seen optional group while preserving manifest order.
- `SET-FR-014` — Generic controls MUST support string, boolean, number, and select; select MUST persist only a declared option.
- `SET-FR-015` — Plugin setting load MUST use persisted override then manifest default; runtime `tenon.settings.get` MUST see the same effective value.
- `SET-FR-016` — Save MUST validate the key is declared and value type/options match before atomically persisting per installation.
- `SET-FR-017` — Successful save MUST emit `settings.changed {key,value}` to the running installation; a stopped plugin still persists the override without an event.
- `SET-FR-018` — Failed save MUST restore the previous UI value and show an error; it MUST NOT publish uncommitted actor state.
- `SET-FR-019` — Extensions and plugin pages MUST show enable state, permissions, violations/errors, and serialize enable/disable lifecycle operations.
- `SET-FR-020` — If a selected plugin disappears, detail MUST fail-soft to General.

### Non-functional requirements

- `SET-NFR-001` — Settings MUST follow [`designs.md`](../designs.md), grouped Form/native source-list conventions, and existing semantic colors.
- `SET-NFR-002` — Plugin settings UI MUST be generic; adding a manifest setting MUST require no feature-specific Swift view.
- `SET-NFR-003` — Settings values MUST remain JSON scalar IntentValues; keys, entries, installations, and document bytes MUST obey `PluginValueStoreLimits`.
- `SET-NFR-004` — Plugin settings persistence MUST lock, version, validate, and atomically replace; write failure MUST leave prior memory/disk truth.
- `SET-NFR-005` — Settings MUST be scoped to stable plugin installation identity; trust-class rotation/uninstall MUST not leak another installation's overrides.
- `SET-NFR-006` — `tenon.settings` MUST remain the closed plugin-private SCOPED FACILITY: non-routable, non-discoverable, capability-free, and tied to runtime installation.
- `SET-NFR-007` — All controls MUST have labels, keyboard behavior, progress/error state, and non-color accessibility meaning.
- `SET-NFR-008` — Settings status reads/CLI install work MUST avoid filesystem/process I/O from SwiftUI `body` or MainActor blocking paths.

## 8. Acceptance specification

[`settings.feature`](settings.feature) maps every requirement bidirectionally. Any Settings
visual change also requires the appearance/contrast/screenshot verification in
`docs/designs.md`; current semantic behavior is shipped.

## 9. Architecture and lifecycle

Native UI calls AppPreferencesStore/PluginHost DIRECT. Manifest specs are CONTRIBUTION.
`settings.changed` is an EVENT. `tenon.settings.get` is a SCOPED FACILITY, not an intent.
App preferences belong to app identity in UserDefaults; plugin overrides belong to
`PluginInstallationKey` in `.settings.json`. Runtime local state receives effective values
at activation and the changed event updates its owned configuration thereafter.

Default store bounds are 256-byte keys, 1,024 entries per installation, 16,384 total
entries, 4,096 installations, and an 8 MiB document (64 MiB hard maximum). Invalid version,
duplicates, corrupt data, oversize, or persistence failures are explicit errors.

## 10. Delivery and compatibility

All requirements are current-source shipped. Continue regression testing pure preference
mapping/decoding, generic schema validation, persistence identity/limits, and hosted Settings
semantics. T-002's hardcoded Browser tab and old tabbed layout are superseded by the flat
source list and manifest-driven browser settings.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| plugin-specific settings creep | generic manifest renderer only |
| old blob breaks launch | field-by-field lenient decode/full default fallback |
| optimistic failed save | copy/validate/write before publish; UI rollback |
| trust/uninstall leaks overrides | installation identity and removal |
| accent misstates status | accent limited to chrome identity/focus; semantic status colors remain fixed |

## 12. Decisions

| Date | Decision | Supersedes |
|---|---|---|
| 2026-08-09 | flat source-list Settings is canonical | T-002 General/Browser/Plugins tabs |
| 2026-08-09 | Browser settings are plugin manifest settings | hardcoded Browser page |
| 2026-08-09 | app and plugin settings use separate stores/identities | one undifferentiated preferences store |

## 13. Verification receipts

Current focused suites: `AppPreferencesTests`, `WorkspaceDefaultContentTests`,
`PluginSettingsSchemaTests`, plugin persistence/identity/limits tests, builtins changed-event
tests, CLI installer state tests, and interaction-boundary fitness tests. Human visual review
remains required only when native Settings appearance changes.

## 14. Change history

| Date | Author | Change |
|---|---|---|
| 2026-08-09 | Codex | Reconciled T-002 with current manifest-driven source-list Settings. |
