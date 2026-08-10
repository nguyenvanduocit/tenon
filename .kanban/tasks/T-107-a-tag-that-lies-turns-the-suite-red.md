# T-107: A tag that lies turns the suite red
> The five existing assertions check a tag's *shape*. None of them can tell that a file is
> labelled with a concern it has nothing to do with — the failure T-106 found by hand, three
> times. This adds the check that reads the code, and closes the MARK rule's blind spot.

- **priority**: medium
- **effort**: M

## Owner / files (agent lock)

Released 2026-08-10 15:3x by session `36faa18c`. No files are held.

## Why

T-106 measured the layer and found the vocabulary sound but three tags false:
`EmptyStateCard` labelled `agent-lens` with no `agent-lens` caller, `AppStatePaths` labelled
`diagnostics` while recording no health, `AgentLaunchSuggestions` labelled `agent-lens` while
holding the launch arguments `agent-control` is defined as. Every one was found by a human
reading `docs/domains.md` against the file. The suite was green the whole time, because all
five assertions ask about form — is the domain declared, is it a slug, does every declared
domain appear somewhere — and none of them opens the file.

A tag that lies is worse than a missing tag: a missing tag sends a reader to grep, a lying
tag sends them somewhere confidently wrong, and every measurement in T-106 assumed the tags
were true.

**The check.** A file is *isolated* when its own domain appears in no file it references and
no file that references it, in either direction. Two-way is what makes it usable: the
one-way version flags 16 files, mostly composition roots whose neighbours are legitimately
everywhere (`TenonApp.swift`, `AppIntentRuntime.swift`); the two-way version flags 8, and
would have flagged `AppStatePaths` before today's fix. Files whose every domain covers a
single file are skipped — a one-file domain cannot have a same-domain neighbour, so its
isolation is arithmetic rather than evidence.

It is a smell, not a proof: `ShellStrings` and `ProjectRoot` are leaf utilities that
genuinely touch nothing in their domain, and `EmptyStateCard` is isolated because it is a
*second* launcher implementation that shares no code with `LauncherMenu` — a real finding
about the code, not the tag. So it ships as a ratchet with today's count, the way
`untaggedFileBudget` did from 154 down to 0.

**The blind spot.** `testLongTaggedFilesTagEveryMarkSection` only constrains files that have
MARK sections. 49 of the 65 files over 400 lines have none — 41,879 lines, over half the
tree, including its five longest — so the assertion passes on them without reading anything.
A second ratchet holds that count where it is.

## What the check turned out to reach

Honest result, recorded because the first draft of this task overstated it: the isolation
rule catches **one** of the three false tags, `AppStatePaths` claiming `diagnostics`.
`EmptyStateCard` and `AgentLaunchSuggestions` both shared code with the `agent-lens` files
they wrongly claimed, and no structural rule can see past that — a file can be thoroughly
coupled to a domain it has no business being labelled with.

Building it did find a real defect in the rule itself. An early draft indexed `extension`
declarations as type owners, so the `extension Task` in `AgentLensMarkdown.swift` made every
file that writes `Task { }` a neighbour of `agent-lens` — a false edge that hid
`AgentLaunchSuggestions`' wrong tag even from the one-way version. Ownership is now top-level
`struct`/`enum`/`class`/`actor`/`protocol` only: a nested `enum State` is not what its file
is about, and an extension declares no type at all.

## Criteria

- [x] `AgentLaunchSuggestions` carries `agent-control`, the domain defined as "which options
      this person actually runs them with"; `agent-control` now covers 3 files, `agent-lens`
      17.
- [x] The isolation assertion goes red on demand: with the budget set to 0 it names all 8
      files (`AutomationAuthoring`, `EmptyStateCard`, `FilePaneKind`, `FilePreviewSlotViews`,
      `PaneAttentionNotifier`, `ProjectRoot`, `SettingsView`, `ShellStrings`), matching the
      independent Python count exactly. Restored to 8, it passes in 0.55 s.
- [x] `unsectionedLongFileBudget` holds the 49 long files with no MARK, and both CLAUDE.md
      and `docs/domains.md` say plainly that a green run there checks nothing on 41,879 lines.
- [x] `docs/domains.md` has a "What the tests can and cannot settle" section separating the
      five shape checks from the two code checks, and states the 1-of-3 reach.
- [x] `CLAUDE.md` puts step 1 at the moment of use ("before you grep a symbol name") with the
      adoption and yield numbers that make it worth running and worth not trusting.
- [x] `swift test` green: **1844 tests, 0 failures** (2026-08-10 15:37), `DomainTagFitnessTests` 7/7.

## One thing this leaves standing

`SettingsView.swift` is tagged `plugin-settings`, whose Excludes line says in as many words:
"the settings *window* and its SwiftUI surface". The tag contradicts its own domain entry and
no domain in the vocabulary covers a settings window. Left alone deliberately — resolving it
means either a new domain or an amended Excludes, which is a product decision, and T-106
measured that adding domains costs recall. It sits in the isolation budget as a standing
reminder rather than being quietly re-tagged.
