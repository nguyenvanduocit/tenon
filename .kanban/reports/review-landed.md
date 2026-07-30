# Adversarial review — the four "LANDED" slices, before commit

Reviewed 2026-07-30, 20:02 → 22:10, against a working tree with **nothing committed since
`3c06770`**. Read-only: no source, test, plugin, doc or kanban file was modified; no git
write command was run; `swift build` / `swift test` were deliberately not run (another
worker owns `poc/.build` this wave). Every finding below is grounded in a `file:line` on
disk or in `git diff`.

**Headline: T-026 is safe on the mid-edit question, and blocked on a different one — its
menu criterion is asserted only in a test target `swift test` never builds. T-022 has two
real defects. T-024 and T-025 are committable.**

---

## Findings, most severe first

### 1. RESOLVED DURING REVIEW — T-026 was mid-edit at 20:05, and has since landed clean

This was the review's opening blocker and it has cleared. Recording it because the
resolution is what makes the rest of the T-026 verdict trustworthy.

At 20:03 `.kanban/board.md` still read `session d25d3c17 · Claiming …` with all five
criteria unchecked, and the code moved underneath the review:

| time | evidence |
|---|---|
| 20:03 | `git diff` of `SpatialCanvasView.swift` showed the Duplicate item's `isEnabled:` as a **three-term inline expression** (`slot.rect.width >= … \|\| slot.rect.height >= … \|\| SpatialLayout.bestEmptyRect(…) != nil`) — a second copy of a rule that also lives in core |
| 20:04:21 | `Workspace.swift` written — gained `canDuplicateSlot(_:)` at `Workspace.swift:498-505` |
| 20:04:35 | `SpatialCanvasView.swift` written — `:500` became `isEnabled: store.catalog.canDuplicateSlot(slotID)` |
| 20:05:00 | `WorkspaceDuplicateSlotTests.swift` written — asserts `canDuplicateSlot` at `:45` and `:186` |

**Current state (22:09):** those three files have been byte-stable for two hours
(`SpatialCanvasView.swift` 20:04, `Workspace.swift` 20:04, `WorkspaceStore.swift` 19:54),
and `.kanban/board.md:17` now reads **"LANDED; LOCKS RELEASED"** with all five criteria
ticked in `.kanban/tasks/T-026-duplicate-pane-menu.md`.

**This matters for confidence:** the tree I reviewed at 20:05 *is* the final state. The
duplicated inline predicate was collapsed into one core call before it settled — there is
no half-renamed symbol, no unreferenced new function (`canDuplicateSlot` has a live caller
at `SpatialCanvasView.swift:500`), no test referencing a symbol that does not exist, and
`SlotTypeOption` is deleted with **zero** references repo-wide. On the "is it half-written"
question specifically, T-026 is clean.

---

### 2. BLOCKING for T-026 — its own criterion is asserted only in a target `swift test` never builds

`poc/Package.swift` declares exactly three test targets:

- `poc/Package.swift:105` — `TenonIntentCoreTests`
- `poc/Package.swift:106` — `TenonCoreTests`
- `poc/Package.swift:110` — `TenonAppStateTests`

