# T-070: A URL in backticks is still a URL

> The same address renders live in one sentence and dead in the next: bare
> `https://tenon.dev` autolinks, but wrapped in backticks it is inert text — while a file
> path in backticks now opens its pane (T-068).

- **priority**: medium
- **effort**: XS

## Owner / files (agent lock)

**Released 2026-08-06 14:3x by session `cbf0f2c6`. Both files are FREE.**
`AgentLensView.swift` was never claimed — T-069 has it.

## Mechanism

No boundary moves. A code span that names an absolute `http(s)` address takes a `.link`
attribute, exactly as the autolinker already gives a bare one. The click keeps the
behaviour every other web link in Agent Lens has: `OpenURLAction` returns `.systemAction`
and the address opens where the person's links already open.

## Criteria

- [x] `` `https://tenon.dev/docs` `` renders as a link to that address — asserted equal to
      what the bare form already produced.
- [x] A code span that is not an absolute `http(s)` address stays plain text — commands,
      flags, `ftp://`, `tenon.dev` with no scheme, and a bare `https://` with no host.
- [x] A file path in backticks still wins as a file link, and a bare URL still autolinks.

## Evidence

`AgentLensFileLinkTests` + `AgentLensMarkdownTests`: **38 tests, 0 failures.**

Measured before writing anything, which is what scoped the task: a bare
`https://tenon.dev/docs`, an `<autolink>`, a `[written](link)`, and even `hi@tenon.dev`
already carried links through `AttributedString(markdown:)`. Only the code span went dead,
and only because T-068 had just made the backticked *path* live — so the gap was newly
visible, not newly created.
