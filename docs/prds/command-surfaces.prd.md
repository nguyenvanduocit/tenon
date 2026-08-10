# PRD — Command surfaces, tab launcher, and tab ordering

| Field | Value |
|---|---|
| PRD ID | `TENON-PRD-002` |
| Lifecycle | `shipped` |
| Owner | Tenon shell and command-surface domains |
| Reviewers | product, native UI, plugin runtime, accessibility, test |
| Created | 2026-08-09 |
| Last reviewed | 2026-08-09 |
| Related work | T-006, T-008, T-019, T-022, T-039, T-057, T-058, T-096 |
| Existing design | [`design-command-palette.md`](../design-command-palette.md) |
| Acceptance specification | [`command-surfaces.feature`](command-surfaces.feature) |

## 1. Executive summary

### Problem

Tenon exposes many ways to start work: the Command Palette, the tab-strip `+`, a tab's
secondary click, empty workspace space, keyboard shortcuts, and accessibility actions. When
those surfaces use different catalogs or add intermediate menus, options disappear and the
user must remember which surface owns which action. This happened when tab right-click hid
the actual launcher behind “Open Something New…”, then later when unifying the launcher
dropped Copy Tab ID. A separate native-input conflict made a tab drag move the whole window
instead of reordering the tab.

The product requirement is one coherent command projection with placement-specific anchors,
plus local tab controls that remain directly reachable. Unifying discovery must never remove
tab identity utilities, tab selection, close, reordering, or native window movement.

### Proposed outcome

The Command Palette and every launcher anchor derive executable rows from the same
plugin-owned intent presentations and ranking system. The anchor supplies placement: `+`
creates a destination, a tab launcher targets the clicked tab, and an empty target fills the
exact space. Tab-specific utilities such as Copy Tab ID remain fixed, visible actions outside
the ranked catalog. Pointer tab reordering and empty-titlebar window dragging coexist without
one stealing the other's mouse stream.

### Why now

Repeated user reports showed context drift across fixes: restoring the unified launcher hid
Copy Tab ID; restoring Copy Tab ID did not restore drag-to-order; and the first reorder
implementation lost to the hidden-titlebar window server and AppKit controls. The old T-096
task record still describes a SwiftUI `DragGesture` and an unverified arbitration, and the
AppKit pan observer that replaced it lost to the window server in the same way (T-101);
current source gives the strip its own hit-testing surface. A canonical shipped-state PRD is required
so the next change begins from current behavior rather than a stale task outcome.

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| direct user feedback | conversation, 2026-08-09 | high | launcher options must not be hidden behind an intermediate action; Copy Tab ID and drag-to-order are required together |
| current launcher source | [`LauncherMenu.swift`](../../Sources/TenonApp/LauncherMenu.swift), [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift) | high | one launcher view is shared; tab anchors add a fixed Copy Tab ID action and placement-specific dispatch |
| current tab-input source | [`TabReorder.swift`](../../Sources/TenonCore/TabReorder.swift), [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift), [`WindowChrome.swift`](../../Sources/TenonApp/WindowChrome.swift) | high | reorder is pure core logic fed by the strip's own AppKit surface, which answers `mouseDownCanMoveWindow` with `false` and owns the primary-button stream; empty chrome calls `performDrag` explicitly |
| measured title-bar band probe | standalone `.windowStyle(.hiddenTitleBar)` probe, 2026-08-09 | high | every AppKit view SwiftUI builds under a chip answers `mouseDownCanMoveWindow == true`; a representable in `.background` is never the hit, one in `.overlay` is; `window.isMovable = false` survives in the live window and still does not stop the move |
| shipped plugin manifests | `plugins/*/manifest.json` | high | palette/launcher rows and product keybindings are plugin-owned declarations |
| focused tests | core, hosted AppKit, and XCUITest files listed in the delivery matrix | high | ranking, placement, failure, reordering, accessibility values, and real pointer/window behavior have matching evidence seams |
| task archive | T-006, T-008, T-019, T-022, T-039, T-057, T-058, T-096 | medium | original decisions and mutation evidence; implementation narratives may be superseded by current source |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| What core problem are we solving? | Every command/launcher anchor must expose the intended capability without losing local tab controls or changing unrelated pointer behavior. | user feedback, 2026-08-09 |
| Who experiences it? | A keyboard, pointer, or VoiceOver user supervising work across tabs and panes. | product behavior and accessibility requirements |
| How will we know it worked? | The same declared commands appear through their eligible surfaces; the tab launcher includes Copy Tab ID; tab drag changes order without moving the window; empty chrome still moves the window. | acceptance scenarios and focused UI tests |
| Which constraints cannot move? | interaction-boundary law, plugin-owned command declarations, Tenon native design system, stable tab identity, one mutation path, and accessibility parity | normative docs/current source |
| What remains unknown? | Product analytics targets such as time-to-command are not instrumented. Correctness and non-regression are currently measured through deterministic tests and direct observation. | 2026-08-09 |

