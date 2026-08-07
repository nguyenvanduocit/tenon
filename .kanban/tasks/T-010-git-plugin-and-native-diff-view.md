# T-010: Git plugin (kero parity) + host native default diff view
> Rewrite the git plugin to kero-level capability and add a host-owned, reusable, native diff view that plugins open into a new tab/pane. Enables "click a changed file → diff opens in its own tab", not carved inline.

- **priority**: high
- **effort**: L

## Owner / files (agent lock)
Session c2fc4dd9 (main).

**Part A — DONE + verified (new files only, NO collision):**
- Sources/TenonCore/LineDiff.swift (NEW — pure Myers line-diff engine) ✓ 14 tests green
- Sources/TenonCore/DiffRequest.swift (NEW — DiffRequest/DiffSource value) ✓ 6 tests green
- Sources/TenonApp/DiffSlotView.swift (NEW — native SwiftUI diff renderer; unified+split, off-main git resolve, generation guard) ✓ compiled clean
- plugins/git/main.js + manifest.json (MY plugin — full rewrite to kero parity) ✓ node syntax OK; existing testGitPluginReportsBranchOfARealRepository stays compatible (⎇ branch ±n)
- Tests/TenonCoreTests/LineDiffTests.swift + DiffRequestTests.swift (NEW test files) ✓

**REALIGNED — align to the peer's existing content mechanism, do NOT invent a parallel API:**
A live peer already shipped `tenon.workspace.newTab({type})` → `WorkspaceCommand.openTab(SlotContent)`
→ `store.newTab(content:)`, with `parseContentSpec(_:)` (PluginRuntime ~745) mapping
`{type: terminal|files|changes|docs|browser|plugin, plugin?, viewID?}` → SlotContent. The diff view
plugs into THIS, not a new `tenon.diff.*`. So `tenon.diff.open`/`tenon.views.open`/`SlotPlacement`
are dropped; the git plugin calls `tenon.workspace.newTab({type:"diff", ...})`.

**Part B — SHARED, land in ONE coordinated window with the owning session(s) (peers are LIVE):**
- Sources/TenonCore/Workspace.swift: `SlotContent += case diff(DiffRequest)` — not claimed, but the added case breaks every exhaustive `SlotContent` switch a peer is mid-editing.
- Sources/TenonCore/PluginRuntime.swift `parseContentSpec(_:)` (~745): add a `"diff"` branch → read `{repoPath, path, staged, untracked, origPath, title}` → `DiffRequest(source: .git(...))` → `.diff(req)`; add `"diff"` to the two `newTab`/`setContent` error strings. ⚠️ T-005/537832b5 actively edits this exact region.
- Sources/TenonApp/BuiltInSlotViews.swift: `.diff(let req): DiffSlotView(request: req)` in `BuiltInSlotContentView.body`; `SlotPresentation.title` → req.title; `.glyph` → "±". ⚠️ T-005 + T-008 claim this file.

## API contract (realigned, frozen)
```js
// Git plugin opens a file's diff via the host content mechanism — a new tab:
tenon.workspace.newTab({ type:"diff", repoPath, path, staged:false, untracked:false, origPath:null, title });
```
Gated by `workspace.control` (already declared in git/manifest.json). The diff render is free tier
(Inv #5). No private API — the git plugin adds "diff" as a public SlotContent type any plugin can open (Inv #6).

## Criteria
- [x] Pure `LineDiff` engine (Myers) + hunks/stat, asserted in TenonCoreTests without a window — 14 tests
- [x] `DiffRequest`/`DiffSource` pure values + Equatable tests — 3 tests
- [x] Native `DiffSlotView` renders unified + split, colored gutters, skeleton, per-hunk (high perf), off-main git resolve with generation guard (native — no WebView)
- [x] git plugin: status (staged/changed/conflict/branch/ahead-behind), stage/unstage/discard, commit/commit-all, push/pull/fetch, stash/pop, create branch — all via tenon.process.exec + git; existing `testGitPluginReportsBranchOfARealRepository` passes (fixed a self-introduced repo-resolution race)
- [x] Clicking a changed file opens its diff via `tenon.workspace.newTab({type:"diff"})` in a NEW tab
- [x] `newTab({type:"diff"})` blocked without workspace.control, allowed with it; missing path rejected (DiffContentCapabilityTests — 4)
- [x] `SlotContent.diff` + `parseContentSpec` "diff" branch + `BuiltInSlotViews` `.diff`→`DiffSlotView` + all SlotContent switch sites (RecentStore/EmptyStateCard) updated
- [x] swift build clean, swift test green — **296/296, 0 failures**

## Status: DONE + verified (headless). Landed Part B after T-006/4564041c released parseContentSpec/SlotContent (board ack) + user approval. Not committed. One thing not machine-checked (repo convention: SwiftUI views carry no unit-testable rules): the actual pixels of DiffSlotView — smoke via `swift run tenon-poc`, open the git panel into a pane, click a file.
