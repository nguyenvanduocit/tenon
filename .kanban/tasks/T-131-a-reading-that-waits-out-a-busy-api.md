# T-131: A reading that waits out a busy API instead of blaming itself
> The CLI announces every retryable API error and then goes quiet for its own backoff. The host
> threw the announcement away and killed the run at 45 s of "silence", so a reading succeeded or
> failed on API weather and said the wrong thing about why.

- **priority**: high
- **effort**: S
- **prd**: `TENON-PRD-012` (`docs/prds/agent-lens.prd.md`) — `AL-FR-031`, `AL-FR-038`

## Owner / files (agent lock)
Session `9fe92d11`, claimed 2026-08-11 16:4x. **Released on completion.**

- `Sources/TenonApp/AgentTimelineSynthesis.swift`
- `Tests/TenonAppStateTests/AgentCLIRetryTests.swift` (new)

`AgentTimelineSynthesis.swift` is named by T-123, whose session died at 10:43 without releasing
it; the user authorised clearing those locks at 16:0x. This task touches the stream reader, the
progress vocabulary and the watchdog — not the options plumbing T-123 left unfinished.

## What the user saw

A pane reading "**No reading was produced — The reading stopped responding after 45s of
silence**", with Try again, on a run that was working the whole time.

## The measurement

A full 320-fact / 91 KB digest streams its first bytes in **1.4–3.0 s** and finishes in
**20–21 s**, with a largest inter-chunk gap of **3.0 s**. Prompt size is not the cause and the
deadline is not too tight for a healthy run.

Against a loaded endpoint the same arguments produce stdout gaps of **50.41 s and 46.26 s** —
both past `silenceSeconds = 45`. Even against a fast-failing endpoint the CLI's backoff reaches
a **39.28 s** gap, leaving 5.7 s of margin. The CLI is not hung during those gaps; it is waiting
out a backoff it already announced.

It announces them on stdout. From the installed CLI's own strings (2.1.227): *"@internal
Retryable-API-error frame carrying the plain-data error snapshot and retry counters. REPL
renders the retry banner from this. **Wire twin is SDKAPIRetryMessage (`'api_retry'`)**. From
internal SystemMessage 'api_error'."* `"api_retry"`, `"error_status"` and `"attempt"` are all
present in that binary. The measured frame carried `error_status: 529, error: "overloaded"`.

`AgentCLIStreamReader.claude` matched `system` only where `subtype == "init"` and returned
`.ignored` for everything else, so the announcement was dropped — and then the host reported the
quiet it had just been given the reason for.

## The rule

T-111 replaced a duration deadline with a silence one on the argument that **a reading still
writing is alive by observation**. This extends the same argument rather than weakening it: a
run that announced a backoff is alive by observation too — it said so — and the quiet that
follows is the backoff it named. An announced retry therefore *explains* the silence, and the
**absolute ceiling stays the only bound** on a run that never speaks again.

The explanation is a **deadline, not an amnesty**, and the host does not have to guess where it
falls: the CLI states the wait. Its own construction site, read out of the installed 2.1.227,
is `subtype:"api_retry", attempt:…retryAttempt, max_retries:…maxRetries,
retry_delay_ms:…retryInMs, error_status:…error.status ?? null, error:…`. A run gets the delay it
asked for plus the ordinary silence budget to say something once the wait is over; a run that
misses its own restart is exactly the kind worth stopping.

Only a retry that states no delay is excused outright, and then the absolute ceiling is left in
charge. That is the weaker answer and it is reached only when the CLI declines to say.

## Criteria
- [x] `api_retry` is read as its own reading rather than as framing, with the counters optional
      and the subtype load-bearing.
- [x] `init` keeps its meaning and an unknown `system` subtype stays framing, so a future
      subtype cannot silently become a retry.
- [x] The pane says "The API is busy — retrying (attempt N)" while it waits.
- [x] An announced retry excuses the silence for exactly as long as the CLI said it would wait,
      plus the ordinary silence budget — `testAPromisedDelayRunsOutInsteadOfExcusingSilenceForever`.
- [x] A retry that states no delay is excused until the ceiling, and the test pins
      `ceilingSeconds > silenceSeconds` so the ceiling stays the longer bound.
- [x] `AgentRunActivity` is assertable on its own rather than private inside the synthesizer.
- [ ] Confirmed against a genuinely overloaded endpoint. Not reproducible on demand; the
      measurement above stands, and the classification is pinned against recorded line shapes.

## Found and fixed on the way

`AgentCLIStreamReader.read(line:provider:)` routed **`.codex` to the Claude reader**
(`case .codex: return claude(record)`), leaving the whole `codex(_:)` reader unreachable. A
Codex reading would have misparsed every line: `thread.started` never became `.connected`, and
`item.completed` — the one frame carrying the reply — was framing. Latent rather than live,
because `AgentReadingOptions` defaults to `.claude` and T-123 never shipped a way to choose
otherwise, so nothing has asked for a Codex reading yet. One word.

Note left standing: `silenceSeconds(for:)` ignores its `provider` argument and its doc comment
says Codex "has no such signal, so the same rule would kill healthy runs — the ceiling is the
only honest bound there". The code and the comment disagree. Fixing it belongs with whoever
finishes T-123's provider choice, since until then no Codex run can be started.

## Corrected after the fact, in the same session

The first implementation excused an announced retry **indefinitely**, on the argument that a
backoff's length is the CLI's business and a host guessing at it would be inventing numbers
again. A background `strings` search over the CLI binary finished after that shipped and
falsified the argument outright: the frame carries **`retry_delay_ms`**. The host was never
guessing — it was ignoring an answer it had been handed. `AgentRunActivity.explain()` became
`explain(forSeconds:)` and the excuse now expires. Nine assertions, 0 failures.