### Assumptions to validate

| ID | Assumption | Validation method | State |
|---|---|---|---|
| `CMD-A-001` | A six-point pointer threshold distinguishes a click from an intentional tab drag without feeling delayed. | installed-app observation with mouse and trackpad | partially validated by XCUITest; human feel remains observational |
| `CMD-A-002` | A fixed Copy Tab ID footer is discoverable without polluting search/ranking. | direct user confirmation and usability observation | accepted product decision |

## 3. Users and jobs

### Primary user

An operator supervising several terminal, agent, file, and plugin panes. They switch between
keyboard and pointer input, frequently create or place content, and need stable identifiers
when invoking CLI/agent workflows. They cannot afford a surface to silently omit an action
because a previous fix chose a different menu implementation.

### Secondary users and affected actors

- VoiceOver and keyboard-only users who need non-drag alternatives and spoken position.
- Plugin authors whose declared intents, launcher membership, and keybindings are projected
  by the host.
- CLI/agent users who paste the raw tab UUID copied from the native UI.
- Test and support engineers who need identifiers and deterministic command entry points.

### Jobs to be done

- When I know the action but not its location, I want one search surface so I can run it
  without navigating feature-specific menus.
- When I am working from the tab strip, I want `+` and tab right-click to expose the same
  launcher vocabulary with placement that matches the anchor.
- When another tool needs a tab address, I want to copy the stable raw ID from that tab.
- When tabs no longer match my workflow, I want to drag one to a new position without moving
  the window or losing the tab's work.

### Product vocabulary

| Term | Meaning in this PRD | Not to be confused with |
|---|---|---|
| Command Palette | full-window `⌘⇧P` search over eligible static and dynamic plugin-owned intent presentations | the compact launcher popover |
| Launcher | the shared compact `LauncherMenu` presentation anchored by `+`, a tab, or empty workspace space | a second command registry |
| Anchor placement | host-native context supplied when a launcher row is invoked | plugin authority or an alternate intent contract |
| Tab utility | same-owner local action such as Copy Tab ID | a ranked/open command or public intent |
| Reorder | move one stable tab within the active workspace's displayed sequence | moving a tab between workspaces/windows or a pasteboard drag |

## 4. Goals and success measures

### Goals

- `CMD-G-001` — A user can discover and invoke every eligible command from the Command
  Palette and every relevant launcher anchor without a duplicate catalog.
- `CMD-G-002` — Placement follows the anchor while invocation authority and settlement use
  the canonical dispatcher path.
- `CMD-G-003` — Copy Tab ID, selection, close, reorder, and window drag all remain reachable
  after launcher unification.
- `CMD-G-004` — Pointer-only behavior has a useful keyboard or accessibility alternative.

### Success metrics

| ID | Metric | Baseline | Target | Measurement method |
|---|---|---|---|---|
| `CMD-M-001` | intermediate native menu before tab launcher | previously present | zero | XCUITest and source fitness gate |
| `CMD-M-002` | eligible launcher catalogs implemented outside `CommandIndex` projection | historical duplicates existed | zero | architecture fitness/source audit |
| `CMD-M-003` | tab reorder moves window frame | reproduced defect | zero successful reorders move the window | XCUITest compares tab order and window frame |
| `CMD-M-004` | empty-titlebar drag after disabling server movement | regression risk | window origin changes | focused XCUITest |
| `CMD-M-005` | launcher success/failure teaches incorrect frecency | former tab-context bug | only successful invocation records | headless settlement tests |

### Guardrail metrics

| ID | Regression to prevent | Limit | Measurement method |
|---|---|---|---|
| `CMD-GM-001` | tab clicks or close controls swallowed by the reorder observer | zero | hit-target hosted tests plus UI flow |
| `CMD-GM-002` | slow dynamic provider blocks/reorders static results | zero | provider lifecycle test observes static order immediately |
| `CMD-GM-003` | stale provider result shown for a newer query | zero | revision and retirement tests |
| `CMD-GM-004` | tab identity/content/selection changes during reorder | zero | workspace reorder tests and persistence round trip |

## 5. Scope

### In scope

- Command Palette search, keyboard navigation, dynamic result sections, result actions, and
  shared invocation/frecency behavior.
- Manifest-owned product keybindings and deterministic conflict handling.
- Shared LauncherMenu presentation for `+`, tab secondary click, empty tab/slot/grid, and
  host-native agent suggestions where available.
- Anchor-specific target placement and settlement.
- Fixed Copy Tab ID utility in the tab launcher and accessibility action.
- Tab selection, close, drag-to-reorder preview/commit/cancellation, spoken position, and
  keyboard/VoiceOver reorder alternatives.
