# T-061: Create automation with AI — a pane-based pair-authoring flow
> Settings ▸ Automation gains "Create with AI…": one click opens a fresh terminal tab
> running `claude` seeded with a host-authored guide prompt (the exact single-file
> manifest format, schedule syntax, `automation.fired` contract, the REAL plugins-root
> path, and how to verify via Run Now) so the agent pair-writes the automation with the
> user and hot reload does the rest. User-directed design (01:51): "bấm nút create
> agent → mở tab, chạy sẵn claude code, submit luôn prompt hướng dẫn; AI tương tác qua
> tenon cli."
- **priority**: medium
- **effort**: M

## Owner / files (agent lock)
**RELEASED 02:0x — task done, every file below is FREE.** (Was: session 1d3e1340,
user-directed; third Doing entry past the WIP pair, T-059/T-060 precedent — zero
overlap with T-055 and T-059 locks.) Claimed while active:
- Sources/TenonApp/AutomationAuthoring.swift (NEW)
- Sources/TenonApp/SettingsView.swift
- Sources/TenonApp/TenonApp.swift (wiring only)
- Tests/TenonAppStateTests/AutomationAuthoringTests.swift (NEW)
- docs/design-automations.md (one new section)

## Rung walk (recorded before code)
- **Button → pane**: a built-in host-UI gesture composing the SAME typed services
  `terminal.open.v1`'s provider adapts — `WorkspaceStore.newTab`,
  `catalog.activeSlotID`, `SurfacePool.seedSpawnDirectory`, `sendTextWhenReady`
  (TerminalIntentProvider.swift:224-237). Same-owner DIRECT (invariant 6); the intent
  stays the public adapter over the same one implementation, so no second path exists.
  Not an INTENT from the UI: built-in app UI has no generic app intent principal
  (invariant 8).
- **Guide prompt**: host-owned static content parameterized by a host-known path
  (`PluginHost.pluginsRoot`, already public). Nothing crosses the plugin boundary;
  zero new `tenon` members; no new capability — the agent in the pane holds only what
  any shell in a pane holds, and the automation it writes earns authority the ordinary
  way (manifest declaration + consent at first privileged firing).
- **The agent's side**: everything it is told to use already exists publicly —
  the plugins-root directory (T-047 single-file discovery + hot reload), `tenon-cli
  intent list/describe/send`, and T-060's Run Now / history for verification.

## Decisions
- The prompt and the command builder live in ONE pure type (`AutomationAuthoring`),
  testable headless in TenonAppStateTests: the rules worth pinning are "the real
  plugins-root path is embedded verbatim", "the header opener is taught exactly",
  and "the whole prompt crosses the shell as ONE POSIX-quoted argument".
- POSIX quoting is written here as a small pure function because no Swift-side quoting
  helper exists (grepped; `agents.run`'s quoting is JS inside the plugin runtime — a
  different runtime, not a reusable implementation).
- Working directory of the pane = the plugins root, so the agent's relative writes land
  where discovery watches.
- Choosing to create closes the Settings window (user-directed 02:12): the button's
  whole outcome is the pane, and Settings sits exactly on top of it. The action
  composes then calls `dismissWindow`, so focus lands on the pair-authoring pane.
- Prompt is English (repo docs convention); it instructs the agent to interview the
  user FIRST, write the smallest correct script, and warn about the consent prompt on
  the first privileged firing.

## Criteria
- [x] `AutomationAuthoring.prompt(pluginsRoot:)` embeds the real path verbatim and
      teaches: the `/* tenon-manifest` header-must-open-the-file rule, schedule syntax
      (`every` ≥ 1m / `daily` "HH:mm"), the `automation.fired` payload including
      `trigger`, `tenon-cli intent list/describe`, and the Run Now verification loop —
      pinned headless (`testPromptEmbedsTheRealPluginsRootAndTeachesTheContract`,
      8 named assertions).
- [x] `AutomationAuthoring.command(pluginsRoot:)` delivers `claude` plus the whole
      prompt as one POSIX-quoted argument; quoting neutralizes single quotes and
      command substitution — pinned headless with a hostile fixture
      (`$(rm -rf /) \`id\` "x" \\n`, plus a plugins root containing a space).
- [x] Settings ▸ Automation shows "Create with AI…" in both the populated and the
      empty state (one Section rendered before the branch, so both states carry it);
      the click opens a fresh terminal tab seeded with the plugins-root working
      directory and the command — `AppComposition.openAutomationAuthoringPane()`
      composes exactly the calls `terminal.open.v1`'s provider makes
      (`newTab` → `activeSlotID` → `seedSpawnDirectory` → `sendTextWhenReady`).
- [x] Zero new `tenon` members; surface/global pins untouched — pin tests ran in the
      green full suite.
- [x] Full `swift test` green — **956 / 0**, exit 0 (was 946 at T-060; +3 mine, the
      rest peers landing in parallel).

## Evidence (session 1d3e1340, 01:5x–02:0x)
- RED first: 3 tests, **12 assertion failures, 0 unexpected** against inert stubs;
  tree kept compiling.
- GREEN: 3/3 filtered; full suite **956 / 0**; `swift build` exit 0
  (warnings-as-errors).
- **3 mutation proofs, each RED on its named assertion, restores `cmp`-verified
  byte-identical**: M1 command drops quoting, M2 quoting drops the escape, M3 prompt
  hardcodes a guessed path instead of the real root. FINAL sanity rerun exit 0.
- Launch smoke: debug binary alive 8 s, log empty (no live instance existed, checked
  first).
- Docs in-change: `docs/design-automations.md` § "Creating one with an agent (T-061)".
- Human-verify remaining: press the button — Settings closes, the pair-authoring pane
  has focus, claude receives the guide as its prompt, and a real pair-authoring
  session produces a working script. Follow-up candidate recorded, not built: a CLI
  verb for "did my plugin load / what failed" so the agent can self-check without
  asking the user to read Settings.
