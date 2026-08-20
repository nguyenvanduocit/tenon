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
| measured drag-region layering and gesture-seam probes | scratch probes over `NSWindow._lastDragRegionDataDescription` and `NSHostingView`, macOS 26.4, 2026-08-13 | high | the region is not front-view-wins: a carving `NSControl` keeps its rect out of it from any z position, *including behind* the movable container SwiftUI flattens the chips into, while `isHidden = true` puts the rect back. `window.isMovable = false` empties the region to zero rects, chrome included. A SwiftUI `DragGesture` in an `NSHostingView` never fires under synthetic events, or blocks the process in a nested tracking loop, on all three delivery routes |
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
| Tab utility | same-owner local action such as Copy Tab ID or Arrange Panes, offered only by an anchor that names a real existing tab (`CMD-FR-024`) | a ranked/open command or public intent, or something the `+` anchor may offer |
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
- Shared LauncherMenu presentation for `+`, tab secondary click, empty grid space, and
  host-native agent suggestions where available.
- The empty tab/pane card's own search field: grouped offerings with nothing typed, one ranked
  list once something is, and a typed command line run in the target it fills.
- Anchor-specific target placement and settlement.
- Fixed Copy Tab ID utility in the tab launcher and accessibility action.
- Tab selection, close, live drag-to-reorder and the restore that refuses it, spoken position,
  and keyboard/VoiceOver reorder alternatives.
- Empty-titlebar drag and system-configured double-click behavior.

### Non-goals

- Moving a tab between workspaces, windows, or applications.
- A pasteboard representation for tab reordering.
- Making the dragged chip follow the pointer: it travels by changing places in the row, and the
  row itself is the preview.
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
- Empty grid space opens LauncherMenu constrained to the rectangle that was clicked.
- An empty tab or pane opens its own card, which leads with a search field and constrains
  every pick — including a typed command line — to that exact tab or pane.
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
3. The dragged tab dims and changes places with the chips the pointer crosses, one typed
   `moveTab` mutation per crossing, animated so the eye can follow which chip went where.