- Empty-titlebar drag and system-configured double-click behavior.

### Non-goals

- Moving a tab between workspaces, windows, or applications.
- A pasteboard representation for tab reordering.
- Making the dragged chip follow the pointer; the insertion caret is the preview.
- Publishing tab reorder as a host-wide command or public intent.
- Putting Copy Tab ID into fuzzy ranking, frecency, or the public intent catalog.
- Exposing raw core intents directly to the palette; user-facing rows remain plugin-owned
  intent presentations.
- Defining pane drag/resize behavior, which belongs to PRD-003.

### Later possibilities

- Usability measurement for command discovery time and pointer-drag threshold.
- A user-visible product analytics policy, if Tenon adopts analytics at all.
- Cross-window tab transfer under a separate interaction and resource-lifetime design.

## 6. User experience

### Entry points

- `⌘⇧P` toggles the Command Palette.
- The tab-strip `+` opens LauncherMenu; clicking `+` alone does not create a tab.
- Secondary click or Control-click on a tab opens LauncherMenu directly on that chip.
- Empty tab/slot/grid entry points reuse the launcher presentation and constrain its target.
- Manifest-assigned product keybindings invoke their exact plugin-owned intent.
- A short primary click selects a tab; a six-point primary-button pan begins reorder.
- Pressing empty titlebar chrome begins a native window drag.

### Primary launcher flow

1. The user opens a command surface.
2. The host projects currently active, authorized plugin-owned intent presentations.
3. Search/ranking and arrow selection operate on the same displayed order.
4. The anchor prepares placement and a fresh user gesture.
5. Invocation enters the shared dispatcher and settles visibly.
6. Success records frecency and dismisses; failure remains visible without teaching ranking.

### Tab launcher flow

1. The user secondary-clicks any foreground or background tab.
2. The searchable LauncherMenu appears immediately, without an intermediate native menu.
3. Launcher rows target the clicked tab's scope; the tab is revealed only when the selected
   action needs visible placement.
4. Copy Tab ID remains visible as a fixed footer and copies the raw UUID.

### Tab reorder flow

1. A primary press begins on a measured tab chip.
2. Movement below six points remains a click; movement at or above six points begins reorder.
3. The dragged tab dims and a caret marks the insertion gap.
4. Releasing within the strip's admitted vertical band commits one typed `moveTab` mutation.
5. The tab keeps identity, contents, active state, pane focus, and persisted order; the window
   frame does not change.

### Alternate and edge flows

- **No-op:** dropping on either side of the tab's current position changes nothing.
- **Cancellation:** leaving the admitted vertical band, recognizer cancellation, view/window
  teardown, or an invalid target clears preview and preserves order.
- **Invalid state:** a tab not shown by the strip and an out-of-range boundary are refused.
- **Failure:** launcher error remains in the popover; missing intent says it is no longer
  available; neither records frecency.
- **Stale query:** provider publications for an older revision are ignored.
- **Background tab:** non-placing actions do not steal selection; placing actions reveal only
  as required to show the result.

### Accessibility and input parity

- Each tab exposes its one-based position and active state to VoiceOver.
- Each tab exposes Move tab left/right only where that move exists.
- A completed move posts a spoken announcement using the same core sentence for pointer and
  accessibility routes.
- Each tab exposes Open launcher and Copy Tab ID accessibility actions.
- Palette and launcher support keyboard search, arrows, Enter, and Escape/cancel behavior.
- Visual preview uses existing semantic tokens and does not rely on color alone.

## 7. Requirements

### Functional requirements

