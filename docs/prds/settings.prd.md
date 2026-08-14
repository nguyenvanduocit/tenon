# PRD — Application preferences and manifest-driven plugin settings

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-004` |
| Lifecycle | `shipped` |
| Owner | workspace-model, plugin-settings, and companion domains |
| Reviewers | product, native UI, accessibility, plugin runtime, persistence, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-13 |
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

Host-owned AI assistance has one additional app preference concept: Companion. Its profile
stores the selected installed coding agent, optional model, bounded custom instructions, and
an optional working directory. Tasks snapshot that profile when they start and retain
ownership of their own schema, input/output limits, timeout, and cancellation.

T-002's original “General / Browser / Plugins tabs” UI description is superseded. Current
Settings is a flat macOS source list: General, Companion, one entry per plugin declaring settings,
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
- Companion agent/model/instructions/working-folder defaults for host-native AI helpers.
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
one flat entry. Companion selects the reusable host AI profile and reports whether its agent
is installed. Automation contains global scheduled-delivery policy; CLI installs or
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
- `SET-FR-004` — The pane maximum width MUST cap future pane creation and automatic horizontal growth after a pane closes. Changing it alone MUST NOT resize existing panes, and manual resize MUST remain able to exceed it.
- `SET-FR-005` — Sidebar visible-on-launch and width MUST initialize shell state; live user resizing MAY diverge until next launch preference use.
- `SET-FR-006` — Accent selection MUST update Tenon chrome immediately and persist; terminal palette MUST remain unchanged.
- `SET-FR-007` — Automation global enabled and per-schedule paused keys MUST persist and advance only their relevant process-local policy revisions.
- `SET-FR-008` — App preferences MUST persist as one JSON blob under `app.preferences` and fall back completely to defaults if the blob is unreadable.
- `SET-FR-009` — Missing fields in an older blob MUST decode to current defaults; an unknown pane-width value MUST degrade to no maximum without failing other fields.
- `SET-FR-010` — Settings navigation MUST contain General, Companion, manifest-declared plugin pages, Automation, Permissions, CLI, and Extensions in one flat source list.
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
- `SET-FR-021` — Permissions MUST present one switch governing whether the host answers permission confirmations itself, defaulting to on, persisted in the app preferences blob, and decoding to that default when an older blob omits it.
- `SET-FR-022` — With the switch on, every confirmation — `.policy` and `.always` alike — MUST be approved without presenting UI, and the approval MUST be wave-local so that turning the switch off restores asking with no consent record written while it was on.
- `SET-FR-023` — The switch MUST govern permission confirmations only; a plugin's own `ui.confirm` interaction MUST still be presented.
- `SET-FR-024` — The Permissions page MUST state, in the page, what the switch surrenders for plugins outside the bundled inventory and what policy checks still run regardless of it.
- `SET-FR-025` — Settings navigation MUST expose one host-owned Companion page distinct from plugin settings and interactive agent launch.
- `SET-FR-026` — `AppPreferences` MUST persist one `CompanionProfile` containing agent, optional model, custom prompt, and optional working directory; an older document MUST gain Claude + Haiku defaults without losing any existing preference.
- `SET-FR-027` — Companion MUST offer every host-supported `AgentCLI`, report whether the selected executable is installed, and leave a missing executable selected so the next task fails honestly rather than silently changing providers. Changing providers MUST restore that provider's compatible default model rather than carry the previous provider's model into the next run.
- `SET-FR-028` — Clearing Model MUST mean the provider's configured default; custom prompt MUST be capped at 8 KiB and working directory at 4 KiB.
- `SET-FR-029` — A Companion-backed task MUST snapshot the profile when it starts; a Settings edit during a run MUST affect only the next run.
- `SET-FR-030` — Settings navigation MUST expose one host-owned Agent Harness page, distinct from CLI, that installs Tenon's briefing into the global agent instruction files this machine's agents already read at session start.
- `SET-FR-031` — The briefing MUST be delimited by Tenon's own markers inside `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Bytes outside those markers MUST survive install, reinstall, and removal unchanged, and reinstalling MUST replace the existing block rather than append a second one. A Claude skill file is owned by Tenon end to end and MAY be written and deleted whole.
- `SET-FR-032` — Installing when every target already carries the current briefing MUST change no file; the page MUST distinguish absent, current, and outdated and MUST name the exact paths it writes before the operator presses anything.
- `SET-FR-033` — The page MUST offer removal beside installation, and removal MUST take only Tenon's own block and its own skill file.
- `SET-FR-034` — Every environment variable and every intent id the briefing prints MUST exist in the shipping build: variables in `TerminalPaneEnvironment`, intent ids in `CoreIntentCatalog`.

