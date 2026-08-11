# T-122: The test that only knew half the naming rule

> `testClaudeHookBindingMatchesAProviderChildInTheSameProcessGroup` passed on every
> developer machine and failed on every CI run. The product code was right the whole time;
> the test built its fixture directory with a naming rule it had reinvented and got wrong.

- **priority**: critical
- **effort**: S
- **prd**: TENON-PRD-015 (ENQ-FR-017 flake control, ENQ-NFR-012 reproducibility)

## What was actually wrong

Claude Code stores a session under `~/.claude/projects/<slug>`, where the slug is the
workspace path with **every non-alphanumeric character** replaced by `-`.
`AgentLensDiscovery.claudeProjectSlug` implements that. The two tests built the same
directory with `path.replacingOccurrences(of: "/", with: "-")`, which only replaces the
slash.

The two rules agree for a path made of letters, digits and slashes, and disagree the moment
one contains anything else:

| | |
|---|---|
| runner `TMPDIR` | `/var/folders/**_5**/zjnzxgh…/T/` |
| test built | `-var-folders-**_5**-zjnzxgh…-workspace` |
| product looked in | `-var-folders-**-5**-zjnzxgh…-workspace` |
| this machine's `TMPDIR` | `/var/folders/**gv**/3wrq6lbs…/T/` — agrees by luck |

So the fixture transcript sat in a directory the resolver never looked in,
`declared(_:under:)` returned nil, and `resolve` fell to `.processOnly` with no transcript —
exactly what CI reported three times.

The product rule is the correct one, confirmed against the real store on this machine:
`~/.claude/projects` contains `-Users-firegroup--claude` for `/Users/firegroup/.claude`,
so Claude replaces `.` as well, not just `/`.

## Why it stayed invisible

`testClaudeWithoutHookDoesNotAttachAnotherTranscriptFromSameDirectory` has the same bug and
was **green on CI** — it asserts that nothing gets attached, and a fixture in a directory
nobody reads produces that outcome for the wrong reason. One of the pair failed loudly and
the other passed vacuously.

## The fix

- `claudeProjectSlug` stops being private, so a test uses the rule instead of restating it.
  One rule, one implementation — a second copy is what failed here.
- Both fixtures now sit under a directory named `tenon_claude.<kind>-<uuid>`, carrying an
  underscore and a dot on purpose. The two rules disagree about both, so this failure can no
  longer depend on whether a machine's temporary directory happens to be alphanumeric: it is
  now red everywhere or green everywhere.

## Criteria

- [x] Both tests use `AgentLensDiscovery.claudeProjectSlug` rather than their own rule
- [x] Fixture paths contain characters the rules disagree on, so the case is covered locally
- [x] Reverting the slug call turns them red **on this machine** (mutation check)
- [ ] The CI run for this commit passes the headless suite

## Evidence

The mutation is the receipt, because it reproduces a CI-only failure on a developer
machine — which is the thing that could not be done for three red runs. With the old
home-made rule restored and the new fixture names in place:

```
testClaudeHookBindingMatchesAProviderChildInTheSameProcessGroup   FAILED  (3.222s)
testClaudeWithoutHookDoesNotAttachAnotherTranscriptFromSameDirectory   passed
```

Restored, both pass. So the fixture names now carry the failure rather than the runner's
temporary directory carrying it.

The second line is worth keeping in view: that test **passed under the mutation too**. It
asserts an absence, and a fixture written where nothing reads it produces that absence. It
is correct now only because it builds its directory with the real rule — not because its
assertion would notice if it stopped. Anything later that re-derives the slug would be
caught by the first test and waved through by the second.

## What this cost, and what would have caught it sooner

Three CI runs produced the same message — `nil is not equal to <url>` — and no information,
because one assertion covered two different failures. The bisecting assertions added in
`b0ef49b` named the half that broke on the first run afterwards. A test that fails without
saying where is nearly as expensive as no test.

## Owner / files (agent lock)

Session `b67a9a60` — claimed 2026-08-11 09:4x.

- `Sources/TenonApp/AgentLensSources.swift`
- `Tests/TenonAppStateTests/AgentLensTests.swift`