| ID | Requirement | Priority | Delivery | Acceptance reference |
|---|---|---|---|---|
| `CMD-FR-001` | Every static palette/launcher row **MUST** originate from an active plugin-owned intent presentation; a launcher **MUST NOT** maintain a second hard-coded command catalog. | must | shipped | `@req-cmd-fr-001` |
| `CMD-FR-002` | `⌘⇧P` **MUST** open the Command Palette, focus search, filter/rank results, support arrow/Enter selection, and close on Escape. | must | shipped | `@req-cmd-fr-002` |
| `CMD-FR-003` | Dynamic providers **MAY** append current-revision sections below static results; they **MUST NOT** block or reorder the static list. | should | shipped | `@req-cmd-fr-003` |
| `CMD-FR-004` | The tab-strip `+` **MUST** open LauncherMenu directly and create/place content only after a row is selected. | must | shipped | `@req-cmd-fr-004` |
| `CMD-FR-005` | A tab secondary click **MUST** open the same LauncherMenu directly, with no intermediate native menu or “Open Something New…” action. | must | shipped | `@req-cmd-fr-005` |
| `CMD-FR-006` | A row invoked from a tab launcher **MUST** resolve scope from the clicked tab, including when it is in the background, and reveal it only when the result requires presentation. | must | shipped | `@req-cmd-fr-006` |
| `CMD-FR-007` | A tab launcher **MUST** retain a fixed Copy Tab ID action that copies the raw UUID and remains outside search, ranking, and frecency. | must | shipped | `@req-cmd-fr-007` |
| `CMD-FR-008` | Empty tab, slot, and grid entry points **MUST** reuse the launcher vocabulary while filling their exact target rather than silently choosing a different pane/tab. | must | shipped | `@req-cmd-fr-008` |
| `CMD-FR-009` | Manifest product keybindings **MUST** normalize chords, resolve conflicts deterministically, respect shell-reserved chords, display the assigned chord, and invoke through the same current-binding dispatcher path as palette selection. | must | shipped | `@req-cmd-fr-009` |
| `CMD-FR-010` | Successful launcher invocation **MUST** record frecency and dismiss; failure or vanished intent **MUST** remain visible and **MUST NOT** record frecency. | must | shipped | `@req-cmd-fr-010` |
| `CMD-FR-011` | Launcher height **MUST** fit its rows/separators/padding until available screen space is exhausted, then scroll without extending past that space. | should | shipped | `@req-cmd-fr-011` |
| `CMD-FR-012` | A short primary click on a tab **MUST** remain selection, while a primary drag of at least six points beginning on a chip **MUST** enter reorder without selecting an unrelated target or taking the close control's hit. | must | shipped | `@req-cmd-fr-012` |
| `CMD-FR-013` | Reorder **MUST** show one insertion caret and commit the stable dragged tab to the previewed gap within the current workspace. | must | shipped | `@req-cmd-fr-013` |
| `CMD-FR-014` | Reorder **MUST** preserve tab identity, content, panes, focus, active state, and persisted sequence; it **MUST NOT** move the window. | must | shipped | `@req-cmd-fr-014` |
| `CMD-FR-015` | Invalid, cancelled, out-of-band, unknown-tab, and current-position drops **MUST** clear preview and leave order unchanged. | must | shipped | `@req-cmd-fr-015` |
| `CMD-FR-016` | Empty titlebar chrome **MUST** retain native window drag and the user's configured double-click titlebar action even though implicit server-side background movement is disabled. | must | shipped | `@req-cmd-fr-016` |
| `CMD-FR-017` | Tab reorder and Copy Tab ID **MUST** expose keyboard/VoiceOver alternatives, useful values, and a completion announcement. | must | shipped | `@req-cmd-fr-017` |
| `CMD-FR-018` | Machine-local agent launch suggestions **MAY** appear as a host-native launcher section, but they **MUST** use the same displayed-order, settlement, and placement rules as command rows. | could | shipped | `@req-cmd-fr-018` |
| `CMD-FR-019` | The surface that removes the chips from the window's drag region **MUST NOT** cover any other title-bar control, and **MUST NOT** hold keyboard focus: a press on `+` opens the launcher, and a press on a tab leaves the keyboard with the focused terminal. | must | shipped | `@req-cmd-fr-019` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `CMD-NFR-001` | lifecycle | Provider query revisions **MUST** be monotonic; stale generation/revision results **MUST** be rejected and retirement **MUST** remove publications. | shipped | provider lifecycle tests |
| `CMD-NFR-002` | bounds | One plugin **MUST NOT** register more than 8 dynamic providers; one publication is bounded to 50 results and 8 actions/result with runtime string/payload bounds. | shipped | palette provider tests |
| `CMD-NFR-003` | responsiveness | Delivering a palette query **MUST NOT** await plugin handlers; static ranking remains immediately usable even when a provider never answers. | shipped | slow-provider test |
| `CMD-NFR-004` | accessibility | Pointer-only reorder **MUST** have Move left/right actions; status and preview **MUST NOT** depend only on hue. | shipped | spoken-value core tests and visual/hosted test |
| `CMD-NFR-005` | design | Launcher, rows, caret, hover, type, color, and geometry **MUST** use `TenonTheme` and `docs/designs.md`; no feature-local token is permitted. | shipped | source/design review |
| `CMD-NFR-006` | consistency | Search rendering, keyboard selection, and invocation **MUST** read one displayed order; grouping **MUST NOT** create a different selectable index. | shipped | `LauncherSectionsTests` |
| `CMD-NFR-007` | locality | Tab reorder and identifier copy **MUST** remain same-owner local/DIRECT behavior and **MUST NOT** add a public `tenon` path, intent, capability, audience, or registered product command. | shipped | interaction fitness |

## 8. Acceptance specification

The linked Gherkin file is the business-readable acceptance contract. Automation remains at
the smallest seam that can prove each behavior.

