# T-097: Customize each workspace's identity
> Let a person give every workspace its own name, icon, and semantic accent color.

- **priority**: medium
- **effort**: M

## Criteria
- [x] A workspace can be renamed and can choose or clear an icon and accent color from a native customization surface.
- [x] Name input is trimmed and validated without changing the workspace's stable identity, root directory, panes, tabs, or plugin scope; duplicate display names remain safe because identity is UUID-based.
- [x] The chosen identity is shown consistently anywhere the host already represents that workspace, including the workspace switcher/sidebar and workspace menus, without duplicating formatting rules per surface.
- [x] Customization persists in the workspace catalog, survives app restart and catalog restoration, and existing catalogs migrate to the current default appearance without data loss.
- [x] Reset restores Tenon's default derived name, icon, and color without deleting or recreating the workspace.
- [x] Icons and colors use the vocabulary and semantic tokens from `docs/designs.md`; color is never the only distinguishing signal, and VoiceOver announces a useful workspace name and customization controls.
- [x] Built-in SwiftUI calls a typed same-owner application service DIRECT; the task adds no plugin capability or public intent unless a separately justified cross-owner use case is classified under `docs/architecture-interaction-boundaries.md`.
- [x] Tests cover validation, duplicate names, default derivation, reset, persistence, migration from an uncustomized catalog, and preservation of workspace identity and contents.

## Owner / files (agent lock)

RELEASED — session `87cdeb99`, done 18:0x. Every file below is free.

## What shipped

**Identity is presentation; the workspace is a `UUID`.** `Workspace` gains one stored value,
`appearance` (mark + tint), beside the `name` it already carried. Renaming, re-marking and
re-tinting are three pure mutations on `WorkspaceCatalog` that each publish exactly one new
fact — `WorkspaceEvent.workspaceIdentityChanged` — and touch nothing else: id, root, tabs,
panes and selection come out of a rename byte-identical, which is asserted rather than
asserted-about. That is also the whole answer to duplicate names: nothing downstream reads a
name to find a workspace, so two workspaces called "Payments" stay individually addressable.
The sidebar renders exactly that case today (two folders both named `tenon`).

**Two naming rules that were previously written out at each call site now live in one place**
(`WorkspaceName`): what Tenon calls an unnamed workspace, and what a typed name becomes before
it is stored. Trimming collapses interior whitespace and newlines too — a name pasted out of a
terminal arrives with both, and a one-line row would render them as a gap it cannot explain —
and caps at 60 *characters*, so a composed name is never cut through the middle of one. An
empty name is not a third state: it is the reset signal, so clearing the field and pressing
Reset produce the same workspace.

**One inconsistency was removed on the way.** `WorkspaceCatalog.init` named its first
workspace `"Workspace 1"` while every later one took its folder's name, so the very first
workspace a person ever saw was the only one carrying a generic label. It now derives like the
rest. Nothing asserted the old string.

**The vocabulary is closed, and both halves of it are spoken.** Twelve marks
(`WorkspaceSymbol`), each carrying its own SF Symbol *and* its own word, so the picker, the
tooltip and VoiceOver cannot drift apart; a hosted test draws every one of them against the
running system, because a misspelled symbol renders as nothing at all and reads as a missing
icon rather than as a bug. The tints are `AccentColor` — the palette Settings already owns —
plus "follow the app accent", which is drawn as a **dashed outline rather than a dimmer dot**:
two circles of one hue would be told apart by brightness alone, and "inherited" is a shape.
The chosen mark and the chosen tint both carry a ring, and the tint additionally a check, so
no choice is signalled by colour alone. No feature-local hex exists; `TenonTheme.accentColor`
is the single rule for "this thing's tint, or the app's".

