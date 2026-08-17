# T-173: A collapsed rail still says which workspace you are in
> With the sidebar collapsed the workspace name disappears entirely — the title bar's identity zone spends its ~90 pt on the wordmark instead.

- **priority**: medium
- **effort**: S
- **PRD**: `TENON-PRD-001` [`workspace-shell`](../../docs/prds/workspace-shell.prd.md) — extends `WS-FR-002`

## Owner / files (agent lock)
Released 2026-08-17 by session `7ae26fb6`. Files touched, all uncommitted in the shared tree:
`ShellIdentityLabel.swift`, `TitleBarSnapshot.swift`, `ShellIdentityLabelTests.swift` (new);
`ShellTitleBar.swift` (identity zone only), `TenonApp.swift`, `CLAUDE.md`,
`workspace-shell.prd.md`/`.feature`, `project.pbxproj`.

Overlap note: T-144 lists `ShellTitleBar.swift` from 2026-08-13 and T-152 waits on that
release, but the file was not dirty in the working tree and T-144 reports its reorder work
shipped. This change stayed inside the identity zone, which neither task's description reaches;
the tab strip, reorder rules, and `TabStripSurface` are untouched and `TabStripReorderTests`
is 19 / 0 after it.

## Why
Collapsed, the 48 pt rail draws marks only — a workspace's name survives just in the row's
tooltip (`WorkspaceSidebarView.swift:343`, `:403`). Meanwhile the title bar's left zone keeps
its full 232 pt (`ShellTitleBar.swift:328`, `TenonTheme.sidebarWidth`) and spends the ~90 pt
left after the traffic-light inset on the word "Tenon" — which the menu bar and the Dock
already say. The operator photographed exactly that state and asked for the workspace name
there instead.

## What shipped
`ShellIdentityLabel.resolve(sidebarVisible:workspaceName:)` is the whole rule and it returns
both answers the view needs: the text, and whether that text is a workspace's name. The view
reads the second one to decide how the label behaves under pressure — a name is content, so it
truncates at the tail and keeps its tooltip; the wordmark is chrome, so `fixedSize` lets
`ViewThatFits` see it stop fitting and drop it whole, exactly as before.

`TENON_TITLEBAR_SNAPSHOT` is new and mounts the shipping `ShellTitleBar` over a real store and
host, because a passing test says nothing about whether a truncated name crowds the sidebar
toggle. Three pictures taken: collapsed reads `tenon`, expanded reads `Tenon`, and
`interviewassistant-monorepo` reads `intervie…` with the toggle and divider untouched.

## Criteria
- [x] `ShellIdentityLabel` is a pure rule, asserted without a window: collapsed + a named
      workspace reads the workspace name; expanded reads "Tenon"; a blank or absent name
      falls back to "Tenon" in both states.
- [x] The collapsed label truncates at the tail instead of vanishing, carries the full name
      in its tooltip and its accessibility label, and stays one line.
- [x] Expanded behaviour is unchanged, including `ViewThatFits` dropping the wordmark at the
      minimum sidebar width.
- [x] `WS-FR-034` added to the PRD with a scenario in `workspace-shell.feature`, tagged
      `@req-ws-fr-034`.
- [x] Red first at the new assertions, then green; full `swift test` green; `xcodegen generate`
      adds the three new files and nothing else.

## Evidence
- Red first: `("Tenon", false)` against `("tenon", true)` and against `("spaced workspace",
  true)`, from a stub that answered the wordmark for every input. Green after the rule landed.
- Full suite **2280 / 0**, exit 0, 140.8 s. An earlier run of the same tree reported 2
  failures while `CLAUDE.md` was being edited underneath it — `DomainTagFitnessTests` and
  `ScriptSurfaceFitnessTests` both read that file — and the rerun over a quiet tree is clean.
- Focused rerun after the `// MARK: - The identity zone` split: `DomainTagFitnessTests`,
  `ScriptSurfaceFitnessTests`, `ShellIdentityLabelTests`, `TabStripReorderTests` — **31 / 0**.
- Pixels, through the new `TENON_TITLEBAR_SNAPSHOT` (900 × 36, dark):
  `tb-collapsed.png` reads `tenon`, `tb-expanded.png` reads `Tenon`, `tb-long.png` reads
  `intervie…` for `interviewassistant-monorepo` with the toggle and divider clear.
- `xcodegen generate` → 12 added lines in `project.pbxproj`, all three new files, nothing else.

## Left open
The zone is ~90 pt wide after the traffic-light inset, so a name past roughly nine characters
is read from the tooltip rather than the bar. Widening it means moving the collapsed row's
232 pt divider, which is the tab strip's left edge — T-152's territory, not this task's.