### Non-functional requirements

- `SET-NFR-001` — Settings MUST follow [`designs.md`](../designs.md), grouped Form/native source-list conventions, and existing semantic colors.
- `SET-NFR-002` — Plugin settings UI MUST be generic; adding a manifest setting MUST require no feature-specific Swift view.
- `SET-NFR-003` — Settings values MUST remain JSON scalar IntentValues; keys, entries, installations, and document bytes MUST obey `PluginValueStoreLimits`.
- `SET-NFR-004` — Plugin settings persistence MUST lock, version, validate, and atomically replace; write failure MUST leave prior memory/disk truth.
- `SET-NFR-005` — Settings MUST be scoped to stable plugin installation identity; trust-class rotation/uninstall MUST not leak another installation's overrides.
- `SET-NFR-006` — `tenon.settings` MUST remain the closed plugin-private SCOPED FACILITY: non-routable, non-discoverable, capability-free, and tied to runtime installation.
- `SET-NFR-007` — All controls MUST have labels, keyboard behavior, progress/error state, and non-color accessibility meaning.
- `SET-NFR-008` — Settings status reads/CLI install work MUST avoid filesystem/process I/O from SwiftUI `body` or MainActor blocking paths.
- `SET-NFR-009` — The permission answer MUST be read from the preferences store when a confirmation arrives rather than cached in presentation state, so a change in Settings governs the next request with no synchronization step that can drift.
- `SET-NFR-010` — Agent detection for Companion availability MUST run outside SwiftUI `body` and off blocking `MainActor` paths; the form MUST render captured observable state only.
- `SET-NFR-011` — Provider adapters MUST consume their documented machine-readable output channels. Raw terminal rendering and stderr MUST NOT be accepted as an AI task result.

## 8. Acceptance specification

[`settings.feature`](settings.feature) maps every requirement bidirectionally. Any Settings
visual change also requires the appearance/contrast/screenshot verification in
`docs/designs.md`; current semantic behavior is shipped.

## 9. Architecture and lifecycle

Native UI calls AppPreferencesStore/PluginHost DIRECT. Companion settings are the same typed
DIRECT app-preference path and mint no principal. Manifest specs are CONTRIBUTION.
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
| every AI feature grows vendor knobs | one Companion profile supplies defaults; each task owns only its schema and lifecycle |
| provider prose is mistaken for structured output | adapters accept Claude JSON or Codex JSONL agent-message events only, then validate the task schema |

## 12. Decisions

| Date | Decision | Supersedes |
|---|---|---|
| 2026-08-09 | flat source-list Settings is canonical | T-002 General/Browser/Plugins tabs |
| 2026-08-09 | Browser settings are plugin manifest settings | hardcoded Browser page |
| 2026-08-09 | app and plugin settings use separate stores/identities | one undifferentiated preferences store |
| 2026-08-11 | a Permissions page carries one switch that answers every confirmation, on by default, chosen by the product owner with its consequence stated: a plugin outside the bundled inventory then runs its declared contracts unasked, which is what `PRT-FR-006`/`PRT-FR-022` were written to prevent. Recorded rather than re-argued. | permission confirmation as the only path, with no operator control over it |
| 2026-08-13 | Companion is one app-wide provider/model/prompt/folder default, snapshotted per host-owned AI task. Visible per-run controls remain overrides. | provider and model literals repeated inside each helper feature |
| 2026-08-13 | The pane-width preference also caps automatic horizontal close absorption, while changing the preference alone and manual resize leave committed panes untouched. | creation-only sizing let close reflow immediately widen a pane past the same configured maximum |
| 2026-08-14 | The Agent Harness page ships together with the capability its briefing describes. The operator asked for the page alone; a survey of `CoreIntentName` found no intent exposing `Workspace.renameSlot` and no `tenon-cli` verb for it, so instructions installed into every agent session on the machine would have taught a command that fails. `workspace.pane.title.set.v1` and `tenon-cli rename` were built in the same change, and `SET-FR-034` is the standing check that the briefing keeps describing a build that exists. | installing a briefing written against `TENON_PANEL_ID`/`TENON_TAB_ID` and a rename route, none of which existed |