4. Releasing within the strip's admitted vertical band leaves the tab where it stands and
   announces the landing once; releasing outside that band returns it to where it started.
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
| `CMD-FR-013` | Reorder **MUST** preview by performing: while the pointer is down inside the strip's admitted band, the stable dragged tab **MUST** already occupy the place the pointer means, within the current workspace, and the strip **MUST NOT** draw a second marker describing that place. | must | shipped | `@req-cmd-fr-013` |
| `CMD-FR-014` | Reorder **MUST** preserve tab identity, content, panes, focus, active state, and persisted sequence; it **MUST NOT** move the window. | must | shipped | `@req-cmd-fr-014` |
| `CMD-FR-015` | Invalid, unknown-tab, and current-position pointer positions **MUST** leave the order unchanged, and an out-of-band release **MUST** return the dragged tab to the index the drag began at. | must | shipped | `@req-cmd-fr-015` |
| `CMD-FR-016` | Empty titlebar chrome **MUST** retain native window drag and the user's configured double-click titlebar action even though implicit server-side background movement is disabled. | must | shipped | `@req-cmd-fr-016` |
| `CMD-FR-017` | Tab reorder and Copy Tab ID **MUST** expose keyboard/VoiceOver alternatives, useful values, and a completion announcement. | must | shipped | `@req-cmd-fr-017` |
| `CMD-FR-018` | Machine-local agent launch suggestions **MAY** appear as a host-native launcher section, but they **MUST** use the same displayed-order, settlement, and placement rules as command rows. | could | shipped | `@req-cmd-fr-018` |
| `CMD-FR-019` | The surface that removes the chips from the window's drag region **MUST NOT** cover any other title-bar control, and **MUST NOT** hold keyboard focus: a press on `+` opens the launcher, and a press on a tab leaves the keyboard with the focused terminal. | must | shipped | `@req-cmd-fr-019` |
| `CMD-FR-020` | An empty tab or pane **MUST** open with a search field as its first element and no decorative header; with nothing typed it **MUST** present its offerings grouped, and a typed query **MUST** replace that grouping with one ranked list that ↓/↑ walks and Enter runs. Every drawn row **MUST** resolve to an action. | must | shipped | `@req-cmd-fr-020` |
| `CMD-FR-021` | A typed query **MUST** always be offered as a command line to run in a terminal filling that exact target, carrying the query verbatim minus surrounding whitespace; it **MUST** lead the list when the query reads as a command line and follow the rows it named otherwise. | must | shipped | `@req-cmd-fr-021` |
| `CMD-FR-022` | With nothing typed, `LauncherMenu`'s `.open` grouping **MUST** split ranked commands by whether they can fill a pane rather than by each plugin's own declared category: pane-filling commands **MUST** draw as one tile grid, and every other launcher command **MUST** fold into the same "Pane" section as the fixed tab utilities rather than drawing its own one-row section. | must | shipped | `@req-cmd-fr-022` |
| `CMD-FR-023` | Every `LauncherMenu` anchor **MUST** offer a typed query as a command line to run, using the same rule and placement/delivery path (`RunCommandOffer`, `TerminalCommandLaunch`) the empty tab/pane card already uses for `CMD-FR-021`, so a query is never runnable in one launcher and not another. | must | shipped | `@req-cmd-fr-023` |
| `CMD-FR-024` | Sharing one `LauncherMenu` presentation (`CMD-FR-004`/`005`) is a statement about vocabulary, not about every anchor's optional callbacks: a utility whose meaning depends on an existing tab's current state — Arrange Panes, same as Copy Tab ID under `CMD-FR-007` — **MUST** be supplied only by an anchor that names a real existing tab. The `+` anchor, which creates a destination and names no existing tab, **MUST NOT** supply it, and **MUST NOT** substitute whichever tab is merely active. | must | shipped | `@req-cmd-fr-024` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `CMD-NFR-001` | lifecycle | Provider query revisions **MUST** be monotonic; stale generation/revision results **MUST** be rejected and retirement **MUST** remove publications. | shipped | provider lifecycle tests |
| `CMD-NFR-002` | bounds | One plugin **MUST NOT** register more than 8 dynamic providers; one publication is bounded to 50 results and 8 actions/result with runtime string/payload bounds. | shipped | palette provider tests |
| `CMD-NFR-003` | responsiveness | Delivering a palette query **MUST NOT** await plugin handlers; static ranking remains immediately usable even when a provider never answers. | shipped | slow-provider test |
| `CMD-NFR-004` | accessibility | Pointer-only reorder **MUST** have Move left/right actions; status and preview **MUST NOT** depend only on hue. | shipped | spoken-value core tests and visual/hosted test |
| `CMD-NFR-005` | design | Launcher, rows, hover, reorder motion, type, color, and geometry **MUST** use `TenonTheme` and `docs/designs.md`; no feature-local token is permitted. | shipped | interaction fitness `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics` for the row half — one chrome, `TenonTheme` hover and accent, one set of density metrics; the reorder's single animation constant and type remain design review, photographed mid-drag by `testAChipReportsTheBoxItOccupiesIncludingItsCloseControl` under `TENON_TAB_STRIP_SNAPSHOT` |
| `CMD-NFR-006` | consistency | Search rendering, keyboard selection, and invocation **MUST** read one displayed order; grouping **MUST NOT** create a different selectable index. | shipped | `LauncherSectionsTests` |
| `CMD-NFR-007` | locality | Tab reorder and identifier copy **MUST** remain same-owner local/DIRECT behavior and **MUST NOT** add a public `tenon` path, intent, capability, audience, or registered product command. | shipped | interaction fitness |
| `CMD-NFR-008` | presentation altitude | Every row in a command surface — ranked command, appended provider result, and fixed tab utility — **MUST** draw one shared row presentation that owns density metrics, hover, and the selected accent; that presentation **MUST NOT** take ranking data, and no call site may restate the highlight or fabricate a ranking answer to obtain a row. | shipped | interaction fitness `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics` |

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
| launcher grouping/run-command parity | pane-filler tile grid, non-pane-filler fold into Pane, run-command leading/trailing/absent across every anchor | `LauncherMenuGroupedLayoutTests`, `LauncherMenuRunCommandTests` |
| tab-scoped utility anchoring | `+` never offers Arrange Panes, the tab launcher keeps offering it for the tab it named | `InteractionBoundaryFitnessTests.testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities` |

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