| Requirement group | Feature scenarios | Evidence seam |
|---|---|---|
| catalog/ranking/palette | unified catalog, keyboard palette, dynamic results | core command/palette tests plus `PaletteFlowUITests` |
| launcher anchors/placement | plus launcher, tab launcher, empty target, background tab | launcher/placement headless tests plus workspace XCUITest |
| identity utility | Copy Tab ID remains visible and raw | interaction fitness, pasteboard unit path, XCUITest visibility |
| keybindings | manifest assignment, conflicts, invocation | KeyChord/KeyBindingIndex/host/invoker tests |
| reorder | commit, no-op, cancellation, preservation, persistence | `TabReorderTests`, `WorkspaceTabOrderTests`, hosted strip tests, XCUITest |
| window behavior | tab drag stays local; empty chrome moves window | two focused XCUITests |
| accessibility | position, custom moves, announcement, copy/open actions | core spoken-value tests and source/hosted accessibility inspection |

## 9. Product and architecture constraints

### Interaction boundary classification

| Interaction | Semantic owner/caller | Classification | Why this rung applies | Public inventory change? |
|---|---|---|---|---|
| plugin declares palette/launcher/key metadata | plugin → host | CONTRIBUTION/control declaration | plugin owns declarative presentation; host validates/projects | already inventoried |
| palette query delivery | host palette → plugin | EVENT | a query revision is a fact already produced; host does not await observers | already inventoried |
| provider publishes revision results | plugin → host | CONTRIBUTION | replaceable plugin-owned result snapshot | already inventoried |
| user invokes a command row/keybinding | palette principal → plugin provider | INTENT | finite cross-owner request/reply through canonical dispatch | already inventoried |
| anchor computes placement and renders launcher | host shell | DIRECT | same owner and focused UI context | no |
| tab reorder/select/close/copy | host shell/workspace service | DIRECT/local control | same semantic owner; no product command registration | no |
| empty titlebar drag/double-click | host window chrome | DIRECT/local control | focused native window mechanism | no |

### Native design-system constraints

Launcher density, row anatomy, search chrome, caret, tab chip geometry, colors, focus, and
accessibility follow [`designs.md`](../designs.md). The compact launcher and full Command
Palette may differ in presentation scale, but they share command models and semantic tokens.

### Domain and ownership map

| Product domain | Existing owner/source | Responsibility |
|---|---|---|
| command-surface | `CommandIndex`, `LauncherMenu`, `PaletteOverlay`, invoker/settlement values | discover, rank, render, and invoke eligible command presentations |
| workspace-model | `TabReorder`, `WorkspaceCatalog`, `WorkspaceStore`, `WindowChrome` | stable order mutation, persistence, and local window/tab interaction |
| plugin-contributions | manifest/presentation projection and dynamic providers | declare user-facing actions and replaceable results |
| intent-bus | dispatcher/policy/provider registration | one cross-owner invocation path |

### Data, resource, and lifecycle model

- Command identity is the versioned plugin intent ID; launcher membership and keybinding are
  presentation metadata, not separate commands.
- Frecency is learned only after successful settlement.
- Dynamic results are keyed by plugin/provider and current host query revision; hot reload or
  plugin retirement removes them.
- Tab reorder carries a stable UUID, never a mutable array index or pasteboard payload.
- `TabReorderMonitor` observes the window content stream simultaneously but its view never
  wins hit testing. Detach/cancel clears its local drag.
- `WindowChrome` disables implicit server-side movement; `WindowDragArea` explicitly invokes
  native `performDrag` only from empty chrome.

### Security and privacy

- Command execution still passes contract, audience, capability, scope, provider, admission,
  confirmation, and current-binding checks.
- The host mints a fresh user-gesture identity at invocation; plugins cannot provide one.
- Copy Tab ID exposes only the stable local UUID deliberately requested by the user and does
  not publish it to a plugin or analytics channel.

### Compatibility

- Manifest key/launcher fields are versioned and fail closed when malformed.
- Losing or invalid keybindings remain discoverable in the palette with deterministic
  diagnostics rather than overriding a winner.
- The old flat tab `.contextMenu`, intermediate “Open Something New…”, and SwiftUI-only tab
  `DragGesture` are superseded paths and must not be reintroduced.

## 10. Delivery plan

### Requirement delivery matrix

