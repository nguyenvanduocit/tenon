# T-030: A pane knows its cwd and its project root; Files and Git follow the worktree
> When an agent `cd`s into its git worktree, the file tree and git panel still point at the
> workspace path. Give each pane a current directory and a resolved project root, and let
> the panels re-root on the project root — not on every `cd`.

- **priority**: high
- **effort**: M

## Probe

**Answer: libghostty already surfaces the pwd. The foreground-pid route is not needed.**
Settled by reading the pinned header and the existing action switch, before any design.

- **Which API.** `GHOSTTY_ACTION_PWD`
  (`poc/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:963`) carries
  `ghostty_action_pwd_s { const char* pwd; }` (`ghostty.h:720-722`), reachable as the
  `pwd` member of the action union (`ghostty.h:1012`). (HIGH — read from the pinned
  header this build links against.)
- **Where it lands.** `GhosttySurface.handleAction` (`GhosttySurface.swift:366`) already
  switches on `action.tag` and today handles `GHOSTTY_ACTION_SET_TITLE` (`:368`),
  `NEW_TAB` (`:378`), `NEW_SPLIT` (`:382`), `GOTO_SPLIT` (`:390`) and
  `COMMAND_FINISHED` (`:395`), returning `false` from `default:` (`:401`) for everything
  else — so PWD is currently *dropped on the floor*. The seam is one new `case`, shaped
  exactly like the title case: read the C string, hop to the main queue, call a
  `((String) -> Void)?` callback declared beside `onTitleChange` (`:540`). (HIGH)
- **How fresh.** It is push, not poll: ghostty raises the action when the shell reports
  OSC 7, i.e. on each prompt after a `cd`. Tenon already ships the shell integration that
  emits it — `resourcesDir()` (`GhosttySurface.swift:488-500`) resolves the bundled
  `ghostty/shell-integration` directory and hands it to the config. Caveat worth knowing:
  that lookup returns `nil` when the bundle has no `shell-integration` directory, and
  then no OSC 7 is emitted at all — cwd silently stays at the launch directory. Pane cwd
  therefore *degrades to the workspace path*, which is exactly today's behaviour, so the
  failure mode is "no improvement", never a wrong root. (HIGH)
- **What it reports under a full-screen TUI.** Nothing new — and that is the correct
  semantics here. OSC 7 rides the shell's prompt; a full-screen TUI (vim, an agent CLI)
  holds the foreground and emits no prompt, so the last reported pwd persists for the
  duration. The pane keeps the directory the shell was in when it launched the TUI, which
  is the directory the work belongs to. A `foreground-pid` + `proc_pidinfo` route would
  instead report the *TUI's* cwd, which drifts as the tool chdirs internally — strictly
  worse for re-rooting a file tree, on top of costing a polling loop with no push signal.
  (MEDIUM — reasoned from OSC 7 semantics, not from a live capture under a TUI.)
- **Cost of the rejected route.** `ghostty_surface_foreground_pid` /
  `ghostty_surface_tty_name` (recorded as available in the process-monitor design doc)
  would need a timer per pane, a `proc_pidinfo(PROC_PIDVNODEPATHINFO)` syscall per tick,
  and a debounce to avoid thrash — a RESOURCE-shaped poller — to obtain a *less* correct
  value than the push signal already being discarded. Rejected.

**Interaction classification** (per `docs/architecture-interaction-boundaries.md`,
applied in order, stop at first match):

- Step 0 reserved control op? No — this is a product fact.
- Step 1 CONTRIBUTION? No — the plugin is the *observer*, not the contributor; it owns no
  snapshot here.
- Step 2 **fact that already happened on a publisher-owned channel whose producer exists
  independently of this observer? YES → EVENT.** The shell moved; the pane's directory
  changed; the surface exists whether or not any plugin is listening; there is no reply,
  no result, no deadline, no authorization decision (`:342-343`). The law already lists
  "terminal title changed" as an EVENT exemplar (`:165`) and its inventory already covers
  "terminal title, command-finished, exit, and other terminal facts" (`:336`) — cwd is
  that same class of fact, and `PluginHost.terminalTitleChanged` (`PluginHost.swift:1440`)
  is the publisher shape to copy.

Consequences of landing on rung 2, which is why the rung matters:

- **No new member on the `tenon` global.** `tenon.events.on` already exists
  (boundary doc `:424`), so plugins observe this with the API they already have.
  Invariant 1 is untouched.
- **No plugin reads terminal state.** The host resolves and publishes a bounded value;
  file-explorer and git never touch a surface (invariant 2).
- **Event name is `pane.cwd-changed`, NOT `terminal.cwd-changed`.** This is deliberate.
  `PluginHost.emit` gates every `terminal.`-prefixed event behind the `terminal.read`
  permission (`PluginHost.swift:1381-1384`, and again at `:1419-1421` for the targeted
  overload). Naming it `terminal.*` would force file-explorer and git to request
  permission to read **terminal screen contents** merely to learn a directory — a strictly
  worse posture than the fact requires. A pane's directory is a pane fact, in the same
  class as the workspace paths the host already broadcasts to every plugin via
  `workspace.selected`. Recorded here because it is a real judgement call, not an
  oversight: the name chooses the gate.