`poc/Tests/TenonAppTests/SpatialCanvasInteractionTests.swift` is in **none** of them. It is
Xcode-only. T-024's own task file already records this in bold
(`.kanban/tasks/T-024-smart-open-reuses-a-pane.md:10-13`: "*that directory is Xcode-only,
so the provider test landed in `Tests/TenonAppStateTests/`*"), and T-026 then put its menu
assertions there anyway.

T-026's criterion 4 is now ticked `[x]` in its task file, and its board line claims
`swift test` green. Both are true and neither covers this: the assertions that would catch a
regression in the menu shape were never compiled, so a green suite is not evidence for that
checkbox. (Criterion 2 — "*the rule is asserted in `TenonCoreTests` without a window*" — **is**
properly met: `WorkspaceDuplicateSlotTests.swift` is in `TenonCoreTests` and does run.)

The two tests that carry T-026 criterion 4 ("*The header menu is `Split · Stack ·
Duplicate · Close` — no type submenu anywhere in the tree*") are
`testHeaderContextMenuOffersSplitStackDuplicateAndClose` and
`testHeaderContextMenuDuplicateOpensASecondPaneWithTheSameContent`, both in that file.

**Failure scenario:** someone re-adds a submenu, reorders the items, or breaks the
`canDuplicateSlot` → menu wiring. `swift test` stays green and reports the same
`583/3`-style count, because those assertions were never compiled. The criterion is
unverified by the suite that gates this repo. (The pure catalog rule *is* covered — 
`WorkspaceDuplicateSlotTests.swift` is in `TenonCoreTests` and runs. It is the menu
projection that is not.)

---

### 3. HIGH — T-022: the launcher's ↓/↑ keys move the highlight to the wrong visible row

Three lines disagree about what "row N" means in `LauncherMenu.swift`:

- `LauncherMenu.swift:147-161` — `sections(_:)` **regroups** the ranked list by category
  when the query is empty (`"New"`, `"Split"`, `"Open"`), emitting each category's matches
  contiguously in first-appearance order.
- `LauncherMenu.swift:117-135` — the `ForEach` renders **that regrouped order**, but marks
  the highlight with `isSelected: ranked[selected].id == match.id`, i.e. indexed into the
  **flat** ranking.
- `LauncherMenu.swift:164-167` — `move(_:in:)` advances `selection` through the **flat**
  ranking too.

`PaletteOverlay.swift:128-129` does not group (`ForEach(Array(matches.enumerated()))` with
`isSelected: index == selected`), so display order and selection order coincide there. The
mismatch is new to the launcher.

**Failure scenario:** the user has run *Open Browser* (category `Open`) and *New Terminal*
(category `New`). Empty-query ranking is frecency-then-title, so it interleaves categories —
say flat order `[browser(Open), newTab(New), terminal(New), docs(Open)]`. `sections()`
renders `Open:[browser, docs]` then `New:[newTab, terminal]`. Press ↓ once: `selection`
becomes 1, which is `newTab` — displayed as the **third** visible row. The highlight jumps
over the row directly beneath it. Enter then runs a command two rows below where the eye
was tracking. The more the user actually uses the launcher, the more the ranking
interleaves and the worse the skipping gets.

---

### 4. HIGH — T-022: `Image("TenonMark")` has no bundle to load from under `swift run tenon`

`ShellTitleBar.swift:69` replaced `Image(systemName: "terminal.fill")` with the asset-catalog
lookup `Image("TenonMark")`. The catalog is `poc/Sources/TenonApp/Assets.xcassets/TenonMark.imageset/`
— **untracked** (`git status --porcelain` → `?? poc/Sources/TenonApp/Assets.xcassets/`).
`poc/Package.swift`'s `TenonApp` target (`poc/Package.swift:58-93`) declares **no
`resources:`**, and the board already records the precedent at `.kanban/board.md:22`
(T-016): "*SwiftPM does NOT run `actool`*".

**Failure scenario:** `swift run tenon` — the command CLAUDE.md documents as the dev launch
path — emits an unhandled-resource warning and renders a blank 14×14 gap where the app mark
should be, because the SF Symbol fallback was deleted in the same hunk. Separately, if the
commit stages only tracked files, the reference at `ShellTitleBar.swift:69` ships without the
asset it names, so the mark is missing for every other clone too.

Also note this hunk is **not in T-022's claimed-files list**
(`.kanban/tasks/T-022-plus-button-launcher-menu.md:11-21`) — see the attribution section.

---

### 5. HIGH — T-024: two different "where does this pane go" policies now ship side by side

- `WorkspaceStore.swift:143-152` — `openContent` reuses a qualifying pane, else
  `splitActiveSlot(.horizontal, content:)`. It **never consults `SpatialLayout.bestEmptyRect`**.
- `Workspace.swift:540-569` — `openSlot` (T-026's shared `addSlot`/`duplicateSlot` path)
  tries `bestEmptyRect` **first**, and only then splits, picking the axis that still fits.

**Failure scenario:** the active tab holds a 3-column-wide file-explorer tree at `x=0..3`
with 9 free columns beside it — precisely the state T-025's `fillWidth` exists to consume
(`SpatialLayout.swift:505-508`: "*or the canvas edge where none do*"), and the state
`WorkspaceDuplicateSlotTests.swift:65-95` constructs directly. The user clicks a file in the
tree:

1. `reusableSlotID` finds nothing — the tree is `.pluginView`, and
   `SlotContent.yieldsPane(to:)` (`Workspace.swift:22-34`) refuses to let a plugin view take
   a `.file`.
2. Fallback `splitActiveSlot(.horizontal)` on a 3-wide pane. `SpatialLayout.split` needs
   `minimumWidth * 2 == 6` (`SpatialLayout.swift:145`, `:227`) → returns `nil` →
   `splitSlot` returns `[]` (`Workspace.swift:594-599`).
3. Nothing opens. `WorkspaceIntentProvider.swift:352-358` correctly reports
   `dev.tenon.core.layout-unavailable` — while 9 empty columns sit unused.

The identical geometric question asked through `duplicateSlot` would have placed the pane in
that free space. This is invariant 6's "one typed semantic implementation" showing up as a
user-visible dead click, and it only becomes visible **because T-024 and T-026 land
together**.

---

### 6. MEDIUM — T-025: the double-click → fill wiring has no executing test

`SpatialCanvasGestureTests.swift` (in `TenonAppStateTests`, so it *does* run) asserts only
the pure rule `SpatialCanvasInteractionCoordinator.press(region:clickCount:)`. The two lines
that make the gesture do anything —

- `SpatialCanvasView.swift:457-459` — `card.onFillWidth = { self?.store?.fillSlotWidth(id) }`
- `SpatialCanvasView.swift:911-918` — the `switch press(...)` that dispatches `.fillWidth`

— are covered only by the non-running `TenonAppTests` target (see finding 2).

**Failure scenario:** delete the `card.onFillWidth` assignment entirely. `SpatialLayout.fillWidth`,
`WorkspaceCatalog.fillSlotWidth`, `WorkspaceStore.fillSlotWidth` and
`SpatialCanvasInteractionCoordinator.press` all still pass their tests; `swift test` is green;
double-clicking a pane header silently does nothing. T-025's task file already concedes
"*Not verified: the on-screen result of the gesture*" — this notes that the gap is structural,
not just a missing human look.

---

## Lower confidence — flagged, not asserted

- **`LauncherMenu.swift:176-198`, `isRunning` is never reset on the success path.** `.failure`
  sets it back to `false`; `.success` calls `dismiss()` and leaves it `true`. Whether this
  bites depends on whether SwiftUI tears down the popover's content view between
  presentations (`ShellTitleBar.swift:122-129`) — I did not verify that, and if the view is
  recreated the `@State` resets harmlessly. Costs one line to make unconditional.
- **`LauncherMenu.swift:23-28 / :68`** — `matches` is a computed property calling
  `rank(…, now: Date())`, and `onSubmit { runSelected(matches) }` recomputes it rather than
  using the `ranked` array the body rendered. Ordering is stable across the milliseconds
  involved, so I could not construct a failing input; noting it only because it is the same
  flat-vs-displayed confusion as finding 3.

## Checked and clean

- **Invariant 1 (only the `tenon` global):** no new global. `launcher` is a manifest field
  (`PluginManifest.swift:280`) projected to `Command.isLauncher` (`CommandIndex.swift:16`);
  no plugin-facing API was added.
- **Invariant 3 (`TenonCore` imports no AppKit/SwiftUI):** the four new core files/hunks
  (`SpatialLayout.fillWidth`, `WorkspaceCatalog.fillSlotWidth`/`duplicateSlot`/`openSlot`/
  `canDuplicateSlot`, `SlotContent.yieldsPane`, `CommandIndex.launcherOnly`) are pure value
  logic. No import added.
- **Invariant 7 (closed scoped-facility allowlist):** untouched. `workspace.content.open.v1`
  is an INTENT, not a `tenon.*` helper.
- **Invariant 10 (bounded lifetimes):** no new queue, timer, or retained handle. The launcher's
  one `Task { @MainActor … }` (`LauncherMenu.swift:180`) is a single awaited send.
- **Interaction-boundary law — T-024 is at the correct rung.** Plugin → host workspace domain
  is cross-principal, finite, unicast, one terminal result, no lifetime handle → INTENT is
  right. `CoreIntentCatalog.swift:1397-1426` reuses the existing `workspaceControl` binding
  (no new capability), declares its errors, and uses the `programmatic` audience. The
  built-in `ChangesPanelView.swift:500` calls `store.openContent` **DIRECT** — same owner,
  same typed service. That is invariant 6 satisfied, and it is the best-built slice here.
  `showDiff` was genuinely deleted (0 references repo-wide).
- **T-024 scope handling is correct.** `WorkspaceIntentProvider.swift:339-346` focuses the
  scope pane first, and `WorkspaceCatalog.focusSlot` (`Workspace.swift:684-704`) does switch
  the active workspace *and* tab, so "the scope pane's tab takes the content" holds.
- **T-026 left no residue.** `SlotTypeOption` is deleted and has **zero** references
  repo-wide. `canDuplicateSlot` is called from `SpatialCanvasView.swift:500` (as of 20:05).
- **`SpatialLayout.fillWidth` geometry is sound.** Row-overlapping neighbours in a valid
  layout are necessarily wholly left or wholly right of the target, so the two stop
  computations at `SpatialLayout.swift:534-543` are exhaustive; `isValid(proposal)` at `:552`
  is a second gate; a no-op yields `isValid: false` so `applyResize` (`Workspace.swift:936-938`)
  emits nothing.
- **Plugin manifest/JS drift:** file-explorer keeps `workspace.tab.create.v1` in `uses`
  legitimately — `poc/plugins/file-explorer/main.js:304` still sends it via `call.send(…)`,
  which `ShippedPluginsTests.swift:75-115`'s regex covers. I initially flagged this as a
  stale declaration and it is not one.

---

## Files in `git status --porcelain` I cannot attribute to the four slices

**Do not stage these when committing T-022 / T-024 / T-025.**

| file(s) | likely owner | note |
|---|---|---|
| `poc/Sources/TenonCore/RecentWorkspaceStore.swift`, `poc/Sources/TenonApp/WorkspaceSidebarView.swift`, `poc/Tests/TenonCoreTests/RecentWorkspaceStoreTests.swift` | **T-032 recent-menu, session `1a79a1bf`** | `.kanban/board.md:16`; LANDED. Renumbered T-027 → T-032 at ~22:08 because another session took T-027 for catalog restore |
| the `openWorkspaceFolders` block **inside** `WorkspaceStore.swift` (`:33-37`, `:47`, `:204-207`, `:210-212`) | **T-032, session `1a79a1bf`** | **cannot be separated** — `WorkspaceStore.swift` carries T-024 + T-025 + T-026 + T-032 in one file |
| `?? poc/Sources/TenonCore/DiffRows.swift`, `?? poc/Tests/TenonCoreTests/DiffRowsTests.swift` | **T-028 diff rows** | appeared during this review (after 20:15); not present when the four slices were written |
| `?? poc/Tests/TenonCoreTests/ProjectRootTests.swift` | **T-030 pane cwd / project root** | appeared during this review |
| `poc/Sources/TenonApp/WindowChrome.swift` (`mouseDownCanMoveWindow` → manual `performDrag` + double-click zoom/minimise) | **unclaimed titlebar slice** | no task file, no board entry |
| `TenonTheme.titleBarHeight 46 → 36` (`TenonTheme.swift:44-46`) | **unclaimed titlebar slice** | T-025 claims only `tabMinWidth` in this file |
| `ShellTitleBar.swift` — `Image("TenonMark")`, chip height 32→26, icon 27→24 | **unclaimed titlebar slice** | T-022 claims this file only for "delete `slotControls`, `+` opens the popover" |
| `?? poc/Sources/TenonApp/Assets.xcassets/`, `?? poc/Design/`, `?? poc/scripts/generate-app-icon.sh` | **unclaimed app-icon slice** | see finding 4 — the `Image("TenonMark")` reference is worthless without these |
| `CLAUDE.md`, `README.md`, `poc/README.md`, `dev.sh`, `install.sh`, `?? poc/scripts/prune-build-cache.sh`, `docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md` | **T-023 build cache, session `68979863`** | `.kanban/board.md:27`, already in `Done` |
| `poc/project.yml` (deletes the `TenonCLI` Xcode target), `poc/Package.swift` (`TENON_CLI_IMPORTS_CORE_MODULE`) | **T-023** | compensated — `install.sh:129-130` still bundles `tenon-cli` into the app |
| `poc/Tenon.xcodeproj/project.pbxproj` (−240 lines) | **T-023, regenerated** | ⚠️ both T-022 and T-023 state they *deliberately did not* run `xcodegen`. Someone did. Matches the `project.yml` TenonCLI removal. |
| `poc/Vendor/TreeSitterTSX/Package.swift`, `poc/Vendor/TreeSitterTSX/README.md` | **T-016 editor stack, session `d7f580dd`** | still in `Doing` |
| `poc/Sources/TenonCore/PluginHost.swift` | **mixed: T-022 + T-021** | T-022's one additive `launcher` field sits in a file T-021 also edited |
| `.kanban/board.md` | **all sessions** | written at 20:03:19, during this review |
| `?? .kanban/tasks/T-023, T-027, T-028, T-029, T-030, T-031, T-032, T-033` | **T-023 = `68979863`; T-032 = `1a79a1bf`; rest = the backlog author** | eight untracked task files, none belonging to the four slices. `T-033-plugin-inventory-trust-is-fail-closed.md` appeared during this review — it is the task for the 3 pre-existing T-021 reds every slice's evidence cites |
| `?? .kanban/reports/` | **this review** | contains only `review-landed.md`, the single file this task was permitted to write |

---

## Verdict

| slice | SAFE TO COMMIT | blocking reason |
|---|---|---|
| **T-026** duplicate pane menu | **YES, code-wise — NO on its evidence claim** | The half-written worry is answered: files byte-stable 2 h, board LANDED, criteria ticked, no dead symbols, `SlotTypeOption` fully removed (finding 1). What is *not* true is criterion 4's evidence — its menu assertions sit in `Tests/TenonAppTests/`, which `swift test` never builds (finding 2). Commit the code; do not trust the checkbox. |
| **T-022** launcher menu | **NO** | ↓/↑ move the highlight to the wrong visible row as soon as ranking interleaves categories (finding 3). `Image("TenonMark")` renders blank under `swift run tenon`, and the asset catalog it names is untracked, so a tracked-files-only commit ships a dangling reference (finding 4). Both are one-file fixes. |
| **T-024** smart open | **YES, with one caveat** | Cleanest slice here: correct rung (INTENT for the plugin boundary, DIRECT for the built-in panel), one typed service, `showDiff` genuinely deleted, 14 running tests. Caveat: the narrow-pane dead click of finding 5, which only becomes reachable because T-026's `bestEmptyRect`-first policy lands beside it. |
| **T-025** fill width + tab floor | **YES, with one caveat** | Core geometry is sound and covered by tests that actually run. Caveat: the gesture→store wiring is covered only by the non-running target (finding 6). |

### How to sequence the commit

`poc/Sources/TenonCore/WorkspaceStore.swift` and `poc/Sources/TenonCore/Workspace.swift`
each carry **T-024 + T-025 + T-026** interleaved, and `WorkspaceStore.swift` carries
**T-032** on top. Per-slice staging of those two files is not possible without hand-splitting
hunks. All four owning sessions have now released (`d25d3c17`, `dd2c89a8`, `fd5aa92f`,
`1a79a1bf`), so the realistic options are:

1. **Recommended — fix T-022 first, then commit all four slices plus T-032 as one changeset.**
   Findings 3 and 4 are both confined to `LauncherMenu.swift` / `ShellTitleBar.swift` +
   `Package.swift`, i.e. outside the two entangled core files. Fixing them costs far less
   than unpicking the entanglement, and `poc/Sources/TenonApp/Assets.xcassets/` must be
   `git add`-ed explicitly or finding 4 ships broken.
2. **Commit now and file findings 3–6 as follow-ups.** Defensible — none of them corrupt
   state, all four slices build — but the launcher ships with keyboard navigation that
   misbehaves the moment it is used twice, which is the first thing a human tester will hit.

Either way: stage deliberately. The unattributed table above lists two whole slices
(T-023 build-cache, and the unclaimed title-bar/app-icon work) plus in-flight T-028/T-030
files sitting in the same `git status`.
