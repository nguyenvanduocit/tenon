# PRD — Browser surfaces, web links, and open-handler choice

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-006` |
| Lifecycle | `partial` |
| Owner | plugin-contributions, terminal-surface, intent-bus, plugin-host, and agent-lens domains |
| Reviewers | product, native UI, accessibility, security/privacy, plugin runtime, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-005, T-070, T-071, T-072, T-073, T-077 |
| Existing design | [`design-open-handlers.md`](../design-open-handlers.md) |
| Acceptance specification | [`browser-and-open.feature`](browser-and-open.feature) |

## 1. Executive summary

### Problem

Tenon has a working plugin-owned browser pane and a trusted system URL opener, but it does
not yet connect them through one user-selected open-handler flow. A web link in Agent Lens
still returns SwiftUI's `.systemAction`; the Browser plugin still provides its private
`dev.tenon.browser.open.v1` action rather than `url.open.v1`; and the persisted approval,
resolver, and configured-default primitives have no complete product UI. Consequently the
location of a click still determines where an address opens, despite the accepted decision
that the person's handler choice must govern every caller.

### Proposed outcome

The bundled Browser remains an ordinary JavaScript plugin whose declarative pane is backed
by a host-owned, installation-scoped WKWebView. Browser navigation is bounded to absolute
HTTP(S), emits facts, uses a truthful Safari product token, and disposes surfaces and data
at their defined lifetimes. Agent prose recognizes safe web links without weakening file
links.

Every openable kind is a typed `open` contract. Built-in SwiftUI calls one typed application
opener DIRECT; plugin, CLI, and agent adapters invoke the public intent. The same resolver
applies explicit choice, remembered default, trusted default, eligibility, approval, and
visible failure. There is no generic app intent principal.

### Why now

The current documentation says both “built and dormant” and “wired to an empty approval
set,” while current source now persists real approvals but still lacks the user workflow.
This audit separates shipped infrastructure from pending product behavior so subsequent
work cannot mistake a helper type or passing unit test for a completed user outcome.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| browser manifest/runtime | [`plugins/browser`](../../plugins/browser) | high | plugin ownership, pane toolbar, settings, private open action |
| native surface | [`PluginWebSurfacePool.swift`](../../Sources/TenonApp/PluginWebSurfacePool.swift), [`WebUserAgent.swift`](../../Sources/TenonApp/WebUserAgent.swift) | high | WKWebView ownership, navigation rules, profile lifetime, UA |
| link rendering | [`AgentLensMarkdown.swift`](../../Sources/TenonApp/AgentLensMarkdown.swift), [`AgentLensView.swift`](../../Sources/TenonApp/AgentLensView.swift) | high | link recognition ships; HTTP(S) activation still delegates to system action |
| open contracts | [`CoreIntentCatalog.swift`](../../Sources/TenonCore/CoreIntentCatalog.swift), [`SystemIntentProvider.swift`](../../Sources/TenonApp/SystemIntentProvider.swift) | high | typed URL contract and trusted system provider |
| resolver/approval | [`ProviderRegistry.swift`](../../Sources/TenonIntentCore/ProviderRegistry.swift), [`OpenHandlerApprovals.swift`](../../Sources/TenonCore/OpenHandlerApprovals.swift), [`TenonApp.swift`](../../Sources/TenonApp/TenonApp.swift) | high | query-only decision, defaults, real persisted approval gate |
| accepted design/tasks | [`design-open-handlers.md`](../design-open-handlers.md), T-005/T-070…T-077 | medium | intended full user flow; some implementation statements have drifted |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| Core problem? | Open web content inside or outside Tenon according to one explicit user choice. | accepted design |
| Primary users? | Operators reading agent output or browsing beside terminals; public plugin/CLI/agent callers. | current surfaces |
| Success? | The same URL and choice produce one result regardless of entry point, with no silent failure. | acceptance spec |
| Fixed constraints? | closed audiences, DIRECT built-in entry, explicit plugin approval, exact HTTP(S) schema, native host ownership | normative architecture |
| Unknown? | final chooser placement/copy and installed-app compatibility evidence | open product work |

### Assumptions to validate

| ID | Assumption | Validation method | State |
|---|---|---|---|
| `BO-A-001` | Users want the internal Browser as a general URL handler. | opt-in/choice observation | unresolved |
| `BO-A-002` | A Settings approval row plus on-demand chooser explains the privacy boundary. | usability/accessibility review | unresolved |
| `BO-A-003` | Safari product tokens avoid important unsupported-browser routing without site regressions. | real-site matrix | headless rule proven; live evidence owed |

## 3. Users and jobs

### Primary user

An operator supervising work in Agent Lens and terminal panes who needs a cited address to
open exactly once in the place they chose, while retaining their current spatial context.

### Secondary users and affected actors

- Plugin authors offering an open handler or a caller-owned web surface.
- CLI and agent callers invoking the programmatic URL contract.
- Accessibility users operating browser chrome, approval rows, and choosers by keyboard or
  VoiceOver.
- Privacy reviewers protecting the complete addresses exposed to third-party handlers.

### Jobs to be done

- Open a link from agent output in my chosen handler without learning entry-point quirks.
- Browse inside a pane with normal address, search, history, reload, popup, and session behavior.
- Inspect and revoke which plugin may see the things I open.
- Recover through the system handler when a plugin handler disappears or becomes unhealthy.

### Product vocabulary

| Term | Meaning | Not to be confused with |
|---|---|---|
| Browser | bundled `dev.tenon.browser` plugin | a host-native Browser content case |
| Web surface | host-owned WKWebView addressed by installation and surface ID | plugin-owned native object |
| Offer | unapproved declaration that a plugin can handle an open contract | active provider binding |
| Approval | persisted `(pluginID, intentID)` grant | default handler choice |
| Trusted default | built-in system opener | configured user default |

## 4. Goals and success measures

### Goals

- `BO-G-001` — Browser is useful while retaining the plugin/native ownership boundary.
- `BO-G-002` — Link detection is safe and activation follows one handler policy.
- `BO-G-003` — Approval, choice, defaults, revocation, and fallback are understandable and enforceable.
- `BO-G-004` — Web surfaces have deterministic navigation, privacy, and teardown rules.

### Success metrics

| ID | Metric | Target | Measurement |
|---|---|---|---|
| `BO-M-001` | one accepted link gesture causing zero or multiple opens | zero | integration/UI tests |
| `BO-M-002` | unapproved plugin receiving an opened address | zero | activation/policy tests |
| `BO-M-003` | qualifying entry points bypassing configured choice | zero | cross-entry acceptance matrix |
| `BO-M-004` | disposed/uninstalled web surfaces retained | zero | hosted lifecycle tests |
| `BO-M-005` | third-party iframe popup replacing top-level page | zero | hosted WebKit test |

### Guardrail metrics

| ID | Limit | Value |
|---|---|---|
| `BO-GM-001` | URL input | absolute HTTP(S), nonempty host, no embedded credentials, catalog encoded bounds |
| `BO-GM-002` | open dispatch timeout | 15 seconds |
| `BO-GM-003` | browser surface execution | serial browser lane |
| `BO-GM-004` | persisted web data | one WKWebsiteDataStore per plugin installation; removed on uninstall |

## 5. Scope

### In scope

- Browser plugin discovery, settings, instanced pane state, toolbar, search/address resolution.
- Host web-surface intent provider, navigation events, persistent profile, popup and UA policy.
- Agent Lens file/remote/bare/backticked link recognition and link activation.
- `url.open.v1`, trusted system provider, provider resolution, approvals, chooser/default policy.
- Principal/audience rules and observable denial/failure behavior.

### Non-goals

- A host-native Browser slot or plugin access to WKWebView/native objects.
- Generic MIME/scheme intent filters; each openable kind remains an exact contract.
- Local HTML preview browsing; PRD-008 owns its network-free renderer.
- Restoring browser sessions as workspace content beyond the installed plugin's current model.

### Later possibilities

- Additional typed open contracts that reuse the same approval/chooser mechanism.
- Browser downloads, uploads, dialogs, or multiple-window behavior under separate designs.

## 6. User experience

### Entry points and primary flow

The launcher opens Browser through the plugin's palette contribution. Each pane shows Back,
Forward, Reload, and one flexible address field in the existing 34-point pane header. A
blank submission is ignored; a hostname gains HTTPS; other text becomes an encoded search.
Navigations update the address from `web.did-navigate`.

A link activation asks the typed host opener for a resolution decision. A remembered
eligible default wins. Otherwise the trusted system handler is available, and multiple
eligible alternatives require a chooser. “Just once” targets that request; “Always” also
stores the selected provider. Cancellation preserves the current pane and default.

### Alternate and edge flows

- Invalid/non-HTTP(S) input is refused without creating or redirecting a surface.
- A refused private Browser open clears its one-shot pending address.
- A disabled, draining, or quarantined provider is ineligible; a stale configured default
  cannot swallow the click.
- A plugin failure or timeout is visible on the initiating gesture and permits safe retry.
- Revocation retires the binding and configured default; uninstall also removes approval
  and the installation website data store.

### Accessibility and input parity

Browser header controls, approval rows, and chooser options MUST expose native labels,
focus, keyboard activation, VoiceOver order, increased contrast, and reduced-motion-safe
feedback. Choice MUST never depend only on icon, color, hover, or pointer drag.

## 7. Requirements

### Functional requirements

| ID | Requirement | Priority | Delivery | Acceptance reference |
|---|---|---|---|---|
| `BO-FR-001` | Browser **MUST** remain a bundled JavaScript plugin with no host-native Browser content/config store. | must | shipped | `@req-bo-fr-001` |
| `BO-FR-002` | Its manifest **MUST** declare the Browser view, launcher action, `homeURL`, and search-engine settings through shared plugin contracts. | must | shipped | `@req-bo-fr-002` |
| `BO-FR-003` | Every open Browser pane **MUST** have instance-local address state and one matching surface ID. | must | shipped | `@req-bo-fr-003` |
| `BO-FR-004` | The pane header **MUST** expose Back, Forward, Reload, and a flexible address/search field using host-native chrome. | must | shipped | `@req-bo-fr-004` |
| `BO-FR-005` | Address resolution **MUST** ignore blank input, preserve explicit schemes for validation, add HTTPS to host-like input, and encode other input with the configured search engine. | must | shipped | `@req-bo-fr-005` |
| `BO-FR-006` | Browser open **MUST** stage an optional resolved address for exactly the next created Browser pane and clear it on success or failure. | must | shipped | `@req-bo-fr-006` |
| `BO-FR-007` | Browser surface operations **MUST** be plugin-only intents scoped to the caller's installation and surface ID. | must | shipped | `@req-bo-fr-007` |
| `BO-FR-008` | Top-level loads **MUST** accept only absolute HTTP(S) URLs with a host and without embedded credentials. | must | shipped | `@req-bo-fr-008` |
| `BO-FR-009` | Surface changes **MUST** emit title, location, and loading facts; Browser **MUST** reflect navigation location in its field. | must | shipped | `@req-bo-fr-009` |
| `BO-FR-010` | A main-frame popup **MUST** load in the same pane only when its target passes top-level policy; a subframe popup **MUST** be declined. | must | shipped | `@req-bo-fr-010` |
| `BO-FR-011` | Browser web views **MUST** append Tenon's versioned Safari product token through `applicationNameForUserAgent`, never replace WebKit's whole UA. | must | shipped | `@req-bo-fr-011` |
| `BO-FR-012` | Closing a pane or disabling a plugin **MUST** release its surface; uninstall **MUST** also retire its installation-scoped website data store. | must | shipped | `@req-bo-fr-012` |
| `BO-FR-013` | Agent prose **MUST** retain written and bare remote links and turn only absolute HTTP(S) code spans into web links. | must | shipped | `@req-bo-fr-013` |
| `BO-FR-014` | A resolving file path **MUST** remain a file link and outrank web-address inference; invalid, credentialed, or non-HTTP(S) spans **MUST** remain plain. | must | shipped | `@req-bo-fr-014` |
| `BO-FR-015` | `url.open.v1` **MUST** take one bounded absolute HTTP(S) URL and retain the programmatic `{plugin, cli, agent}` audience. | must | shipped | `@req-bo-fr-015` |
| `BO-FR-016` | The trusted URL provider **MUST** revalidate URL and authorized host before asking NSWorkspace to open it. | must | shipped | `@req-bo-fr-016` |
| `BO-FR-017` | Resolution **MUST** use one rule: explicit target, eligible configured default, eligible trusted default, allowed sole candidate, then sorted choice/no provider. | must | shipped | `@req-bo-fr-017` |
| `BO-FR-018` | A resolution query **MUST NOT** reserve, lease, mutate, or hold a provider generation. | must | shipped | `@req-bo-fr-018` |
| `BO-FR-019` | Resolution **MUST** exclude inactive, draining, unexported, and unhealthy providers and clear defaults when their provider retires. | must | shipped | `@req-bo-fr-019` |
| `BO-FR-020` | An open-handler approval **MUST** persist per exact plugin/contract pair; no installation, including bundled installation, grants it implicitly. | must | partial | `@req-bo-fr-020` |
| `BO-FR-021` | Unapproved open declarations **MUST** remain inert offers; approval **MUST** bind only a contract the same manifest declares. | must | shipped | `@req-bo-fr-021` |
| `BO-FR-022` | Agent calls selecting a non-trusted open provider **MUST** require confirmation for each call rather than gain standing consent. | must | shipped | `@req-bo-fr-022` |
| `BO-FR-023` | Built-in UI **MUST** call one typed opener DIRECT, and public provider adapters **MUST** call the same application service without a generic app principal. | must | planned | `@req-bo-fr-023` |
| `BO-FR-024` | Agent Lens HTTP(S) activation **MUST** use that opener and produce exactly one resolved open, replacing `.systemAction`. | must | planned | `@req-bo-fr-024` |
| `BO-FR-025` | Browser **MUST** offer `url.open.v1`; it **MUST NOT** bind or receive addresses until the person approves that pair. | must | planned | `@req-bo-fr-025` |
| `BO-FR-026` | Settings **MUST** list truthful handler offers and allow grant, revoke, and uninstall cleanup with immediate runtime effect. | must | planned | `@req-bo-fr-026` |
| `BO-FR-027` | Multiple eligible handlers **MUST** present an accessible Just once/Always chooser; Always **MUST** store the configured default and cancellation **MUST** preserve state. | must | planned | `@req-bo-fr-027` |
| `BO-FR-028` | Handler refusal, invalid output, failure, and timeout **MUST** be visible at the initiating gesture and **MUST NOT** silently double-open elsewhere. | must | planned | `@req-bo-fr-028` |
| `BO-FR-029` | A second typed openable kind **MUST** prove approval, chooser, default, revocation, and fallback are shared rather than browser-specific. | should | planned | `@req-bo-fr-029` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `BO-NFR-001` | native design | Host chrome, Settings, chooser, and failure UI **MUST** use `docs/designs.md` tokens/components without feature-local tokens. | partial | `@req-bo-nfr-001` |
| `BO-NFR-002` | security | Plugins **MUST NOT** receive WKWebView/native objects; surface IDs plus capability-scoped intents are the only boundary. | shipped | `@req-bo-nfr-002` |
| `BO-NFR-003` | privacy | Persistent website data and handler approvals **MUST** be installation/person scoped and removed at uninstall as specified. | partial | `@req-bo-nfr-003` |
| `BO-NFR-004` | lifecycle | Web views **MUST** be MainActor-owned, settle navigation state, and synchronously sever delegates/owners at disposal. | shipped | `@req-bo-nfr-004` |
| `BO-NFR-005` | determinism | URL/UA/resolution helpers **MUST** be pure for the same inputs and candidate snapshot. | shipped | `@req-bo-nfr-005` |
| `BO-NFR-006` | accessibility | Every browser/open choice and failure path **MUST** have keyboard and VoiceOver parity and non-color-only state. | planned | `@req-bo-nfr-006` |
| `BO-NFR-007` | reliability | One user gesture **MUST** settle once; stale pending addresses, provider selections, and navigation events **MUST NOT** affect a later pane/request. | partial | `@req-bo-nfr-007` |
| `BO-NFR-008` | architecture | Core audiences **MUST** remain exactly programmatic or plugin-only; `user` may project plugin metadata but **MUST NOT** become a generic core principal. | shipped | `@req-bo-nfr-008` |
| `BO-NFR-009` | observability | Data-store deletion errors and open failures **MUST** remain inspectable without logging full URLs as routine diagnostics. | partial | `@req-bo-nfr-009` |
| `BO-NFR-010` | compatibility | Supported macOS versions **MUST** receive a compatible Safari product token; real browsing and chooser behavior require installed-app verification. | partial | `@req-bo-nfr-010` |

## 8. Acceptance specification

[`browser-and-open.feature`](browser-and-open.feature) is the executable example map. Every
requirement above appears as an exact lowercase `@req-*` tag. `@pending` scenarios describe
accepted behavior absent from the current product and MUST remain visible in reports.

| Requirement group | Automation seam | State |
|---|---|---|
| `BO-FR-001…014` | plugin runtime, hosted WebKit, markdown/link tests | green, with live-site receipt owed |
| `BO-FR-015…022` | catalog, registry, policy, approval unit/integration tests | green/partial wiring |
| `BO-FR-023…029` | application service, hosted integration, XCUITest/manual chooser | red/pending |
| `BO-NFR-*` | fitness, hosted lifecycle, accessibility, privacy/manual audit | mixed as marked |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Owner/caller | Classification | Why | Inventory change? |
|---|---|---|---|---|
| plugin view declaration | Browser → host | CONTRIBUTION | declarative registered state | no |
| navigation facts | web surface → plugin | EVENT | facts already happened | no |
| browser surface operations | plugin → host | INTENT | finite cross-owner request/reply | no |
| built-in link activation | SwiftUI → opener service | DIRECT | same semantic owner | typed service pending; no public path |
| plugin/CLI/agent open | external principal → provider | INTENT | public finite operation | Browser binding to existing contract pending |
| handler choice/default | person → resolver/application service | DIRECT | host-owned product policy | no new intent |

### Native design-system constraints

The existing pane header, plugin field/icon buttons, Settings source/detail layout, menus,
alerts/sheets, semantic colors, geometry, focus rings, and typography own presentation.
External browser/Android patterns inform the workflow only.

### Domain and ownership map

| Domain | Existing owner/source | Expected change | Retrieval/tests |
|---|---|---|---|
| plugin-contributions | browser manifest/runtime | offer existing URL contract | plugin runtime tests |
| terminal-surface | `PluginWebSurfacePool`, `WebUserAgent` | none unless defects found | hosted WebKit tests |
| intent-bus | catalog, registry, dispatcher, approvals | typed application bridge/choice flow | intent fitness/integration |
| agent-lens | markdown and view | replace remote `.systemAction` | link and hosted action tests |
| plugin-host | activation coordinator/authorization | restage after grant/revoke | host lifecycle tests |

### Data, resource, lifecycle, security

Surface identity is `(PluginInstallationKey, surfaceID)`. WKWebView and delegates live in
the MainActor pool; pane close/disable disposes the view; uninstall additionally removes the
installation website data. Approval identity is `(pluginID, intentID)` in an atomic,
stable-order file. Configured defaults are resolver state and cannot outlive an eligible
provider. URLs are sensitive: an approved handler sees the complete address, so approval is
explicit and diagnostics avoid routine full-value logging.

### Compatibility

The Browser uses WebKit available on Tenon's macOS deployment floor. The current private
`dev.tenon.browser.open.v1` remains until migration to `url.open.v1` has a reviewed
supersession/removal path; the public core contract is already versioned. No new public
principal or audience is compatible with this design.

## 10. Delivery plan

### Requirement delivery matrix

| Requirements | State | Implementation/evidence | Remaining gap |
|---|---|---|---|
| `BO-FR-001…014`, `BO-NFR-002/004/005` | shipped | browser plugin, pool, UA, markdown and tests | installed real-site observation |
| `BO-FR-015…019/021/022`, `BO-NFR-008` | shipped | core catalog, registry, dispatcher, candidacy, fitness tests | product invocation not connected |
| `BO-FR-020`, `BO-NFR-003/007/009/010` | partial | persisted approval actor and app authorization closure | user mutation/reload/receipts |
| `BO-FR-023…029`, `BO-NFR-001/006` | planned | accepted design; helpers where noted | implement complete user flow |

### Phases

| Phase | Outcome | Included requirements | Exit criteria |
|---|---|---|---|
| `0 — preserve shipped browser` | current plugin/surface behavior remains explicit | 001…014 | headless/hosted suite green |
| `1 — one opener` | every built-in URL gesture resolves identically | 015…024, 028 | typed service and one-settlement tests |
| `2 — real alternative handler` | Browser can be approved/chosen/defaulted/revoked | 020…027 | Settings/chooser/accessibility receipts |
| `3 — mechanism proof` | another open kind reuses policy | 029 | no browser-specific chooser branch |

### Migration and rollout

Ship trusted-system behavior as the fallback throughout. Add the typed opener before
removing `.systemAction`; add the Browser's `url.open.v1` offer inertly; then ship approval
and reload, chooser, and default. Remove the private open path only after all launchers and
tests use the canonical contract. A failed phase falls back to the trusted provider without
deleting user approval data.

## 11. Dependencies, risks, and mitigations

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| `BO-R-001` | helper infrastructure is mistaken for shipped UX again | high | high | delivery matrix plus `@pending` scenarios |
| `BO-R-002` | bundled plugin gains implicit access to browsing history/URLs | medium | high | same explicit approval as third party |
| `BO-R-003` | fallback creates double opens after plugin timeout | medium | high | single settlement; retry only by new gesture |
| `BO-R-004` | stale design text directs implementation to a generic app principal | medium | high | normative audience/DIRECT fitness tests |
| `BO-R-005` | UA/site behavior differs from headless expectations | medium | medium | installed real-site matrix, no whole-UA override |

## 12. Open questions and decisions

### Open questions

| ID | Question | Why it matters | State |
|---|---|---|---|
| `BO-Q-001` | Which Settings detail owns approval rows and explanatory copy? | discoverability/accessibility | open |
| `BO-Q-002` | Which second open kind is the smallest honest extensibility proof? | closes FR-029 | open |
| `BO-Q-003` | When is the private Browser open intent removed versus temporarily adapted? | compatibility | open |

### Decision log

| Date | Decision | Rationale/evidence | Supersedes |
|---|---|---|---|
| 2026-08-06 | Built-in UI uses a typed DIRECT opener; public audiences stay closed. | interaction boundary law | generic app-principal proposal |
| 2026-08-06 | Approval is per plugin/contract and never implied by bundling. | complete URLs are private data | location-based trust |
| 2026-08-09 | Current source, not T-071 prose, defines delivery state. | approval closure is now real; user surface/provider binding still absent | stale implementation table |

## 13. Verification receipts

| Date | Worktree | Scope | Result | Known exclusions |
|---|---|---|---|---|
| 2026-08-09 | current dirty tree, documentation-only audit | manifest/runtime/pool/catalog/registry/approval/link source and mapped tests | implementation map reconciled | full tests and installed GUI not run in this documentation pass |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD | preserve shipped behavior and expose unfinished handler UX |
