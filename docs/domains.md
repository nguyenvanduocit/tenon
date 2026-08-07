# Domain tags

The controlled vocabulary for `@domain:` tags, and the only place a domain may be declared.

A domain names a **product concept**: the thing a person would say they are working on. It is
deliberately not a code fact. Call graphs, imports, and type references already say who calls
whom, and a compiler keeps them honest; nothing in the source says which product concern a
file serves. That judgement is the layer this file adds, and the reason it is written by hand.

Two measurements set the shape. `rg '^import ' Sources/TenonCore` names only *external*
modules — Swift gives files in one module free visibility, so 155 source files expose exactly
one inter-module edge and intra-module structure is textually invisible. And unchecked
metadata rots: 31 of ~35 populated `## Owner / files` blocks in `.kanban/` were stale against
2 tasks actually in `Doing`, ~89%, with the obligation stated plainly in CLAUDE.md the whole
time. So this vocabulary ships with `DomainTagFitnessTests` enforcing it. A tag layer nothing
checks is a tag layer that lies within weeks.

## How to tag

Every source file under `poc/Sources/` carries one file tag, on its own line, above the imports:

```swift
// @domain: plugin-host, plugin-events
```

A file longer than **400 lines** additionally tags every `// MARK:` section, on the MARK line:

```swift
// MARK: - Loading and hot reload  @domain: plugin-host
```

`// MARK:` is Swift's own sectioning convention and — unlike "a block" — it is *enumerable*,
which is the only reason a block-level tag can be checked at all. The tag rides on the MARK
line rather than below it so one `rg` result carries both the section name and its domain.

Prefer the fewest domains that are true. **A file tagged with more than two domains is a split
candidate**, not a well-labelled file: the tag boundaries are the decomposition the file has
not had yet. `PluginHost.swift` carries five today and is the standing example.

## What tags are for, and what they are not for

A tag gives a **better starting set** than a bare keyword grep. It does not certify
completeness, and no check can. Nothing detects that a file tagged `plugin-host` should also
carry `plugin-events` — which is precisely the failure that motivates tagging (edit one
concern, miss the code that concern reaches). So retrieval stays two steps:

```
1. rg -l '@domain:.*plugin-host'      → starting set
2. for each symbol that set touches: rg '\bSymbolName\b'   → the edges Swift hides
```

Step 2 is not optional. Treating step 1 as the whole answer trades a silent omission for a
confident one, which is worse.

## Adding a domain

Adding an entry here is a product decision, not a labelling convenience. A new domain needs a
name a person would use, an Excludes line, and at least one file — the fitness test fails a
declared domain that matches nothing, because a vocabulary nobody uses is how a controlled
vocabulary stops being controlled.

---

## plugin-host

Plugin identity and lifecycle: manifest discovery and validation, inventory precedence and
admission, host-owned authorization and standing consent, generation staging, activation,
retirement, hot reload, filesystem watching, and shutdown.

**Excludes:** dispatching or authorizing an intent invocation (→ `intent-bus`), the content of
what a plugin contributes (→ `plugin-contributions`), and declared settings or plugin-private
storage (→ `plugin-settings`).

## plugin-contributions

What a live generation puts on screen and how the host projects it: status-bar items,
registered views and their pane header, view instances, palette providers and their
revision-scoped result snapshots, key-binding and command indexes.

**Excludes:** rendering those projections in SwiftUI (that lives in `TenonApp`, tagged by its
own file), and the event that *delivers* a palette query to a generation (→ `plugin-events`).

## plugin-events

Plugin-published facts and host-published facts targeted at a generation: channel
qualification under the owner's id, manifest-declared subscriptions, delivery and fan-out, and
the host-originated events — `automation.fired`, terminal title changes, pane cwd changes.

**Excludes:** the schedule that decides *when* an automation fires, and any invocation that
expects a result — an event is a fact, not a call (→ `intent-bus`).

## automation

Manifest-declared wall-clock schedules and the human supervision loop around them: scheduler
phase, global and per-schedule delivery policy, manual Run Now, recent delivery evidence, and
the host-native Automation Canvas that makes those states inspectable and actionable.

**Excludes:** publishing and fan-out after a firing becomes `automation.fired` (→
`plugin-events`), generic plugin manifest discovery and lifecycle (→ `plugin-host`), and the
Settings window's general navigation or styling.

## plugin-settings

Declared settings and their values, plugin-private storage, the secret store, installation
identity, and enable / disable / uninstall.

**Excludes:** the settings *window* and its SwiftUI surface, and manifest parsing of the
setting specs themselves (→ `plugin-host`).

## intent-bus

The invocation kernel: canonical contracts and schema, principals and policy, capability and
audience checks, consent, provider generations and leases, dispatch, admission, and the
presentation metadata a contract projects into palette and keybindings.