| Requirements | State | Implementation/source | Test/evidence | Remaining gap |
|---|---|---|---|---|
| CMD-FR-001…003, CMD-NFR-001…003, 006 | shipped | `CommandIndex`, `PaletteOverlay`, palette provider runtime/host, `LauncherSections` | command index, palette display/provider, launcher sections, palette UI tests | product analytics not instrumented |
| CMD-FR-004…008, 010…011, 018 | shipped | [`LauncherMenu.swift`](../../Sources/TenonApp/LauncherMenu.swift), launcher placement/outcome, titlebar/canvas anchors | launcher commands/height/outcome/placement, workspace launcher tests, XCUITest | trackpad feel remains human-observed |
| CMD-FR-007 | shipped | `WorkspaceIdentifierClipboard`, tab launcher footer and accessibility action | interaction fitness and tab-launcher XCUITest; shared pasteboard helper covered through pane-ID test | no known gap |
| CMD-FR-009 | shipped | `KeyChord`, `KeyBindingIndex`, manifest projection, plugin keybinding Commands and shared invoker | key chord/index, host lifecycle, invoker, core-commands tests | no known gap |
| CMD-FR-012…017, CMD-FR-019, CMD-NFR-004, 005, 007 | shipped | [`TabReorder.swift`](../../Sources/TenonCore/TabReorder.swift) (`press`), `TabStripSurface` in [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift) (`SurfaceView: NSControl`), [`WindowChrome.swift`](../../Sources/TenonApp/WindowChrome.swift), workspace move/persistence | reorder core/workspace/hosted tests; `TabStripReorderTests` — drag region membership, `NSControl` superclass, keyboard hand-back, press-drag-release, select, close, `+` uncovered, deferred dismantle; interaction fitness; [`scripts/drag-region-probe.swift`](../../scripts/drag-region-probe.swift) for the AppKit rule itself | the XCUITest drag passed against the mechanism a human drag falsified, so it does not discriminate CMD-M-003; the region test does |

### Phases

| Phase | User-visible outcome | Included requirements | Exit criteria | Rollback/fallback |
|---|---|---|---|---|
| historical foundation | Command Palette, launcher projection, keybindings, scoped placement | CMD-FR-001…011 | existing focused evidence | plugin command remains palette-only if key loses conflict |
| tab interaction completion | Copy Tab ID and reorder coexist with launcher/window behavior | CMD-FR-012…017 | focused real-window tests plus headless preservation | disable reorder observer while retaining click/launcher; never restore server background dragging over controls |
| ongoing | preserve one model as new commands/providers arrive | all | fitness, manifest, and acceptance audit | reject malformed contribution, keep host available |

### Migration and rollout

This capability is shipped. Future changes migrate by deleting superseded surface paths in the
same change, updating this PRD/Gherkin, and exercising the affected anchor in a staged app. Do
not replace or terminate a running production app merely to verify a UI change; use a separate
channel and preserve user state.

## 11. Dependencies, risks, and mitigations

| ID | Risk | Likelihood | Impact | Mitigation | Trigger/owner |
|---|---|---|---|---|---|
| `CMD-R-001` | AppKit/SwiftUI event arbitration changes and tab drag again moves the window or swallows a button. | medium | high | the strip's own surface claims every point inside itself and answers `mouseDownCanMoveWindow` with `false`, resolving click, close and hover itself; explicit window drag for empty chrome; fitness pins the unconditional claim, a hosted test pins the composition, a hosted press-drag-release pins the whole gesture, and one more pins the `+` staying outside the claimed region | native UI owner when OS/input seam changes |
| `CMD-R-002` | A new launcher anchor forks catalog or settlement logic. | medium | high | one `LauncherMenu`, `CommandIndex` projections, architecture fitness anchors | command-surface review |
| `CMD-R-003` | Positional fallback terminal titles appear to follow order rather than identity. | medium | medium | identity-based tests give source a stable title; future PRD may replace positional fallback naming | workspace shell owner |
| `CMD-R-004` | Dynamic provider floods or stale results degrade typing. | low | high | hard counts, bounded bridge payload, revisions, fire-and-forget delivery, retirement | plugin runtime owner |
| `CMD-R-005` | Utility actions disappear during presentation unification. | medium | high | PRD explicitly separates fixed utilities from ranked catalog; Gherkin and XCUITest cover Copy Tab ID | product/native UI review |

## 12. Open questions and decisions

### Open questions

| ID | Question | Why it matters | State |
|---|---|---|---|
| `CMD-Q-001` | Should fallback tab titles become identity-stable rather than positional? | A move can visibly renumber unnamed terminal tabs even though identity/content are preserved. | open, non-blocking |
| `CMD-Q-002` | Is six points the correct threshold for mouse and trackpad at all accessibility pointer settings? | Correctness is tested; feel is not quantitatively measured. | open validation question |

### Decision log