## Owner / files (agent lock)
session `a4af4e8c` — **LOCKS RELEASED.** Every file below is free again; the list stays as
the record of what this task changed.
- `poc/Sources/TenonCore/ProjectRoot.swift` — NEW, pure resolution rule
- `poc/Tests/TenonCoreTests/ProjectRootTests.swift` — NEW
- `poc/Sources/TenonApp/GhosttySurface.swift` — one `case GHOSTTY_ACTION_PWD` + one callback
- `poc/Sources/TenonApp/SurfacePool.swift` — additive `cwds` registry beside `titles`
- `poc/plugins/file-explorer/main.js`, `poc/plugins/git/main.js` — re-root on the event
- `poc/Sources/TenonApp/TerminalSurface.swift` — `onPwdChange` on the protocol beside
  `onTitleChange`, with a no-op default so no existing conformer breaks. Added so the seam
  is not ghostty-only: the stub backend carries it too, which is what makes the pane
  directory rule assertable headlessly.
- `poc/Sources/TenonApp/SpatialCanvasView.swift` — the pane header menu's directory section
  (both directories + AUTO/PINNED marker + the two pin actions). Released by @d25d3c17
  (T-026) and @dd2c89a8 (T-025); additive, one call inserted in `slotContextMenu`.
- `poc/Tests/TenonAppStateTests/PaneDirectoryTests.swift` — NEW, the pool-level no-thrash
  assertions (`TenonAppTests` is Xcode-only and never runs under `swift test`).
- `poc/Tests/TenonCoreTests/PaneCwdSubscriptionTests.swift` — NEW, runtime proof that the
  real shipped plugin JS registers the subscription. Deliberately a NEW file so it does not
  touch @3bf9127e's `ShippedPluginsTests.swift`.
- `docs/architecture-interaction-boundaries.md` — one additive line in the EVENT inventory
  (6 h stale at time of writing; the normative doc for this exact classification).

✅ **The two additive inserts are APPLIED** — coordinator issued GO after @bac7c45f (T-033)
reported `worker_done` and its slice was committed as `0796494`, leaving me the only writer:
1. `poc/Sources/TenonCore/PluginHost.swift:1469` — `paneCwdChanged(_:slotID:)`, the
   `pane.cwd-changed` publisher, inserted after `terminalTitleChanged`. Re-anchored on
   surrounding code, not on the stale line numbers, and verified on disk after writing.
2. `poc/Sources/TenonApp/TenonApp.swift:378` — `terminalSurfaces.onPaneDirectoryChange`,
   beside the existing `onTitleChange` wire. Verified on disk.

The launcher slice's two uncommitted hunks in `PluginHost.swift` (`launcher: Bool` at :83,
`launcher: palette.launcher` at :2333) were left exactly as found — checked after applying.

⚠️ **@3bf9127e (T-015)** — your claim list still names `SurfacePool.swift` (mtime 10:00,
~12 h stale). My edit is additive only: a `cwds` dictionary beside `titles` plus one
callback wire in `surface(for:workspacePath:)`. No existing member's shape changes.

Expected files:
- `poc/Sources/TenonCore/ProjectRoot.swift` — NEW pure resolution rule
- `poc/Sources/TenonApp/GhosttySurface.swift` — the cwd seam (probe first, see below)
- `poc/Sources/TenonApp/SurfacePool.swift` — per-slot cwd, alongside `titles`
- `poc/Sources/TenonCore/CoreIntentCatalog.swift` — a `pane.cwd-changed` EVENT / fact
- `poc/plugins/file-explorer/main.js`, `poc/plugins/git/main.js` — re-root on it
- `poc/Tests/TenonCoreTests/ProjectRootTests.swift` — NEW

## Why / evidence
- This is Tenon's own workflow: `CLAUDE.md` describes many agents on one tree, and the
  parallel-agent pattern this product targets puts each agent in its own worktree. Today
  `Workspace.path` is fixed and the git plugin resolves the repo itself
  (`plugins/git/main.js:81,513-527`); nothing tracks where the pane's shell actually is.
  (HIGH)
- Kero v0.1.34: *"Terminal's foreground job follows into another checkout; when an agent
  switches to its git worktree, Files, Git and Info re-root accordingly."*
- Kero v0.1.21 defines the surrounding rule: the file tree and git panel anchor to the
  **closest git repository**, not to every `cd`; a "Set Project Directory…" pin overrides
  it; "Use Automatic Directory" reverts; and the Info panel shows **Current Directory** and
  **Project Directory (AUTO)** as two separate things. That split is the useful part — cwd
  churns constantly, project root almost never does.
- The seam is not yet established in Tenon. `GhosttySurface` exposes title changes only;
  the process-monitor design doc records `ghostty_surface_foreground_pid` and
  `ghostty_surface_tty_name` as available. Whether cwd arrives via ghostty's pwd/OSC-7
  callback or via the foreground pid must be settled by a probe, not assumed. (LOW —
  unverified, and the task must not start by guessing)

