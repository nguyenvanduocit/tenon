import Foundation

/// T-061: the seed for pane-based pair-authoring of automations.
///
/// One pure type owns everything that crosses into the agent's PTY: the guide prompt
/// (the single-file manifest contract, schedule syntax, the `automation.fired` shape,
/// the REAL plugins-root path, and the Run Now verification loop) and the command that
/// delivers that prompt to `claude` as ONE POSIX-quoted argument. Pure on purpose —
/// every rule here is assertable headless, and the UI's only job is to type
/// `command(pluginsRoot:)` into a fresh pane.
enum AutomationAuthoring {
    /// The guide the agent reads before touching anything. Parameterized by the real
    /// plugins root so the agent never guesses a path.
    static func prompt(pluginsRoot: String) -> String {
        """
        You are pair-authoring a Tenon automation with the user, inside a Tenon \
        terminal pane.

        ## What a Tenon automation is
        One JavaScript file in this folder (your shell already starts here):
        \(pluginsRoot)
        Write it THERE and nowhere else. In particular never write a plugin inside \
        Tenon.app — that bundle is code-signed, so a file added to it breaks the \
        signature and the app fails to launch, and the next install deletes it anyway.
        The file MUST open with a manifest header — first bytes of the file, nothing \
        above it:

        /* tenon-manifest
        {
          "id": "dev.local.<name>",
          "name": "<name>",
          "version": "1",
          "permissions": [],
          "intents": { "uses": [] },
          "automation": { "schedules": [ { "id": "main", "every": "5m" } ] }
        }
        */

        Rules the host enforces at load:
        - Cadence is exactly one of "every": "<N><s|m|h|d>" (minimum "1m", maximum \
        "7d") or "daily": "HH:mm" (zero-padded 24-hour). Optional "grace" duration \
        bounds how stale a missed occurrence may still fire. At most 8 schedules per \
        file, ids unique.
        - "intents.uses" must name EVERY intent the script sends and "permissions" \
        the capabilities they need; undeclared use fails closed at call time.
        - The "intents" block itself is required even when it declares nothing — write \
        "intents": { "uses": [] }. The "uses" and "provides" lists inside it may be \
        omitted; the block around them may not.
        - A .js file without the header is silently skipped; a file that claims the \
        header and gets it wrong fails loudly with a diagnostic naming the file.

        ## How it runs
        - Saving the file into that folder loads it immediately, and every later save \
        hot-reloads it. A broken script is reported inside Tenon and never takes the \
        app down — fix and save again.
        - On schedule, Tenon delivers the event "automation.fired" to this plugin \
        only:
            tenon.events.on("automation.fired", async function (e) {
              // e.scheduleId, e.scheduledFor (ISO-8601), e.late (boolean),
              // e.trigger ("scheduled" | "manual")
            });
        - The script acts through its declared intents: \
        await tenon.intents.send("<intent-id>", { ... }). Discover what exists from \
        this shell: `tenon-cli intent list`, then `tenon-cli intent describe <id>`.
        - The sandbox exposes ONLY the `tenon` global — no require, no fetch, no \
        setTimeout (use tenon.timers.*). Log with tenon.log(...).

        ## Verify with the user (do not skip)
        1. After saving, ask the user to open Settings > Automation: the schedule \
        must appear there with its next firing.
        2. Ask them to press "Run Now": the handler runs with trigger "manual" and \
        the run appears under Recent runs with its delivery outcome.
        3. If the script uses privileged intents (process.exec.v1, filesystem \
        writes, ...), the first privileged call shows the user a consent prompt \
        inside Tenon — tell them to expect it and to read it before approving.

        Start by interviewing the user: what should happen, how often, and what \
        should be visible when it runs. Then write the smallest correct script, save \
        it, and walk through the verification together.
        """
    }

    /// `claude` plus the whole prompt as one quoted argument, ready for a shell.
    static func command(pluginsRoot: String) -> String {
        "claude " + posixQuoted(prompt(pluginsRoot: pluginsRoot))
    }

    /// Single-quote POSIX quoting: the only bytes the shell interprets in the result
    /// are the outer quotes themselves.
    static func posixQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