## 13. Verification receipts

2026-08-11 (T-130): `swift test --filter PermissionBypassTests` — 10 tests, 0 failures, over
the real `CoreIntentCatalog` contracts in both confirmation modes. Mutation-checked:
returning `.alwaysAllow` instead of `.allowOnce` from the standing answer fails 3 of them.
The Permissions page itself has no offscreen snapshot — Settings is a window scene and
`PaneViewSnapshotWriter` photographs panes — so its layout is unverified by machine.

Current focused suites: `AppPreferencesTests`, `WorkspaceDefaultContentTests`,
`PluginSettingsSchemaTests`, plugin persistence/identity/limits tests, builtins changed-event
tests, CLI installer state tests, and interaction-boundary fitness tests. Human visual review
remains required only when native Settings appearance changes.

2026-08-13 (automatic pane-width close absorption): the shipping General detail rendered at
540×660 in dark appearance through `NSHostingView`. Visual inspection found the new automatic-
width label and wrapped explanation readable without clipping, with all following sections still
visible; PNG SHA-256 `0af94d3ee26474286b6eac1bc66dcdff5903137c8bf34e99eac6ccb9798b23b9`.
The in-process accessibility hit-test exposed the control as `AXPopUpButton` with value
`As wide as it fits`; the picker also publishes an explicit label and close-behavior hint.
The outer SwiftUI hierarchy remained collapsed in the offscreen probe, and System Events denied
the shell assistive access (`-25211`), so a full external accessibility-hierarchy receipt remains
pending rather than being inferred from the screenshot.

2026-08-13 (Companion): `AppPreferencesTests` pins compatible Claude + Haiku defaults,
provider-switch model reset, round trips, unknown-provider isolation, and all free-text byte
ceilings. `PaneRenameTests`
pins Claude JSON/schema and Codex JSONL `item.completed/agent_message` channels, rejects a
plain JSON object outside the Codex event channel, and drives a fake Codex executable end to
end. Companion availability uses executable-only lookup; interactive shell-history parsing
remains isolated to agent-launch suggestions. `TENON_COMPANION_SETTINGS_SNAPSHOT=/tmp/tenon-companion-settings.png swift run tenon`
rendered the shipping detail at 540×660 through `NSHostingView`; visual inspection found the
agent/model/availability, folder, prompt editor, byte count, disclosure, and controls visible
without clipping, using the native grouped form and Tenon semantic surfaces.

2026-08-14 (T-147, Agent Harness): `swift test --filter "AgentHarness"` — 11 tests, 0
failures, over a temp home directory rather than the running operator's configuration.
`AgentHarnessInstallerTests` proves `SET-FR-031`…`033` directly: text a person wrote above and
below the markers is byte-identical after a reinstall that replaced a stale briefing between
them, a second install reports `alreadyCurrent` and rewrites nothing, and removal leaves the
person's text with no marker and no skill file. `AgentHarnessTextTests` is `SET-FR-034`: it
regex-extracts every `*.v1` id the briefing prints and fails unless each is in
`CoreIntentName.allCases`, and asserts the absence of `TENON_PANEL_ID`, which the operator
named and Tenon has never exported. Full suite 2203 / 0. The page itself has no offscreen
snapshot for the reason `SET-FR-021`'s receipt already records — Settings is a window scene —
so its layout remains unverified by machine.

## 14. Change history

| Date | Author | Change |
|---|---|---|
| 2026-08-09 | Codex | Reconciled T-002 with current manifest-driven source-list Settings. |
| 2026-08-11 | Claude | T-130: added the Permissions page and its switch (`SET-FR-021`…`024`, `SET-NFR-009`). |
| 2026-08-13 | Codex | Added Companion settings and machine-readable Claude/Codex task adapters (`SET-FR-025`…`029`, `SET-NFR-010`…`011`). |
| 2026-08-13 | Codex | Centralized structured-output provider adapters, restored provider-compatible models on agent changes, and removed shell-history reads from Companion availability checks. |
| 2026-08-13 | Codex | Extended the pane-width preference to govern automatic horizontal close absorption while preserving manual resize freedom. |
| 2026-08-14 | Claude | T-147: added the Agent Harness page and the briefing installer (`SET-FR-030`…`034`), shipped alongside `workspace.pane.title.set.v1` so the installed instructions describe a capability that exists. |
