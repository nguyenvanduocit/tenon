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