Launcher density, row anatomy, search chrome, tab chip geometry, colors, focus, and
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
| CMD-NFR-008, and the row half of CMD-NFR-005 | shipped | [`PaletteRowChrome.swift`](../../Sources/TenonApp/PaletteRowChrome.swift); `PaletteRow` in [`PaletteOverlay.swift`](../../Sources/TenonApp/PaletteOverlay.swift) and the appended-result row beside it; the Copy Tab ID footer in [`LauncherMenu.swift`](../../Sources/TenonApp/LauncherMenu.swift); [`LauncherListHeight.swift`](../../Sources/TenonApp/LauncherListHeight.swift) | `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics` — the chrome names no ranking type, neither call site restates `isHovered`/`.onHover`, the footer draws the chrome at `compact` with `isSelected: false`, and the height arithmetic reads the chrome's own density; `LauncherListHeightTests` for that arithmetic | a headless suite proves the wash is wired and which token it uses, not that a person sees it follow the pointer; the launcher is an `NSPopover` and no offscreen renderer reaches it |
| CMD-FR-020, CMD-FR-021 | shipped | [`EmptyPaneLauncher.swift`](../../Sources/TenonCore/EmptyPaneLauncher.swift) (`RunCommandOffer` placement and the ranked rows, over `CommandIndex.rank`), [`EmptyPaneOfferings.swift`](../../Sources/TenonApp/EmptyPaneOfferings.swift) (the vocabulary and the id→action map, written together), [`EmptyStateCard.swift`](../../Sources/TenonApp/EmptyStateCard.swift), [`TerminalCommandLaunch.swift`](../../Sources/TenonApp/TerminalCommandLaunch.swift) (placement/delivery, now shared with `AgentLaunchExecutor`) | `EmptyPaneLauncherTests` — 11 headless rules including a command line leading, a file name staying a name, and a query nothing matches still being runnable; `EmptyPaneSearchTests` — every id the ranker can draw resolves, a typed command reaches the exact empty pane's shell in the workspace directory, a pane that filled itself between keystroke and Enter is refused, and a query shortens the card because it *replaced* the grouped layout; [`EmptyPaneSnapshot.swift`](../../Sources/TenonApp/EmptyPaneSnapshot.swift) photographs all three states offscreen | focus behaviour (the field taking the keyboard when its pane is the active one) is asserted only through the mount's own `isActive`, not through a real first responder; the run offer's heuristic is a stated rule, not a measured one |
| CMD-FR-022, CMD-FR-023 | shipped | [`LauncherMenu.swift`](../../Sources/TenonApp/LauncherMenu.swift) (`groupedPaneFillers`/`groupedOtherCommands` splitting by `Command.fillsPane` instead of category, `groupedContentHeight`'s tile-grid arithmetic, `runCommandOffer`/`runTypedCommand` reusing `RunCommandOffer.placement(for:)` unchanged), [`EmptyStateCard.swift`](../../Sources/TenonApp/EmptyStateCard.swift) (`CommandTile`, `LaunchTile`'s SF-Symbol twin — `CMD-NFR-008` keeps hover/highlight chrome out of `LauncherMenu.swift`, so a new grid row is declared beside `LaunchTile` rather than inside it), all three anchors (`ShellTabStrip.swift` ×2, `Canvas/SpatialCanvasNSView.swift`) wiring `runCommand` through the same `TerminalCommandLaunch.run` placement each already uses for `launchAgent` | `LauncherMenuGroupedLayoutTests` — a parameterized fixture proves 2-column packing (3 pane-filler commands need a second grid row, 4 do not) and that a non-pane-filling command's cost is one folded row (bounded against `LauncherListHeight.row`) rather than a second section header; `LauncherMenuRunCommandTests` — the row draws only with `runCommand` supplied and a qualifying query (leading for command-shaped, trailing for a plain word), never for an empty query, using the same `initialQuery` offscreen-measurement seam `EmptyStateCard` already has | same gap as CMD-FR-011/020: no offscreen route reaches a live `NSPopover`'s actual pixels, so the grid's exact geometry is owed a live `./tenon dev` look; `EmptyPaneOfferings`' own "Open a view" vocabulary is still the fixed 4-item list (missing Kanban), not yet driven by the same `CommandIndex.paneFillersOnly` ranking — deferred to T-149 |
| CMD-FR-024 | shipped | [`ShellTabStrip.swift`](../../Sources/TenonApp/ShellTabStrip.swift) (`newTabButton`'s `LauncherMenu` construction no longer passes `paneArrangements`/`arrangePanes`, matching the `copyTabID` omission already there), [`LauncherMenu.swift`](../../Sources/TenonApp/LauncherMenu.swift) (doc comments on the type and the two properties state the rule so a future anchor does not restore it) | `InteractionBoundaryFitnessTests.testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities` — sweeps `newTabButton`'s construction for the absence of all three tab-scoped labels and `tabLauncher(for:)`'s for their presence, red before the fix (`arrangePanes:`/`paneArrangements:` both found on the `+` anchor) and green after | no live `NSPopover` pixel check that the "Pane" section itself is shorter for `+`, same gap `CMD-FR-011`/`CMD-FR-020`/`CMD-FR-022` already carry |
| CMD-FR-012…017, CMD-FR-019, CMD-NFR-004, 005, 007 | shipped | [`TabReorder.swift`](../../Sources/TenonCore/TabReorder.swift) (`press`, and `insertionIndex`/`destination` now applied on every pointer move), `TabStripSurface` in [`ShellTitleBar.swift`](../../Sources/TenonApp/ShellTitleBar.swift) (`SurfaceView: NSControl`) with `updateReorder`/`restore`/`announceLanding`, [`WindowChrome.swift`](../../Sources/TenonApp/WindowChrome.swift), workspace move/persistence | reorder core/workspace/hosted tests; `TabStripReorderTests` — drag region membership, `NSControl` superclass, keyboard hand-back, press-drag-release, **the order already changed with the button still down**, **an out-of-band release putting the row back**, select, close, `+` uncovered, deferred dismantle, and delivery into a window the window server never listed; `testASweepAcrossUnevenChipsMovesTheTabOnlyTheWayThePointerIsGoing` for the feedback loop a live preview closes; interaction fitness; [`scripts/internal/drag-region-probe.swift`](../../scripts/internal/drag-region-probe.swift) for the AppKit rule itself | the XCUITest drag passed against the mechanism a human drag falsified, so it does not discriminate CMD-M-003; the region test does. The reorder's *motion* — whether a person can follow which chip went where at 0.12 s — is human-observed; the suite proves only that the row is in the new order |

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
| 2026-08-09 | **Superseded in the delivery half** — the gesture is still asserted headlessly, but not through `NSWindow.sendEvent`; see the 2026-08-11 row. The whole gesture is asserted headlessly and the workspace's tab order must change. | The earlier claim that synthetic events never reach a view (`downs=0`) was wrong — they had been built without a valid `windowNumber` against a window that was never key. Correcting it turned "only a human can test this" into a test, and that test immediately found a fatal exclusivity violation: `dismantleNSView` wrote `@State` from inside `GraphHost.invalidate()`. | the account that delivery has no headless seam |
| 2026-08-09 | **The premise of all three previous rows was false.** macOS does not consult the hit-tested view: AppKit uploads a **drag region** to the window server, which starts the move from it. `mouseDownCanMoveWindow == false` is honoured by that region builder **only from an `NSControl` descendant**. `TabStripSurface.SurfaceView` is therefore an `NSControl`. | Read back through `NSWindow._lastDragRegionDataDescription` with a two-sided oracle (close button must be outside the region, empty chrome inside): as an `NSView` the chips are **inside** the region, as an `NSControl` they are **outside**, chrome unchanged in both. This is why every headless seam passed while the bug lived — `NSWindow.sendEvent` injects below the window server, so no test using it can observe the region. | the account that hit-testing decides the drag; and `isMovable = false`, now measured to empty the region including the chrome zone |
| 2026-08-10 | **A chip's fallback name is the tab's own number, not its position.** `Tab` carries a `number` assigned by `Workspace.nextTabNumber` when it joins a workspace, persisted in `TabRecord`, and read by `ShellTitleBar.tabTitle(for:)`. | Reported the moment the drag started working: drag one unnamed tab past another and the chips swap while `"Terminal \(index + 1)"` swaps the labels back, so the strip reads exactly as before and a working reorder is indistinguishable from a broken one. T-096 recorded this and exempted itself because no criterion named the title — true of the criteria, and beside the point, since the title is how the criteria's gesture is observed. Number reuse after closing the highest-numbered tab is accepted deliberately: the promise is that no tab's name changes, not that no number returns. | `"Terminal \(index + 1)"`, and T-096's account of the positional fallback as out of scope |
| 2026-08-10 | **The region rule has a second axis, and the strip was failing it.** A view leaves the drag region by being an `NSControl` **and accepting first responder**; a control answering `acceptsFirstResponder == false` is put back inside the region whole. `SurfaceView` therefore keeps `NSControl`'s own answer and overrides that property nowhere. The keyboard is kept by a different mechanism than the one assumed: `mouseDown` never calls `super`, and AppKit focuses no view on a press by itself. | Same read-back, varying only the responder overrides: `NSControl` alone → outside; `+ acceptsFirstResponder = false` → **inside**; the shipped shape → **inside**. A separate probe drove a press at the surface with the property left alone and read `window.firstResponder` back: the stand-in terminal kept it. Both axes are now in `scripts/drag-region-probe.swift`, which had been measuring a control the app no longer resembled and reporting the rule as held. | the `acceptsFirstResponder = false` override and the claim that a control necessarily steals focus from the terminal |
| 2026-08-11 | **A press is routed by the window's own hit test, not by `NSWindow.sendEvent`.** `send` asks the frame view which view owns the point, delivers `mouseDown` there, and holds that view for the drags and the release the way AppKit holds it. | `NSWindow.sendEvent` dispatches only for a window the window server carries on its on-screen list, and a machine running the suite without a display session never puts one there — so this was never a flake and no rerun could fix it. Measured on a window held off that list: `windowNumber` assigned, `event.window` resolving, the frame view hit-testing the press to `TabStripSurface.SurfaceView`, and `mouseDown:` never called; the strip's own closures answered a direct call correctly the whole time. Holding every window in this file off that list reproduces exactly the four CI failures of run `31480549761` and leaves the other twelve green; with the routing above, all seventeen pass in both states. | the account that `NSWindow.sendEvent` is the headless delivery seam |
| 2026-08-11 | **How a row looks is a separate question from whether it won a ranking.** `PaletteRowChrome` owns the icon column, title slot, accessories, density metrics, hover wash and selected pill, and takes no ranking data at all; the ranked command row, an appended provider result, and the fixed Copy Tab ID utility each compose it. | A row presentation typed on `CommandMatch` — the ranking system's *output*, carrying `score` and `titleMatch` — left every caller that had not been ranked choosing between two bad answers, and both shipped: the palette fabricated `CommandMatch(score: 0, titleMatch: [])` for dynamic results, and the tab footer refused to lie and hand-rolled a `Button`, which is why the operator photographed a footer with no hover while `CMD-NFR-005` read `shipped` on `source/design review`. An abstraction whose non-conforming callers must lie or copy is at the wrong altitude, so the altitude moved. | the row presentation typed on `CommandMatch`, the fabricated dynamic-result match, and the hand-rolled footer button |
| 2026-08-13 | **The strip previews a reorder by performing it.** While the pointer is down inside the admitted band, the dragged tab already stands in the place the pointer means, animated by one shared constant; an out-of-band release returns it to the index the drag began at. Taken from `references/kero` (`ContentView.swift:1250-1267`), whose own comment names the same reason Tenon found in T-101 for avoiding a pasteboard drag. | A marker drawn beside the chips is a second description of the destination, and two descriptions of one thing can disagree: the caret came from `insertionIndex` while the commit ran that index through `destination`, so the strip could stand a marker in a gap that releasing refused — a class of defect `testEveryGapTheCaretCanStandInEitherMovesTheTabOrIsNotDrawn` existed to police and that this removes by construction. The rules are unchanged; they are applied continuously. The loop settles because a gap is counted from midpoints, so a moved tab lands under the pointer and goes on naming the same gap — asserted over deliberately uneven chips, re-laid after every move, in `testASweepAcrossUnevenChipsMovesTheTabOnlyTheWayThePointerIsGoing`. | the insertion caret, `TabReorder.caretX`, `TabInsertionCaret`, and commit-on-release |
| 2026-08-13 | **Kero's window route is rejected, and its per-chip SwiftUI gesture with it.** The chips keep their AppKit surface; only the reorder model changed. | Two measurements, both on macOS 26.4. (1) `window.isMovable = false` — kero's lever — empties the drag region to **0 rects, chrome included**, which is `CMD-FR-016` gone; kero pays for that with `WindowDragGesture`, `macOS 15.0+` against this package's `.v14` floor. Recorded alongside it, because it is the finding that made the choice a real one rather than a constraint: the region is **not** front-view-wins — a carving `NSControl` keeps its rect out of it from *behind* the movable container SwiftUI flattens the chips into, so chips owning their own clicks was reachable without that lever. (2) It is not reachable with evidence: a SwiftUI `DragGesture` in an `NSHostingView` swallows a synthetic `leftMouseDown` into a nested event-tracking loop fed only by a real `NSApp.run()`. Driven three ways — `window.sendEvent`, `NSApp.sendEvent`, and a prefilled event queue — it either never fires or **blocks the process indefinitely**, which in a shared `Tests/` target takes every concurrent agent's run down with it. Kero verifies by hand (`kero/CLAUDE.md`); this repo's bar is `swift test`, and T-101 is the record of what an unprovable gesture costs here. | the proposal to copy `references/kero`'s window and gesture layers verbatim |
| 2026-08-19 | **`.open`'s grouping splits by `fillsPane`, not by category, and every anchor gains run-command parity with the empty-pane card (`CMD-FR-022`, `CMD-FR-023`, T-188).** A new grid row type (`CommandTile`) is declared in `EmptyStateCard.swift`, never `LauncherMenu.swift`. | Operator-reported, two screenshots: T-187's per-category grouping left "New Tab" and "Split Right"/"Split Down" each paying for a one- or two-row section header, and only the empty-pane card could run typed text as a shell command — a visible inconsistency between two presentations of what this PRD's own vocabulary table (`§3`) calls **one** shared launcher. `EmptyPaneOfferings`' hardcoded "Open a view" list was found to be exactly the "second command registry" that table already names as a non-goal, but rewriting it needs `SlotContent`'s closed-enum id→content mapping to become dynamic (T-149's scope) — out of reach here without widening the blast radius of a presentation fix into a dispatch-mechanism rewrite, so it stays a known gap. `CommandTile` reimplements `LaunchTile`'s hover chrome for an SF-Symbol icon rather than composing `PaletteRowChrome`; `CMD-NFR-008`'s fitness test (`testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics`) scans `LauncherMenu.swift` and `PaletteOverlay.swift` specifically for a restated `.onHover`, so the type is declared beside its twin in `EmptyStateCard.swift` instead — the file the same rule already treats as the home for grouped-layout row chrome. | T-187's per-category `groupedContent` iteration over `LauncherSections`; the account that a tile grid's row type could live inside `LauncherMenu.swift` |
| 2026-08-19 | **"Shared launcher" is restated as shared vocabulary, not shared callbacks; a new rule, `CMD-FR-024`, says a tab-scoped utility may be supplied only by the anchor that names a real existing tab (T-189).** | Operator-reported, repeatedly, across earlier passes on this same launcher: the `+` popover drew "Arrange Panes" — a utility this PRD's own `§3` vocabulary already scoped to "same-owner local action such as Copy Tab ID" — even though `+`'s own `CMD-FR-004` and this PRD's `§1 Proposed outcome` both say `+` **creates a destination**, naming no existing tab. Reading `ShellTabStrip.swift` found the mechanism: `copyTabID` was correctly left `nil` for `+` all along, but `paneArrangements`/`arrangePanes` were wired to `activeWorkspace?.activeTab`/`store.arrangeActiveTab` — whichever tab merely happened to be active, not a tab `+` had anything to do with. `CMD-FR-022`'s "Pane" section folds Split Right/Split Down/New Tab into the same section as this utility, and those *are* correctly scoped to `+` (they resolve through `sendInNewTab`'s fresh placeholder tab), which is what let the wrongly-scoped utility hide beside correctly-scoped commands without either author noticing the difference. | the account that unifying `+` and tab-right-click into one `LauncherMenu` type means unifying every optional argument passed to it |

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
| 2026-08-11 | current sources, `swift test --filter TabStripReorderTests` | `TabStripReorderTests` after routing the press through the window's hit test | passed **17 / 0**, and passed **17 / 0** again with every window in the file held off the window server's on-screen list — the state that fails four of them on CI run `31480549761` | the window server's own arbitration of a hardware press is still outside any headless seam, and is covered by the region test and `scripts/internal/drag-region-probe.swift` |
| 2026-08-10 | staged app, `SurfaceView` with no `acceptsFirstResponder` override, binary 09:29 | **human drag on a tab chip** | **accepted** — "kéo thả ok rồi, tab có thay đổi" | the same drag exposed T-105: the chips moved and the labels moved back, so the working reorder read as none |
| 2026-08-10 | current sources | full suite | passed, **1735 / 0** | includes T-105's tab-number work; `TenonUITests` still needs an app host |
| 2026-08-11 | current sources, `swift test --filter InteractionBoundaryFitnessTests` | `CMD-NFR-008` and the row half of `CMD-NFR-005` after the row-chrome split | passed **21 / 0**, including `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics`; `LauncherListHeightTests` **3 / 0** and `LauncherSectionsTests` **5 / 0** hold the arithmetic and the displayed order | full suite the same day: **1968 tests, 3 failures**, all three outside this capability (`AgentTranscriptPathTests`, `PluginWebSurfacePoolTests`, `ScriptSurfaceFitnessTests`, each owned by another task in flight). No picture: every offscreen snapshot route in the app renders a pane, the diff, the changes panel, the Agent Lens timeline, or the sidebar, and the launcher is an `NSPopover` none of them reach; that the wash follows a moving pointer stays human-observed |
| 2026-08-13 | current sources, `swift test --filter "TabReorderTests|TabStripReorderTests"` | the live reorder replacing the caret preview (T-144) | passed **40 / 0**. The two assertions that separate the designs failed first and for the right reason — the row was still in its original order with the button down — and pass after. A leftward drag is asserted for the first time, because the loop is not symmetric: travelling right the moved tab lands left of the pointer, travelling left it lands right | the *motion* is human-observed; the suite proves the order, not that a person can follow which chip went where at 0.12 s |
| 2026-08-13 | current sources, `swift test` | full suite after the change | passed **2102 / 0** in 141 s | a hardware drag on an installed build is not claimed here; the window server's own arbitration remains covered by the region test and `scripts/internal/drag-region-probe.swift`, which passed on macOS 26.4 before the change |
| 2026-08-19 | current sources, `swift test --filter "LauncherMenuGroupedLayoutTests\|LauncherMenuRunCommandTests\|InteractionBoundaryFitnessTests\|DomainTagFitnessTests"` | `CMD-FR-022`, `CMD-FR-023` | passed **36 / 0**, including the two-per-row grid-packing test, the folded-Pane-section cost bound, the three run-command placement/absence tests, and `testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics` (red once, when `CommandTile` was still declared inside `LauncherMenu.swift`; green after it moved to `EmptyStateCard.swift`) | no live `NSPopover` pixel check, same gap `CMD-FR-011`/`CMD-FR-020` already carry |
| 2026-08-19 | current sources, `swift test` | full suite | passed **2392 / 0** in 162 s (`AgentFleetIntegrationTests.testOneEventHandlerFansOutTwoSupervisedAgentsAndPublishesTheAggregate` failed once on an earlier run of the same unmodified tree, unrelated to this task's files, and passed on the clean re-run reported here — recorded as flake, not a regression) | none known |
| 2026-08-19 | current sources, `swift test --filter InteractionBoundaryFitnessTests/testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities` | `CMD-FR-024` | red first — `XCTAssertFalse failed - the + anchor wires arrangePanes:` and `paneArrangements:` — against the pre-fix `ShellTabStrip.swift`; green after removing both from `newTabButton`'s `LauncherMenu` construction | none known |
| 2026-08-19 | current sources, `swift test` | full suite | passed **2393 / 0** in 170 s | no live `NSPopover` pixel check, same gap this section already carries for `CMD-FR-011`/`CMD-FR-020`/`CMD-FR-022` |

## 14. Change history

| Date | Change | Why |
|---|---|---|
| 2026-08-09 | Initial canonical PRD written from current source, tasks, manifests, tests, and direct user corrections. | Replace scattered/stale implementation context with one shipped-state contract. |
| 2026-08-09 | Tab-input mechanism corrected after a human drag falsified the shipped account (T-101). | The PRD claimed server-side dragging was disabled; measurement showed the lever is per-view, not per-window. |
| 2026-08-11 | `CMD-NFR-008` added and `CMD-NFR-005` given a test seam for its row half (T-124). | A shipped design requirement whose only evidence was `source/design review` was being broken in plain sight by the launcher's Copy Tab ID footer. |
| 2026-08-13 | The reorder preview became the reorder itself, and `CMD-FR-013`/`CMD-FR-015` were restated for it (T-144). | The operator asked for `references/kero`'s tab drag. Its reorder model is takeable and shipped; its window and gesture layers are not — measured, `window.isMovable = false` empties the drag region including the chrome (`CMD-FR-016`), its `WindowDragGesture` replacement needs macOS 15 against a macOS 14 floor, and a SwiftUI `DragGesture` in an `NSHostingView` cannot be driven by any headless route this suite has. |
| 2026-08-17 | The empty tab/pane card became search-first: its icon badge, title and subtitle were deleted, a focused field took their place, and a typed query is also offered as a command line (`CMD-FR-020`, `CMD-FR-021`, T-176). | The operator asked for the decoration to go, and this PRD had already promised empty tab/slot the launcher presentation while the tree gave it a poster — a person met the unsearchable surface most often and the searchable one least. The offer to run what was typed was the operator's choice of scope: an empty pane is where `npm run dev` is typed. Ranking reuses `CommandIndex.rank`, so the card cannot disagree with the palette about what a query means. |
| 2026-08-19 | `.open`'s grouped layout splits by `fillsPane` instead of by manifest category, and every `LauncherMenu` anchor gains typed-query run-command parity with the empty-pane card (`CMD-FR-022`, `CMD-FR-023`, T-188). | Operator-reported from two screenshots: T-187's category-per-section grouping left "New Tab"/"Split Right"/"Split Down" each paying for a one- or two-row header, and only `EmptyStateCard` could run typed text as a shell command — the same launcher this PRD's own vocabulary table calls one shared presentation was visibly two. `EmptyPaneOfferings`' hardcoded "Open a view" list, found to be the "second command registry" `§3` already names as a non-goal, is left unrewritten — that needs T-149's dynamic `SlotContent` mapping, not a presentation fix. |
| 2026-08-19 | The `+` anchor no longer wires `paneArrangements`/`arrangePanes`; `CMD-FR-024` states that a tab-scoped utility is offered only by the anchor naming a real existing tab (T-189). | Operator-reported, in Vietnamese, and not for the first time on this launcher: clicking `+` — which creates a new tab — surfaced "Arrange Panes", and arranging panes has no meaning for a tab that does not exist yet. The wiring found on inspection was worse than a presentation glitch: `arrangePanes` called `store.arrangeActiveTab`, so choosing it from `+` silently rearranged whichever tab was merely active, not anything the `+` click named. `copyTabID` had already been correctly left unwired for `+`; this brings `paneArrangements`/`arrangePanes` in line with it and states the rule generally so a future unification pass does not restore it a third time. |
