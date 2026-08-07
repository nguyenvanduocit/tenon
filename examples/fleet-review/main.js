// Fleet Review — the supervised-fleet story, small enough to read in one sitting.
//
// One palette command puts three reviewers on the same change, each in its own visible
// pane, waits for all of them, reads back what each said, and publishes a one-line verdict.
// That is the whole shape Tenon exists to make supervisable: parallel agent work in real
// PTYs, with a human able to see which pane is still thinking and read any transcript in
// full.
//
// Everything here is the public boundary. `tenon.agents.run` is the platform loop —
// open a pane, arm the finish wait scoped to it, page the transcript back — and this file
// only decides what to run and what to do with the answers. Nothing is bundled into the
// app: this lives in `examples/` because a demo that runs an agent CLI does not belong in
// every user's palette by default. Copy the directory into `plugins/` to try it.
//
// It is loaded by `FleetReviewExampleTests`, so it cannot rot unnoticed the way an
// untested example would.

var REVIEWERS = [
  { name: "correctness", prompt: "Review the working tree for correctness bugs. Be brief." },
  { name: "security", prompt: "Review the working tree for security problems. Be brief." },
  { name: "tests", prompt: "Review the working tree for missing test coverage. Be brief." }
];

// A reviewer that never returns must not hold the fleet forever; the platform loop turns
// this into a typed timeout rather than a hang.
var TIMEOUT_MS = 10 * 60 * 1000;

function agentCommand() {
  return (tenon.settings.get("command") || "claude").trim() || "claude";
}

// One reviewer: its own pane, its own supervised run. Arguments go through as an array so
// the platform single-quotes each one — a prompt can never become shell syntax.
async function review(reviewer) {
  var result = await tenon.agents.run({
    command: agentCommand(),
    arguments: ["-p", reviewer.prompt],
    timeoutMs: TIMEOUT_MS
  });
  if (!result.ok) {
    return { name: reviewer.name, ok: false, detail: result.error.code };
  }
  return {
    name: reviewer.name,
    ok: true,
    detail: summarise(result.value.transcript)
  };
}

// The transcript is the agent's whole pane, and the status bar is one line. Keep the last
// non-empty line, which is where a `-p` run leaves its conclusion; the pane itself remains
// the place to read the rest, which is the point of running it in a real terminal.
function summarise(transcript) {
  var lines = String(transcript || "").split("\n");
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i].trim();
    if (line) return line.length > 60 ? line.slice(0, 59) + "…" : line;
  }
  return "(no output)";
}

tenon.intents.handle(
  "dev.tenon.examples.fleet-review.run.v1",
  async function () {
    tenon.statusBar.set("review: " + REVIEWERS.length + " agents running…");

    // The fan-out. Each run is independent and pane-scoped, so they genuinely overlap —
    // `terminal.wait.v1`'s lane allows concurrent waits precisely so this works.
    var results = await Promise.all(REVIEWERS.map(review));

    var failed = results.filter(function (r) { return !r.ok; });
    if (failed.length) {
      tenon.statusBar.set(
        "review: " + failed.length + "/" + results.length + " did not finish — "
          + failed.map(function (r) { return r.name + ":" + r.detail; }).join(", ")
      );
      return {};
    }
    tenon.statusBar.set(
      "review: " + results.map(function (r) {
        return r.name + "=" + r.detail;
      }).join("  ·  ")
    );
    return {};
  }
);
