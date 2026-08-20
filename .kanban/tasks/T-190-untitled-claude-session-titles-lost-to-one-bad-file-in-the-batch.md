# T-190: "Untitled Claude session" losing titles to array-format content and single-file batch failures
> Two confirmed bugs in Claude-session title derivation compound to blank out the Agent Sessions list
- **priority**: high
- **effort**: S

**CLAIMED by session `b3c62321` 2026-08-19 16:5x. Operator-reported, root-caused live against real `~/.claude/projects/*.jsonl` transcripts this session; operator explicitly asked for the fix.**

Root cause (both verified by extracting the `awk` program from `ClaudeSessionsScan.swift:65-73` to a
standalone `.awk` file and running it against real transcripts):

1. `ClaudeSessionsScan.swift:72` (`jsonString`) fallback title extraction only matches
   `"content":"..."` (plain string). Claude Code stores `content` as an array whenever the message
   includes an image (`"content":[{"type":"text","text":"..."}]`) — very common for this user, who
   routinely pastes screenshots. The literal `"content":"` marker never matches, so the fallback
   silently returns "". Verified on `1fb5645d-92c0-49db-91f6-4983a6b1cb11.jsonl` (first message is
   `[Image #1] đây không biết...`, array content): extracted `first` field is empty.
2. `ClaudeSessionsScan.swift:395-441` (`enrichClaude`) batches up to 25 session paths into ONE `awk`
   process. If that single process exits non-zero for any reason, `guard result.ok, result.status ==
   0 else { ...; continue }` (line 414) discards title enrichment for the WHOLE batch, not just the
   file that caused the failure — one bad/slow file blanks titles for every other session in that
   refresh. (A related but *not* currently live risk: `/usr/bin/awk` fatally crashes — `towc:
   multibyte conversion failure` — on invalid-UTF8 bytes unless run under `LC_ALL=C`; the code already
   forces that via `/usr/bin/env LC_ALL=C`, confirmed safe against all 146 local transcripts.)

Together: a freshly-started session (no `ai-title` yet — Claude Code generates that asynchronously
after a few turns) whose first message has an image falls through both title sources and renders the
literal `"Untitled Claude session"` fallback in `ClaudeSessionsPlugin.swift:518-525`. A burst of such
sessions (or one bad file in a batch) blanks many rows at once, matching the reported screenshot.

Files held: `Sources/TenonBundledPlugins/ClaudeSessionsScan.swift`, its test file (new or extended).
None held by any other Doing task.

**Shipped 2026-08-19.** `ClaudeSessionsScanTests.swift` (new) proves both fixes: a real
`/usr/bin/env LC_ALL=C /usr/bin/awk` subprocess against a fixture transcript for the array-content
fallback, and a fake `ClaudeSessionsIntentCaller` that fails a whole-batch `process.exec.v1` call
and asserts the healthy file's title survives via per-file retry. Both red before the fix, green
after. `enrichClaude` split into `runAwkDetails`/`failureReason`/`apply` so the retry path reuses
the same exec+parse logic instead of duplicating it. Full suite **2395/0** (one flaky failure on a
first run reproduced clean on immediate rerun — unrelated to this change, another agent's
concurrent edits are live on this shared tree). `xcodegen generate` run so `Tenon.xcodeproj` picks
up the new test file (4-line pbxproj diff, file-reference only).

## Criteria
- [x] Failing test added first, reproducing the array-content fallback miss
- [x] Failing test added first, reproducing single-bad-file-blanks-the-batch
- [x] `awk` fallback also tries the first `"text":"` value when `"content":"` doesn't match
- [x] `enrichClaude` isolates a batch failure to per-file retry instead of discarding the whole batch
- [x] `swift test` green, no regressions