| Date | Decision | Rationale/evidence | Supersedes |
|---|---|---|---|
| 2026-07-25 | Plugin-owned intent presentation is the command source; palette/launcher are adapters. | eliminates duplicate command APIs and policy paths | handwritten/hard-coded command lists |
| 2026-07-31 | Product keybindings are manifest contributions resolved by the host. | one command identity and deterministic conflicts | static host workspace keybindings |
| 2026-08-01 | Tab secondary click reuses LauncherMenu. | one catalog/presentation and correct settlement | flat native context-menu command copy |
| 2026-08-09 | Tab launcher opens directly and keeps Copy Tab ID as a fixed utility. | user feedback: hiding launcher and losing identity utility are regressions | intermediate “Open Something New…” and catalog-only footer |
| 2026-08-09 | Reorder observes AppKit's window content pan stream; implicit window movement is disabled. | SwiftUI parent drag lost to `NSButton`, `NSScrollView`, and hidden-titlebar server drag; focused UI tests prove both tab and empty-titlebar behavior | T-096's SwiftUI `highPriorityGesture`/`@GestureState` implementation account |
| 2026-08-09 | **Superseded.** The strip owns its primary-button stream through one AppKit surface in front of the chips, which claims the point *only while a primary-button event is dispatching*. | A human drag on the installed 10:13 build still moved the window with the pan observer and `isMovable = false` in it. Probing a real hidden-titlebar window showed why: macOS asks the hit-tested view, every SwiftUI view under a chip answers `true`, a `.background` representable is never that view, and `isMovable = false` — verified to survive in the live window — does not close the path. An `.overlay` representable is the hit and can answer for them. | the window-content pan observer, `TabReorderMonitor`, and `window.isMovable = false` |
| 2026-08-09 | **Partly superseded** — the unconditional claim and the zone ownership still hold; the reason given for them did not. The strip's surface claims **every point inside itself, unconditionally**, and therefore owns the click, the close, and the hover as well; the row's four zones and their pointer owners are stated in `ShellTitleBar`'s own documentation. | The conditional claim shipped and a human drag still moved the window: a view that is not the hit-test result at every moment is not the hit-test result at whichever moment macOS uses to decide the band belongs to the window server. Measured after the change: at a chip's centre in a real hidden-titlebar window the hit is `TabStripSurface.SurfaceView` with `mouseDownCanMoveWindow == false`, asserted by `testAChipCentreHitTestsToTheStripSurfaceInsideARealTitleBarWindow`. | the event-gated `claimsPointer` hit test |
| 2026-08-09 | The surface covers **the chips and nothing else**; the `+` keeps its own click, and a drag on it moves the window like the identity zone beside it. | Shipped with the `+` inside the surface, and it stopped responding entirely — a control under a view that claims every pointer hears nothing. Taking the pointer means owning every meaning of it, so the claimed region is exactly the region whose meanings the surface implements. Held by `testTheNewTabButtonIsNotCoveredByTheStripSurface`. | one surface spanning chips and the `+` together |
| 2026-08-09 | The whole gesture is asserted headlessly: `NSWindow.sendEvent` drives press-drag-release through the shipped bar and the workspace's tab order must change. | The earlier claim that synthetic events never reach a view (`downs=0`) was wrong — they had been built without a valid `windowNumber` against a window that was never key. Correcting it turned "only a human can test this" into a test, and that test immediately found a fatal exclusivity violation: `dismantleNSView` wrote `@State` from inside `GraphHost.invalidate()`. | the account that delivery has no headless seam |
| 2026-08-09 | **The premise of all three previous rows was false.** macOS does not consult the hit-tested view: AppKit uploads a **drag region** to the window server, which starts the move from it. `mouseDownCanMoveWindow == false` is honoured by that region builder **only from an `NSControl` descendant**. `TabStripSurface.SurfaceView` is therefore an `NSControl`. | Read back through `NSWindow._lastDragRegionDataDescription` with a two-sided oracle (close button must be outside the region, empty chrome inside): as an `NSView` the chips are **inside** the region, as an `NSControl` they are **outside**, chrome unchanged in both. This is why every headless seam passed while the bug lived — `NSWindow.sendEvent` injects below the window server, so no test using it can observe the region. | the account that hit-testing decides the drag; and `isMovable = false`, now measured to empty the region including the chrome zone |
| 2026-08-10 | **A chip's fallback name is the tab's own number, not its position.** `Tab` carries a `number` assigned by `Workspace.nextTabNumber` when it joins a workspace, persisted in `TabRecord`, and read by `ShellTitleBar.tabTitle(for:)`. | Reported the moment the drag started working: drag one unnamed tab past another and the chips swap while `"Terminal \(index + 1)"` swaps the labels back, so the strip reads exactly as before and a working reorder is indistinguishable from a broken one. T-096 recorded this and exempted itself because no criterion named the title — true of the criteria, and beside the point, since the title is how the criteria's gesture is observed. Number reuse after closing the highest-numbered tab is accepted deliberately: the promise is that no tab's name changes, not that no number returns. | `"Terminal \(index + 1)"`, and T-096's account of the positional fallback as out of scope |
| 2026-08-10 | **The region rule has a second axis, and the strip was failing it.** A view leaves the drag region by being an `NSControl` **and accepting first responder**; a control answering `acceptsFirstResponder == false` is put back inside the region whole. `SurfaceView` therefore keeps `NSControl`'s own answer and overrides that property nowhere. The keyboard is kept by a different mechanism than the one assumed: `mouseDown` never calls `super`, and AppKit focuses no view on a press by itself. | Same read-back, varying only the responder overrides: `NSControl` alone → outside; `+ acceptsFirstResponder = false` → **inside**; the shipped shape → **inside**. A separate probe drove a press at the surface with the property left alone and read `window.firstResponder` back: the stand-in terminal kept it. Both axes are now in `scripts/drag-region-probe.swift`, which had been measuring a control the app no longer resembled and reporting the rule as held. | the `acceptsFirstResponder = false` override and the claim that a control necessarily steals focus from the terminal |

