# T-013: Claude Code sessions plugin
> A `claude-sessions` plugin that scans the Claude Code sessions recorded for the current project directory and resumes one in the terminal.

- **priority**: high
- **effort**: M

## Design
- Sessions live at `<claudeHome>/projects/<slug>/<uuid>.jsonl`, where `slug` is the
  project path with every non-alphanumeric character replaced by `-`.
- Project directory: `projectPath` setting when set, else the active workspace's `path`
  (free-tier `tenon.workspace.get()`), re-resolved on `workspace.selected`/`changed`.
- Two `process.exec` passes, so only the sessions actually shown are read:
  1. `stat` over `*.jsonl` → id + mtime + size, sorted newest first, truncated to `limit`;
  2. `awk` over just those files → ai-title (last one wins), first user prompt, message
     counts, git branch — one pass per file, long lines skipped.
- Click a session → `tenon.terminal.write("claude --resume <id>\n")`.

## Criteria
- [x] `claude-sessions` loads with zero permission violations
- [x] Sessions of a fake project dir are listed newest-first with title, message count, branch
- [x] Resuming writes `claude --resume <id>` to the terminal
- [x] A directory with no sessions renders an empty state, never an error
- [x] `swift test` green

## Outcome
`swift test` 308/308 green, `swift build` clean. Files: `plugins/claude-sessions/{manifest.json,main.js}`,
`Tests/TenonCoreTests/ShippedPluginsTests.swift`.

The one non-obvious finding: BSD `awk` in a UTF-8 locale aborts the entire run on the first byte it cannot
decode (`towc: multibyte conversion failure`). Real transcripts carry pasted images and binary tool output, so
the fixture-based test passed while every real session came back unnamed. Scanning runs through
`/usr/bin/env LC_ALL=C /usr/bin/awk` (byte mode, ~2x faster: 47 MB / 25 files in 2.7s vs the 10s exec timeout),
and the regression test splices invalid UTF-8 ahead of the last `ai-title` record.