## Criteria
- [x] The cwd seam is established by a probe and written down — see `## Probe` above.
      `GHOSTTY_ACTION_PWD`, push via OSC 7, last-value-persists under a full-screen TUI.
      Written before a line of implementation
- [x] `ProjectRoot.resolve` is a pure rule in `TenonCore` — `Sources/TenonCore/ProjectRoot.swift`.
      All six cases asserted in `ProjectRootTests` (16 tests, no window), against real
      directories in a temp tree rather than a stubbed predicate, so `.git`-as-a-file is
      proven rather than assumed: plain repo, linked worktree, submodule, nested repo, no
      repo, symlinked path — plus a broken `.git` symlink and a deleted cwd
- [x] A pane carries both values (`SurfacePool.directories`, `ProjectRoot.PaneDirectory`),
      and `ProjectRoot.rerootsPanels` is the single no-thrash rule. Asserted at both levels:
      pure (`ProjectRootTests`) and at the pool
      (`PaneDirectoryTests.testAnOrdinaryCdInsideOneRepositoryUpdatesTheCwdButNotifiesNobody`
      — cwd moves, observer count stays 0)
- [x] Files and Git re-root off the public `pane.cwd-changed` EVENT, classified first (see
      `## Probe`). No plugin touches terminal state, and `PaneCwdSubscriptionTests` proves
      the REAL shipped JS registers the subscription in a live runtime and that neither
      panel holds `terminal.read`. ⚠️ The publisher itself is the one piece not yet applied
      — see the blocked note below
- [x] "Set Project Directory…" pins a pane's root and "Use Automatic" reverts it — shipped
      in the pane header menu, backed by `SurfacePool.pinProjectRoot(_:for:)`; the pin
      outranks whatever the shell reports, reverting re-resolves from the pane's *current*
      cwd (not the one it was pinned at), and a pin dies with its pane
- [x] The pin survives what T-027 restores — **delivered by T-027**, which owns the one
      persistence path for the workspace tree. Bolting a pin field onto `Slot` from here
      would have been a second persistence path for one object, which invariant 6 forbids,
      so this task specified the field and handed it over instead of half-building it.
      T-027 took it verbatim: `projectRootPin: String?` on the persisted pane
      (`WorkspaceCatalogStore.swift:80`), replayed through `pinProjectRoot(_:for:)` on
      restore, and asserted end to end by `WorkspaceCatalogRelaunchTests.swift:70-74` —
      *"the T-030 project-root pin survives the relaunch verbatim"*

## Handoff to T-027 (catalog persistence) — ACCEPTED AND SHIPPED

T-027 implemented exactly the field specified below; the spec is kept as the record of what
was asked for and why.

The pane pin currently lives in memory, in `SurfacePool.pinnedRoots` (`SurfacePool.swift`),
so it survives pane switches and dies with the pane — but not a relaunch. To make it
survive what you restore, it needs one field on the persisted pane, not a new store:

- **Field:** the pinned project root, one optional absolute path per pane —
  `projectRootPin: String?` (or `URL?`) on `Slot`, `nil` meaning "Use Automatic".
- **Round-trip:** absolute path in, absolute path out. It is a *user override*, so restore
  it verbatim without re-resolving and without validating that the directory still exists —
  a pin pointing at a detached worktree must come back as a pin the human can see and
  clear, not silently revert to automatic.
- **Wiring on restore:** call `SurfacePool.pinProjectRoot(url, for: slotID)` for each
  restored pane that has one. That method already re-resolves and publishes
  `pane.cwd-changed` only when the anchor actually moved, so restoring is a normal update
  and needs no special case.
- **Do not persist the cwd.** It is shell state; the pane re-seeds from its workspace path
  and the first OSC 7 corrects it. Persisting it would restore a directory no live shell
  is in.
- [x] Both directories are visible in the pane header menu: `Current Directory: …` and
      `Project Directory (AUTO|PINNED): …`. NOT the status bar — `WorkspaceStatusBar` is
      documented as carrying only plugin `tenon.statusBar` contributions ("the shell adds
      nothing of its own"), and native pane state there would break that rule
- [x] `swift build` exit 0; `swift test` **653/653, 0 failures** (30 of them new). No
      pre-existing reds inherited and none left — the ~3 T-021 provenance/consent reds other
      tasks reported are green in this tree now
- [ ] Live check (`cd` a pane into a real worktree, watch Files + Git follow) — **STILL
      OWED, human-verify-only.** The publisher is now wired end to end (surface → pool →
      host → plugins) and `swift build`/`swift test` are green over it, but I could not
      drive the real GUI: another session's app instance was live (pid 84500, 31 min
      uptime) and Tenon is a true singleton, so my second instance exits silently — and
      killing another agent's app is not mine to do. Everything headlessly assertable about
      this path IS asserted (30 tests); what remains is a pair of human eyes on the panels
