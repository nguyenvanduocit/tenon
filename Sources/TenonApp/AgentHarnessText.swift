// @domain: agent-control, companion
import Foundation

/// The briefing Tenon installs into a person's global agent instructions.
///
/// It is loaded into every agent session on the machine, so it is written to the standard a
/// paragraph in `CLAUDE.md` is held to: short, and true. Two rules keep it honest, both
/// enforced by `AgentHarnessTextTests` — every environment variable it names is one
/// `TerminalPaneEnvironment` exports, and every `*.v1` id it prints is in `CoreIntentCatalog`.
///
/// What it deliberately leaves out: anything an agent can discover itself. `tenon-cli intent
/// list` is one line and always current; a hand-copied catalogue in here would not be.
enum AgentHarnessText {
    static let beginMarker = "<!-- BEGIN TENON MANAGED SECTION -->"
    static let endMarker = "<!-- END TENON MANAGED SECTION -->"

    /// Wrapped in markers and merged into `CLAUDE.md` / `AGENTS.md`.
    static let instructions = """
        ## Running inside Tenon

        Tenon is a macOS terminal workspace where several agents work in parallel panes while
        one person supervises them. If `command -v tenon-cli` finds nothing, or
        `$TENON_PANE_ID` is empty, you are not in a Tenon pane and none of this applies.

        **Say what you are working on.** The person supervising you sees a tab per pane and
        cannot read them all. Set your own tab's label when you start a task and again when it
        changes materially:

            tenon-cli rename "Fixing the token refresh race"
            tenon-cli rename          # clears it back to the content-derived title

        Keep it to a few words describing the work, not the step. Clear it when you finish.

        **What your pane knows about itself.** Every Tenon terminal exports:

        - `TENON_PANE_ID` — your pane. Stable wherever the pane is moved to, and the scope
          every `tenon-cli` verb below defaults to.
        - `TENON_TAB_ID`, `TENON_WORKSPACE_ID` — the tab and workspace that owned your pane
          when your shell started. These are a snapshot: if the pane has been moved since,
          they are stale, and `tenon-cli intent send workspace.pane.owner.v1 --input
          '{"paneID":"'"$TENON_PANE_ID"'"}'` is the live answer.
        - `TENON_SOCKET_PATH` — the running app's control socket, found automatically.

        **Ask instead of stopping.** When you need a decision, `agent.ask.v1` puts a real
        question with offered choices and evidence links in front of the person, and returns
        the typed value they chose. It writes nothing into anyone's terminal, and the record
        belongs to the pane, so it survives your context being compacted.

        **The rest.** `tenon-cli intent list` and `tenon-cli intent describe <id>` are the
        current, authoritative vocabulary — read them rather than guessing. `tenon-cli state`
        shows the workspace tree. Tenon deliberately does not orchestrate agents: it will not
        start work for you, and no intent lets you drive another agent's keyboard.
        """

    /// Written whole to `~/.claude/skills/tenon/SKILL.md`. Tenon owns the entire file.
    static let skill = """
        ---
        name: tenon
        description: Work inside a Tenon pane — label your own tab so the supervising human \
        can see what you are doing, resolve your pane/tab/workspace identity, and ask the \
        human a typed question instead of stalling. Use when $TENON_PANE_ID is set.
        ---

        # Working inside Tenon

        Tenon supervises several parallel agents for one human. Your pane is one tab among
        many, and that tab's label is the only thing about your work the person sees without
        opening it.

        ## Check you are actually in Tenon

            [ -n "$TENON_PANE_ID" ] && command -v tenon-cli >/dev/null || exit 0

        Everything below is a no-op outside a Tenon pane. Never install `tenon-cli` yourself.

        ## Label your tab

            tenon-cli rename "Migrating the session store"
            tenon-cli rename                      # clear, back to the derived title

        Do it when you pick up a task, when the task changes materially, and clear it when you
        are done. A few words about the work, not a running commentary — it is a label on a
        tab, truncated at 60 characters. It addresses your own pane through `$TENON_PANE_ID`;
        pass `--pane <uuid>` only when you mean a different one.

        ## Know where you are

            echo "$TENON_PANE_ID"        # your pane; stable across moves
            echo "$TENON_TAB_ID"         # snapshot from when this shell started
            echo "$TENON_WORKSPACE_ID"   # snapshot from when this shell started

        A pane can be dragged into another tab while your shell keeps running, and a running
        process's environment cannot be rewritten from outside. When the answer has to be
        right, ask the catalog instead of the environment:

            tenon-cli intent send workspace.pane.owner.v1 \\
              --input '{"paneID":"'"$TENON_PANE_ID"'"}'

        `tenon-cli state` prints the workspace, its tabs, and their panes.

        ## Ask the human, do not stall

        When a decision is genuinely theirs, put the question in front of them with the
        choices you would accept and the evidence behind it. The call blocks until they answer
        or your deadline expires, and returns the value they chose:

            tenon-cli intent send agent.ask.v1 --timeout 60000 --input '{
              "question": "The migration drops the legacy column. Proceed?",
              "choices": [
                {"id": "drop", "label": "Drop it", "value": true},
                {"id": "keep", "label": "Keep it for now", "value": false}
              ],
              "evidence": [{"label": "migration", "url": "file:///path/to/0007.sql"}],
              "recipient": {"kind": "human"},
              "timeoutMs": 60000
            }'

        A `status` of `expired` means nobody answered — it is not consent.

        ## Discover the rest

            tenon-cli intent list
            tenon-cli intent describe workspace.pane.title.set.v1

        That inventory is authoritative and current; this file is not a substitute for it.
        Tenon refuses to orchestrate: nothing here starts another agent or types into one.
        """
}