## 13. Verification receipts

| Date | Worktree/environment | Scope | Result | Known exclusions |
|---|---|---|---|---|
| 2026-08-09 | dirty current worktree, separately staged macOS app | `testDraggingATabReordersItWithoutMovingTheWindow` | passed; stable tab moved to last position and window frame stayed equal | production app deliberately not replaced |
| 2026-08-09 | same staged app | `testDraggingTheEmptyTitleBarStillMovesTheWindow` | passed; window origin changed | system double-click preference not exercised in this test |
| 2026-08-09 | current sources | `TabReorderTests`, launcher interaction fitness, `TabStripReorderTests` | focused suites passed | full default Xcode scheme had an unrelated integration-test compile defect at that time |
| 2026-08-09 | installed production app, built 10:13 | human drag on a tab chip | **failed**: the window moved and no tab reordered, with `TabReorderMonitor` and `isMovable = false` both in the running binary (symbols present; both edits predate the build) | this is the evidence that superseded the row above — `testDraggingATabReordersItWithoutMovingTheWindow` had passed against the same mechanism, so the XCUITest drag does not reproduce a human drag |
| 2026-08-09 | staged app, event-gated surface | human drag on a tab chip | **failed**: the window still moved | the conditional claim was the defect; recorded rather than dropped, because it is the evidence for the decision above |
| 2026-08-09 | current sources | full suite | passed, **1697 / 0** | includes `testAChipCentreHitTestsToTheStripSurfaceInsideARealTitleBarWindow`, which fails for the event-gated design — the regression now has a headless seam |
| 2026-08-09 | installed production app, built 17:22 | human press on the `+` | **failed**: the button did nothing, because the surface spanned it | the same report said the drag still did not reorder; that half is unresolved by this receipt |
| 2026-08-09 | current sources | `TabStripReorderTests` | passed **8 / 8**, including a press-drag-release driven through `NSWindow.sendEvent` on the shipped `ShellTitleBar` that moves the tab, and the `+` staying outside the surface | the window server's own arbitration of a hardware press is still outside any headless seam |
| 2026-08-09 | staged app, `SurfaceView: NSControl`, binary 19:16 | **human drag on a tab chip** | **accepted** — the tab reorders and the window stays put | the drag-region rule behind it is measured by `scripts/drag-region-probe.swift`, not by the suite |
| 2026-08-09 | current sources | full suite | passed, **1700 / 0** | `TenonUITests` needs an app host and does not run under `swift test` |
| 2026-08-10 | installed production app, built 20:49 (binary carries `SurfaceView` with `superclass _OBJC_CLASS_$_NSControl`, read with `otool -oV`) | human drag on a tab chip | **failed**: the window moved again | the `NSControl` change was present and correct; what defeated it was the `acceptsFirstResponder = false` override added beside it |
| 2026-08-10 | current sources | `TabStripReorderTests` | passed **14 / 0** — and the region test now *measures* the shipped surface's rect against the region instead of asserting its superclass, with a band oracle that fails if the harness stops putting the strip in the title-bar band | it failed first with the strip at `y 253…279` intersecting the region rect `(3, 268, 894, 9)`, which is the first time the suite has reproduced this defect |
| 2026-08-10 | staged app, `SurfaceView` with no `acceptsFirstResponder` override, binary 09:29 | **human drag on a tab chip** | **accepted** — "kéo thả ok rồi, tab có thay đổi" | the same drag exposed T-105: the chips moved and the labels moved back, so the working reorder read as none |
| 2026-08-10 | current sources | full suite | passed, **1735 / 0** | includes T-105's tab-number work; `TenonUITests` still needs an app host |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD written from current source, tasks, manifests, tests, and direct user corrections. | Replace scattered/stale implementation context with one shipped-state contract. |
| 2026-08-09 | Tab-input mechanism corrected after a human drag falsified the shipped account (T-101). | The PRD claimed server-side dragging was disabled; measurement showed the lever is per-view, not per-window. |
