# T-104: One place that knows how this person runs an agent

> Every plugin that starts an agent asks the host which agents exist and how this person
> runs them, and a session started in one agent can be continued in another.

- **priority**: high
- **effort**: L
- **PRD**: `docs/prds/agent-control.prd.md` (TENON-PRD-017) — new `AC-FR-031…035`

## Owner / files (agent lock)

**RELEASED — all locks free as of 03:5x, session `c437029d`.** The files this task wrote:

- `Sources/TenonCore/CoreIntentCatalog.swift`
- `Sources/TenonApp/AgentLaunchCommand.swift` (NEW)
- `Sources/TenonApp/AgentIntentProvider.swift` (NEW)
- `Sources/TenonApp/AgentLaunchSuggestions.swift`
- `Tests/TenonAppStateTests/AgentLaunchCommandTests.swift` (NEW)
- `Tests/TenonAppStateTests/AgentIntentProviderTests.swift` (NEW)
- `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`
- `Tests/TenonCoreTests/KanbanPluginTests.swift`
- `Tests/TenonCoreTests/WorkspaceScopedViewStateTests.swift`
- `plugins/claude-sessions/main.js`, `plugins/claude-sessions/manifest.json`
- `plugins/kanban/main.js`, `plugins/kanban/manifest.json`
- `docs/prds/agent-control.prd.md`, `docs/prds/agent-control.feature`,
  `docs/prds/README.md`
- `docs/architecture-interaction-boundaries.md`, `docs/domains.md`,
  `docs/plugin-author-guide.md`

⚠️ **One line inside a file another session holds**: `Sources/TenonApp/AppIntentRuntime.swift`
is claimed by T-071's second session. This task appended exactly one
`collected.append(contentsOf: try AgentIntentProvider().bindings())` beside the other
provider registrations (~line 91) and opened nothing else in that file. Safe to drop if it
conflicts.

⚠️ `Sources/TenonApp/PluginViewSnapshot.swift` was **experimented on and fully restored** —
`git diff` now shows only the one `tabID:` line that was already there when this session
started, which belongs to somebody else. The experiment (waiting for a view to hold still
before photographing it, rather than shooting its first render) changed neither picture it
was tested against, so it was reverted rather than kept on a hunch.

## Problem

The host already knows how this person runs an agent —
`Sources/TenonApp/AgentLaunchSuggestions.swift:80-250` reads PATH and the tail of the shell
history and answers with `{agent, executableURL, arguments}` over an allowlist of flags. That
answer reaches the Launcher and the empty-pane card only (`ContentView.swift:144`).

Every plugin that starts an agent therefore invents its own command line and loses the
person's own options:

- `plugins/kanban/main.js:812` — `"claude " + shellQuote(prompt)`
- `plugins/claude-sessions/main.js:564-577` — `claude`, `codex`, `claude --resume <id>`,
  `codex resume <id>`

A person whose habit is `claude --model opus --dangerously-skip-permissions` gets a plain
`claude` from every plugin, and each plugin re-implements shell quoting and provider argument
order. Sessions are also locked to the agent that created them: there is no way to continue a
Claude transcript in Codex, or the reverse.

## Shape

Two canonical intents, bound to the `terminal.write` capability the callers already hold
(knowing which flags a person uses grants no authority a terminal-writing plugin lacks):

- `agent.inventory.v1` → `{ agents: [{ id, label, arguments, habit }] }` — what is installed
  and how this person runs it. No paths, no history.
- `agent.command.v1` → `{ commandLine, agent, arguments, handoff }` — the host composes the
  provider-shaped command once: `claude --resume <id>`, `codex resume <id>`, or, when the
  chosen agent is not the one that wrote the session, a **handoff prompt** carrying the
  transcript path so the other agent reads the content itself.

Plugins keep calling `terminal.open.v1`, so pane topology stays owned by the terminal
contracts (PRD-017 AC-FR-021).

Verified transcript locations, both directions:
`~/.claude/projects/<slug>/<id>.jsonl`, and a Codex thread id from `state_5.sqlite` maps to
`~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`.

## Criteria

- [x] `agent.inventory.v1` lists only installed agents, with the arguments this person
      habitually passes, and never exposes an executable path or raw history
- [x] `agent.command.v1` composes a native resume for the session's own agent
- [x] `agent.command.v1` composes a handoff prompt naming the transcript path when the chosen
      agent did not write the session, and fails typed when no transcript path is given
- [x] The person's habitual arguments appear in every command a plugin launches
- [x] Agent Sessions can start and resume with any installed agent, not just the one that
      wrote the session
- [x] Kanban starts a task's agent through the same two intents, with a choice per installed
      agent
- [x] Shell quoting exists in exactly one place; no plugin builds an agent command line
- [x] `docs/prds/agent-control.prd.md` carries the new requirements with a dated receipt, and
      `docs/architecture-interaction-boundaries.md` inventories both contracts
- [x] `swift test` green, including the closed-surface and boundary fitness gates

## Evidence

- Full suite **1730 / 0**, re-confirmed on the final tree at 04:0x. Two attempts in between
  could not build at all — a peer session was mid-edit in `Sources/TenonCore/Workspace.swift`
  (`Tab.init` returning without initializing `number`, then the file changing during the
  build), which takes the shared module down for everybody. Nothing in that file belongs to
  this task, and the run that follows their edit is green.
- Red first, both new seams: `AgentLaunchCommandTests` 11 tests / 22 failures against the
  stub composer, then 11 / 0; `AgentIntentProviderTests` 10 failures against the stub
  provider, then 10 / 0.
- **A picture found a defect 29 passing tests did not.** `TENON_VIEW_SNAPSHOT` of the kanban
  board showed a **Start** button on every card — `main.js:597`, plus "Start again" at `:715`
  — both still sending `start:<task>` after the sheet's buttons had been rewired to
  `start:<agent>:<task>`. Every one of them was dead. Fixed, and covered by
  `testTheCardsStartUsesTheOnlyAgentThisMachineHas` and
  `testTheCardsStartAsksWhenThisMachineHasTwoAgents`; the pair was mutation-verified (drop
  the unnamed-agent branch → 5 failures, restore → green, `cmp`-verified byte-identical).
- Transcript layouts confirmed on this machine before being written into a prompt: a Codex
  thread id from `~/.codex/state_5.sqlite` resolves to
  `~/.codex/sessions/2026/08/09/rollout-…-<id>.jsonl`; Claude's is
  `~/.claude/projects/<slug>/<id>.jsonl`. Argument order was read from `codex --help`
  (`codex [OPTIONS] [PROMPT]`, `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`) and
  `claude --help` (`claude [options] [command] [prompt]`), not assumed.

## Known limits

- **The Agent Sessions pane renders empty under `TENON_VIEW_SNAPSHOT`, and did so before this
  task too** — proven by photographing the plugin as it stands at `HEAD` from a copied
  inventory: the two pictures are identical. So there is no photograph of the new per-agent
  buttons, and why that harness shows this plugin nothing is a pre-existing question for
  whoever owns the snapshot tool.
- The handoff prompt has never been read by an agent on the other side. It says where the
  transcript is and what shape it has; whether Claude or Codex then picks the session up well
  is unmeasured, and is the first thing to try by hand.
- No CLI-principal receipt. Both contracts admit `{plugin, cli, agent}`, but only the plugin
  audience was exercised.
- The inventory is re-read per call (PATH plus the tail of up to three history files). That is
  bounded and deliberate — a habit that changed an hour ago is the point of asking — but it is
  not cached, and the kanban board therefore reads it once per sheet opening rather than once
  per board refresh.