**Excludes:** the semantics any single intent implements — a provider's actual filesystem,
terminal, or workspace work belongs to that provider's own domain.

## pane-chrome

What a pane says about itself, and who may put something there. The bounded header vocabulary
and its admission rules, the geometry solver that places a run and decides what folds, the one
renderer, the store a host-native pane publishes through, and the typed routing that carries a
control's interaction back to whoever owns it.

The product concern is scarce attention: this strip is what a supervisor scans instead of
reading a pane, so what may appear in it — and what may never crowd out the pane's name or the
band you grab to move it — is a product rule before it is a layout one.

**Excludes:** the canvas geometry a pane sits in — drag, resize, split, focus ring (that is the
pane's position, not its chrome) — and the content a pane draws below the strip. A plugin's
right to contribute a header at all is `plugin-contributions`; the vocabulary it contributes
in, and everything that draws it, is here.

## spatial-canvas

Where a pane sits and how a person moves it: the grid, the hit regions, the press/drag/resize
state machine, the drop target, the context menu that acts on a pane's position, and the AppKit
surface that mounts each pane's card. The rules are a value-level machine with no view in them,
so a gesture can be asserted without a window; the views ask it what a gesture meant.

The product concern is that the canvas is the workspace. A supervisor arranges panes to keep
what matters in view, and an arrangement that shifts under them — a drag that commits the wrong
move, a pane that loses its surface when a neighbour resizes — costs exactly the attention this
layout was built to save.

**Excludes:** what a pane says about itself in its header strip (→ `pane-chrome`), what a pane
draws below that strip, and the lifecycle of the terminal or web surface a card mounts (→
`terminal-teardown` and the surface's own owner).

## row-list

The one indented list of things: the row vocabulary every file-ish pane is drawn from, its
bounds, the decoder that admits a plugin's rows into it, and the single renderer that turns a
row into a chevron, an icon, a label, a trailing status token, a context menu and a drag.

The product concern is that a list of files is the same list of files wherever it appears. A
supervisor moves between the file tree, the changed files, and whatever a plugin lists, at
speed and without re-reading anything; two implementations of "a row" meant two answers to
what a right-click does and where the indent starts, and the second surface silently lacked
affordances the first had. One vocabulary is what keeps a new list correct by default.

**Excludes:** what a pane says ABOUT its list — its name, its counts, its layout picker — which
is the header strip (→ `pane-chrome`), the right of a plugin to publish rows at all (→
`plugin-contributions`), and how the data in the rows was obtained (a git read, a directory
listing), which belongs to whoever owns that source.

## field-draft

Who owns the characters in a control while a person is typing in it, and when the control's
owner takes it back. One rule — focus decides — held in a value the views bind to, so a field
in a plugin's view and a field in a pane header answer a republish the same way.

The product concern is trust in an input: a supervisor types a path, a URL, a filter, while
agents keep publishing into the same surface. A field that loses characters to a background
republish is a field nobody types a long value into twice.

**Excludes:** what a control looks like and where it may appear (→ `pane-chrome`), a plugin's
right to contribute one (→ `plugin-contributions`), and a document being edited in the source
editor, which is a file's content rather than a control's draft.

## repository-read

What a pane knows about the repository it is looking at, and the one way it asks git for it:
the bounded subprocess, the porcelain parse, and the resolution of a file's two sides for a
diff. Reading is a question with an answer, so it has a size limit and a stable locale, and it
never runs on the thread that draws.

The product concern is that two panes looking at one repository must agree about it. The
changed-file list and the diff below it are read by different code paths, and when each owned
its own subprocess they also owned their own limits — the same repository could be bounded in
one pane and unbounded in the other.

**Excludes:** changing the repository — stage, unstage, discard, commit — which belongs to
whoever owns that action (today the git plugin), the diff algorithm itself, and the row
vocabulary a changed-file list is drawn in (→ `row-list`).

## agent-lens

What a supervisor can see and say about one agent session: how the session is discovered from
a live process, how its transcript and its lifecycle hooks are read, how tool calls, questions
and approvals become a timeline, and how a typed answer is delivered back into the agent's own
PTY. Every claim it shows carries the evidence it came from.

The product concern is the whole point of the app: an agent's work is a stream of terminal
output, and a person supervising several of them cannot read streams. This is the layer that
turns one session into something scannable without cutting the return path to the transcript,
the diff, or the command that produced it.

**Excludes:** the terminal that runs the agent and its teardown (→ `terminal-teardown`), the
pane the lens is drawn in (→ `spatial-canvas`, `pane-chrome`), and the intent kernel a lens
action travels through (→ `intent-bus`).

## command-surface

Everything a person types a name into to make something happen: the palette and its providers,
the launcher, quick commands, the command and key-binding indexes, and the matching and ranking
that decide what a few characters mean.

The product concern is that recall beats navigation. A supervisor who has to find a menu has
already lost the thread of what they were watching, so the fastest path to any action is its
name — which makes ordering, fuzzy matching and frecency product rules rather than utilities.

**Excludes:** the intents a command finally sends (→ `intent-bus`), the plugin's right to
contribute a command or a palette provider (→ `plugin-contributions`), and the keyboard controls
of one focused view, which are that view's own local behaviour.

## workspace-model

The workspace as a value: workspaces, tabs, panes and their arrangement, the mutations allowed
on them, what is restored at launch, and what is remembered as recent. Pure rules over a value
tree, with the store that persists them at the edge.

The product concern is that a supervisor's arrangement is their working memory. A tab that
comes back different after a restart, or a mutation that silently drops a pane, costs more than
the operation saved — so every mutation is a total function over the catalog, asserted without
a window.

**Excludes:** where a pane sits on screen and the gestures that move it (→ `spatial-canvas`),
what a pane draws, and the surfaces a pane mounts.

## attention

Which panes want a person, and how that want is ranked and reported: the per-pane activity
machine, the viewed rule that decides when something has been seen, the rollups a tab and a
sidebar row show, and the notification when a finish goes unattended.

The product concern is the scarcest resource in the product. Attention is directed by this
machine and by nothing else — no surface recomputes "is this busy", because two answers to that
question is how a supervisor learns to distrust the signal entirely.

**Excludes:** how a state is drawn (colour, glyph, spoken value) beyond the one vocabulary
declared here, and the terminal activity the machine is fed from.

## terminal-surface

The live terminal and web surfaces a pane mounts: the PTY-backed view, the surface pool that
keeps one per slot, the web surface pool and the user agent it presents. Identity is the
invariant — a surface belongs to a slot, and a reused slot is a new surface.

The product concern is that agents keep their native harness behaviour because they run in a
real PTY. Anything that reparents, re-creates, or silently swaps a surface breaks the process
running inside it, which is the one thing this product must not do.

**Excludes:** killing what a pane started when it closes (→ `terminal-teardown`), what the
terminal's output means to a lens (→ `agent-lens`), and the pane's chrome (→ `pane-chrome`).

## editor-and-diff

Reading and changing a file inside the workspace: the source editor and its document I/O,
syntax highlighting, the file and preview panes, and the diff — its request, its rows, and the
line-level comparison behind them.

The product concern is evidence. A claim in a lens ends at a diff or a file, and a supervisor
who cannot open that evidence in place has to leave the workspace to check it, which is where
supervision stops scaling.

**Excludes:** how the repository was read (→ `repository-read`), the row vocabulary a changed
file list uses (→ `row-list`), and the pane the editor is mounted in.

## cli-control

The local control channel: the socket the app listens on, its single-instance claim, the wire
protocol and its closed action vocabulary, and the `tenon-cli` client that speaks it.

The product concern is that agents and scripts drive Tenon from inside a terminal, so this
channel is a supervised surface too: it is local-trust, bounded in flight, and its domain
vocabulary is the same canonical intents everything else uses rather than a second API.

**Excludes:** the intents an action dispatches (→ `intent-bus`), the hook ingress that reports
agent activity (→ `agent-lens`), and installing the binary into a person's PATH, which is a
settings action.

## terminal-teardown

What a closing pane owes the processes it started: which of them the host can prove it owns,
what signal they get, how long they have to unwind, and what the host refuses to touch because
ownership cannot be proven.

The product concern is a promise the workspace makes about closing. A supervisor running many
agents closes panes constantly; if closing a pane leaves invisible work running, the count of
things happening on the machine stops matching the count of things on screen, which is the one
thing this product exists to keep true. It is a product rule before it is a signal-handling one:
"stop" has to mean stopped.

**Excludes:** when a surface is created or released, and the hidden-pane renderer rules that
keep a shell alive while nobody looks at it — that is pane lifetime, and lives in
`SurfacePool`. Also excludes process execution a caller asked for on purpose through
`process.exec.v1`, which belongs to that provider.

## diagnostics

What the app records about its own health so that a failure explains itself afterwards:
whether the main runloop is still completing turns, how long a stall has lasted, the process
figures worth keeping beside that judgement, and the bounded on-disk journal those records
live in — including what a person can export from it.

The product concern is that evidence must survive the incident. Tenon's whole claim is that a
condensed statement returns to inspectable evidence; an app that freezes and leaves nothing
behind fails that claim about itself. The T-091 hang was reconstructed from outside with
`sample` and `heap` only because a human happened to notice while the process was still
alive — a force quit would have erased all of it.

**Excludes:** a plugin's own `tenon.log` output, which is attributed to that generation and
belongs to `plugin-host`; anything a terminal displays, which is deliberately never recorded;
and the delivery evidence an automation keeps about its runs (→ `automation`).