**No boundary change.** The form writes straight through `WorkspaceStore` — the typed
same-owner service that already owns every workspace mutation — so there is no draft state and
no second copy of the truth. No `tenon` member, no intent, no principal, no capability. The one
new fact rides the workspace EVENT family the law already inventories ("workspace/tab/pane/
content/focus facts emitted by `WorkspaceStore`") and reaches plugins as
`workspace.identity-changed`, alongside `workspace.added`/`removed`/`selected`.

**Persistence is one optional key.** `WorkspaceRecord.appearance` is absent from every document
written before this task — that *is* the migration: a missing key decodes to nil and restores
as the default, so an older catalog comes back looking exactly as it did. An uncustomised
catalog still writes no key at all, and a mark or tint from a newer build degrades that one
value while keeping the workspace, exactly as an unknown pane content degrades one pane.

Files: `Sources/TenonCore/WorkspaceIdentity.swift` (NEW — `WorkspaceName`, `WorkspaceSymbol`,
`WorkspaceAppearance`), `Sources/TenonCore/Workspace.swift` (stored `appearance`, `customName`,
`hasCustomIdentity`, three mutations, one event), `Sources/TenonCore/WorkspaceStore.swift`
(three verbs + the bus name), `Sources/TenonCore/WorkspaceCatalogStore.swift` (record, restore,
derived launch name), `Sources/TenonApp/WorkspaceIdentityViews.swift` (NEW — metrics, mark,
announcement, popover), `Sources/TenonApp/TenonTheme.swift` (`accentColor`),
`Sources/TenonApp/WorkspaceSidebarView.swift` (row only),
`Tests/TenonCoreTests/WorkspaceIdentityTests.swift` (NEW, 27),
`Tests/TenonAppStateTests/WorkspaceIdentityFormTests.swift` (NEW, 10).
`docs/domains.md` needed no change: every new file carries `workspace-model`, the tag the
sidebar, the catalog and the theme already carry.

## Evidence

- **37 / 0** across both new suites; full suite green (see the run below). Both files are under
  400 lines, so no MARK tags are owed.
- **10 / 10 mutations caught**, one per run, each restored from a `cp` backup and verified
  byte-for-byte (never `git checkout` — this tree carries four other sessions' uncommitted
  work). M1 the empty-name guard (5 tests), M2 the length cap, M3 rename stops sanitising
  (3), M4 the no-op guard (2), M5 reset leaves the name (3), M6 the default appearance is
  written anyway, M7 restore drops the appearance (2), M8 `customName` always answers (4),
  M9 the mark ignores its own tint, M10 the grid fills each row instead of balancing.
  M10's first attempt was refused by the compiler rather than by a test, and was re-run.
- ⚠️ **One mutation came back into the tree after its restore, and the suite is what caught
  it.** M8's restore was verified byte-for-byte at the time it ran, yet `customName` was found
  reading `name` again in the next full run — a peer session was editing `Workspace.swift`
  during that window and wrote back a copy it had read while the mutation was applied. Nothing
  was lost and the restore was not at fault; the lesson is that on this shared tree **a
  `cmp`-verified restore is only true at the instant it is taken**, and mutating a file another
  session is live in can hand that session the mutation. All ten sites were re-audited by grep
  afterwards and only M8 had leaked. Whoever mutates a hot file next: check the site again after
  the batch, and prefer files no `Doing` task lists.
- **Rendered, not just asserted.** The form was photographed offscreen through the same
  `NSHostingView` + `cacheDisplay` route `PaneViewSnapshotWriter` uses, and the picture found
  two things 35 green tests did not: the mark grid laid out **8 then 4** (a stub row reading as
  an interrupted list, now 6 × 2 and pinned by a test), and the app-accent swatch rendered as a
  **dull brown dot** beside the real amber one. The sidebar was then photographed through
  T-098's new `TENON_SIDEBAR_SNAPSHOT`: an uncustomised catalog is pixel-unchanged — muted
  folder, amber folder when selected — which is the "nothing changes for anyone who does not
  use this" claim with a picture behind it.
- The row's explicit VoiceOver label was a regression risk the moment it existed: an
  `accessibilityLabel` replaces the children it would otherwise read, so the tab and unseen
  counts had to be put back into it. `WorkspaceRowAnnouncement` is a pure function precisely so
  that is a test and not a memory.

## Limits, stated not sold past

- **Order of work was implementation-then-test, not test-then-implementation.** The evidence
  bar is met by the 10 mutations rather than by a recorded red-first run; that is a weaker
  provenance and worth saying plainly.
- **`SettingsView.swift` still spells `Color(nsColor: NSColor(hex: accent.hex))` inline** for
  the app-accent picker, one rule now written twice. It was left alone deliberately: that file
  was under another session's additive-only claim while this landed. Converging it on
  `TenonTheme.accentColor` is a one-line follow-up.
- **The popover is reachable only from the row's context menu.** No keybinding, no palette
  command, no menu-bar item — adding one is a public command registration and therefore a
  boundary decision (invariant 8), not a free addition.
- **The tint is drawn on the selected row only.** An unselected row stays muted, so a colour
  chosen for a background workspace is invisible until it is selected. That is deliberate — a
  sidebar of tinted rows is noise, not orientation — but it does mean the tint is a weaker
  signal than the mark, which always shows.
- **The popover's behaviour under catalog churn is reasoned, not measured.** `WorkspaceRow`
  re-renders on every catalog mutation, and this file already documents that hazard for menus
  ("macOS rebuilds an open menu whenever its owning view re-renders"). A popover with a fixed
  `frame(width:)` and content-driven height should not shift the way the Add-Workspace menu
  did, and `ForEach`'s id keeps the row's identity — and therefore the popover — stable across
  a re-render. Neither claim was observed live: a popover needs a window, and this shell has no
  Screen Recording grant. If it does jitter while a terminal is churning, the fix is the same
  one the menu got — move it to a view that does not read `store.catalog`.
- **No light appearance exists to check** (`TenonTheme` is one fixed dark palette), and the
  focus ring is not photographed: an offscreen render has no key window and no first responder.
- Not committed.

## Notes
- This task customizes per-workspace identity. It does not replace the app-wide accent preference from T-002.
- Prefer a curated native icon and semantic-color vocabulary over arbitrary symbol names or feature-local color values.
